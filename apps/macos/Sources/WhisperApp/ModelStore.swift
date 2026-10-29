import Foundation
import WhisperKit

struct WhisperModel: Identifiable, Hashable {
    let id: String
    let name: String
    let size: String
    let detail: String

    static let tiny = WhisperModel(id: "openai_whisper-tiny", name: "Tiny", size: "77 MB", detail: "Fastest, good for short notes")
    static let base = WhisperModel(id: "openai_whisper-base", name: "Base", size: "147 MB", detail: "Better accuracy, still instant")
    static let all: [WhisperModel] = [
        tiny,
        base,
        WhisperModel(id: "openai_whisper-small_216MB", name: "Small", size: "217 MB", detail: "Best accuracy for longer dictation"),
    ]

    static func with(id: String) -> WhisperModel {
        all.first { $0.id == id } ?? base
    }
}

enum ModelStore {
    private static let repoPath = "models/argmaxinc/whisperkit-coreml"
    private static let completeMarker = ".wisper-download-complete"

    static func folder(for model: WhisperModel) -> URL {
        AppPaths.models.appendingPathComponent(repoPath).appendingPathComponent(model.id)
    }

    static func isDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: model).appendingPathComponent(completeMarker).path)
    }

    static func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await WhisperKit.download(variant: model.id, downloadBase: AppPaths.models) {
            progress($0.fractionCompleted)
        }
        markComplete(model)
    }

    static func markComplete(_ model: WhisperModel) {
        FileManager.default.createFile(atPath: folder(for: model).appendingPathComponent(completeMarker).path, contents: nil)
    }

    static func delete(_ model: WhisperModel) throws {
        try FileManager.default.removeItem(at: folder(for: model))
    }
}

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Swell", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let models: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Whisper/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
