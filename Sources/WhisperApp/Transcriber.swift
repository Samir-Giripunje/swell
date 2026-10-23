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
}

actor Transcriber {
    static let modelName = "openai_whisper-tiny"
    private static let modelFolderKey = "cachedModelFolder"
    // Neural Engine for the heavy encoder/decoder is the most power-efficient path;
    // the tiny mel-spectrogram step stays on CPU so the GPU never has to wake up.
    private static let computeOptions = ModelComputeOptions(
        melCompute: .cpuOnly,
        audioEncoderCompute: .cpuAndNeuralEngine,
        textDecoderCompute: .cpuAndNeuralEngine
    )

    private var whisperKit: WhisperKit?

    func load() async throws {
        guard whisperKit == nil else { return }
        let kit = try await WhisperKit(Self.config())
        if let folder = kit.modelFolder {
            UserDefaults.standard.set(folder.path, forKey: Self.modelFolderKey)
        }
        _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: Int(AudioRecorder.sampleRate)))
        whisperKit = kit
    }

    func unload() async {
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    func transcribe(_ samples: [Float], language: DictationLanguage) async throws -> String {
        guard let whisperKit else { return "" }
        let options = DecodingOptions(
            language: language.whisperCode,
            detectLanguage: language == .auto,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    private static func config() -> WhisperKitConfig {
        let modelsDirectory = AppPaths.models
        if let cached = UserDefaults.standard.string(forKey: modelFolderKey),
           FileManager.default.fileExists(atPath: cached) {
            return WhisperKitConfig(
                modelFolder: cached,
                tokenizerFolder: modelsDirectory,
                computeOptions: computeOptions,
                verbose: false,
                logLevel: .error
            )
        }
        return WhisperKitConfig(
            model: modelName,
            downloadBase: modelsDirectory,
            computeOptions: computeOptions,
            verbose: false,
            logLevel: .error
        )
    }

    // Whisper emits bracketed tags such as [BLANK_AUDIO] for silence or noise.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppPaths {
    static let models: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Whisper/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
