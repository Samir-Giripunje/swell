import AVFoundation

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone found."
        case .unsupportedFormat: "The microphone's audio format isn't supported."
        }
    }
}

final class AudioRecorder {
    static let sampleRate: Double = 16_000

    var onLevel: ((Float) -> Void)?
    // Self-test only: replaces the next recording's audio, then clears itself.
    var injectedSamples: [Float]?
    private(set) var inputFormat: AVAudioFormat?

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var pendingLevel: Float?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    func start(device: AudioDeviceID?) throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let device { try select(device, on: input) }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
        self.inputFormat = inputFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.unsupportedFormat
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer, using: converter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func select(_ device: AudioDeviceID, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw AudioRecorderError.noInputDevice }
        var deviceID = device
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioRecorderError.noInputDevice }
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        defer { injectedSamples = nil }
        return injectedSamples ?? lock.withLock { samples }
    }

    private func append(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var delivered = false
        converter.convert(to: output, error: nil) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }

        guard let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        lock.withLock { samples.append(contentsOf: chunk) }
        publishLevel(Self.normalizedLevel(of: chunk))
    }

    // Coalesces level updates so at most one is ever queued on the main thread.
    private func publishLevel(_ level: Float) {
        let isFirstPending = lock.withLock {
            defer { pendingLevel = level }
            return pendingLevel == nil
        }
        guard isFirstPending else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let latest = self.lock.withLock {
                defer { self.pendingLevel = nil }
                return self.pendingLevel ?? 0
            }
            self.onLevel?(latest)
        }
    }

    private static func normalizedLevel(of chunk: [Float]) -> Float {
        let meanSquare = chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)
        let decibels = 20 * log10(max(sqrt(meanSquare), 1e-6))
        return min(max((decibels + 55) / 40, 0), 1)
    }
}
