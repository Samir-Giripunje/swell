import AVFoundation

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case unsupportedFormat
    case audioSystemNotResponding

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone found."
        case .unsupportedFormat: "The microphone's audio format isn't supported."
        case .audioSystemNotResponding:
            "macOS audio isn't responding. Run `sudo killall coreaudiod` in Terminal, or restart the Mac."
        }
    }
}

final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    private static let startTimeout: TimeInterval = 3

    var onLevel: ((Float) -> Void)?
    // Self-test only: replaces the next recording's audio, then clears itself.
    var injectedSamples: [Float]?

    // AVAudioEngine calls into coreaudiod synchronously; a wedged coreaudiod
    // would freeze the main thread, so the engine is only touched on this queue.
    private let audioQueue = DispatchQueue(label: "com.samirgiripunje.whisper.audio")
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var pendingLevel: Float?
    private var isStartInFlight = false
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    // An empty UID means the system default input.
    func start(microphoneUID: String) async throws -> (device: String, format: AVAudioFormat) {
        let alreadyStarting = lock.withLock {
            defer { isStartInFlight = true }
            return isStartInFlight
        }
        if alreadyStarting { throw AudioRecorderError.audioSystemNotResponding }

        return try await withCheckedThrowingContinuation { continuation in
            let outcome = SingleResume(continuation)
            audioQueue.async { [self] in
                let result = Result {
                    let device = AudioDevices.inputs().first { $0.uid == microphoneUID }
                    return (device: device?.name ?? "system default", format: try startEngine(device: device?.id))
                }
                lock.withLock { isStartInFlight = false }
                if !outcome.resume(with: result), case .success = result { stopEngine() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.startTimeout) {
                outcome.resume(with: .failure(AudioRecorderError.audioSystemNotResponding))
            }
        }
    }

    private func startEngine(device: AudioDeviceID?) throws -> AVAudioFormat {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let device { try select(device, on: input) }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
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
        return inputFormat
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
        audioQueue.async { [self] in stopEngine() }
        defer { injectedSamples = nil }
        return injectedSamples ?? lock.withLock { samples }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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

private final class SingleResume<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
        return pending != nil
    }
}
