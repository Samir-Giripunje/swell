import CoreML
import Foundation
import WhisperKit

enum DictationLanguage: String, CaseIterable, Identifiable {
    case auto
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto-detect"
        case .english: "English"
        }
    }

    fileprivate var whisperCode: String? {
        switch self {
        case .auto: nil
        case .english: "en"
        }
    }

    // The `language` query parameter of the host protocol.
    var hostCode: String { whisperCode ?? "auto" }
}

actor Transcriber {
    // Neural Engine for the heavy encoder/decoder is the most power-efficient path;
    // the tiny mel-spectrogram step stays on CPU so the GPU never has to wake up.
    private static let computeOptions = ModelComputeOptions(
        melCompute: .cpuOnly,
        audioEncoderCompute: .cpuAndNeuralEngine,
        textDecoderCompute: .cpuAndNeuralEngine
    )

    private var whisperKit: WhisperKit?

    // Builds the new model before swapping, so the current one keeps working until then.
    func load(from folder: URL) async throws {
        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: AppPaths.models,
            computeOptions: Self.computeOptions,
            verbose: false,
            logLevel: .error
        ))
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: Int(AudioRecorder.sampleRate)))
        let previous = whisperKit
        whisperKit = kit
        await previous?.unloadModels()
    }

    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    func transcribe(_ samples: [Float], language: DictationLanguage) async throws -> String {
        guard let whisperKit else { return "" }
        // Past 30 s, WhisperKit otherwise cuts fixed windows, and words straddling a cut are lost; after
        // a long thinking pause whole sentences went missing. VAD chunking cuts in the pauses instead.
        let options = DecodingOptions(
            language: language.whisperCode,
            detectLanguage: language == .auto,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    // Whisper emits bracketed tags such as [BLANK_AUDIO] for silence or noise.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
