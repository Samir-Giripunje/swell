import Foundation
import FoundationModels

/// Swell's rephrasing prompts, shared with the Linux host through packages/protocol/fixtures/rephrasing.json,
/// which build.sh copies into the app.
struct RephrasingPrompts: Decodable {
    struct Level: Decodable {
        let instructions: String
        let examples: [[String]]
        let wordRatio: [Double]
    }

    struct Kind: Decodable {
        let preamble: String
        let tag: String
        let levels: [String: Level]
    }

    let minWords: Int
    let fillers: String
    let sentenceStart: String
    let dictation: Kind
    let text: Kind
    let lowCases: [[String]]

    static func load(from url: URL) throws -> RephrasingPrompts {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RephrasingPrompts.self, from: Data(contentsOf: url))
    }

    static let bundled: RephrasingPrompts? = Bundle.main.url(forResource: "rephrasing", withExtension: "json")
        .flatMap { try? load(from: $0) }
}

enum OnDeviceRephraserError: LocalizedError {
    case unavailable(String)
    case strayed
    case tooLong
    case declined

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .strayed: "The rewrite strayed too far from your text, so Swell discarded it. Try another level."
        case .tooLong: "That's more text than this Mac's model can take at once (about 1,500 words)."
        case .declined: "Apple's model declined to rewrite this text."
        }
    }
}

/// Rephrases with Apple's on-device model, so dictation cleanup and text correction keep working when no machine answers.
enum OnDeviceRephraser {
    static var unavailableReason: String? {
        guard #available(macOS 26, *) else { return "Rephrasing on this Mac needs macOS 26 with Apple Intelligence." }
        if RephrasingPrompts.bundled == nil { return "Swell's rephrasing prompts are missing from the app. Reinstall Swell." }
        return AppleModel.unavailableReason
    }

    /// Dictation never fails here: the transcript comes back unchanged when the level is off, the text is short,
    /// or the model is unavailable or strays. Low is a word list and needs no model.
    static func cleaned(_ text: String, level: RephraseLevel) async -> String {
        guard level != .off, let prompts = RephrasingPrompts.bundled else { return text }
        if level == .low { return withoutFillers(text, prompts: prompts) }
        guard text.split(whereSeparator: \.isWhitespace).count >= prompts.minWords,
              unavailableReason == nil, let prompt = prompts.dictation.levels[level.rawValue] else { return text }
        return (try? await rewrite(text, kind: prompts.dictation, level: prompt, minWords: prompts.minWords)) ?? text
    }

    /// Typed text: throws, so the popover can say why instead of pretending nothing needed changing.
    static func corrected(_ text: String, level: RephraseLevel) async throws -> String {
        if let reason = unavailableReason { throw OnDeviceRephraserError.unavailable(reason) }
        guard let prompts = RephrasingPrompts.bundled, let prompt = prompts.text.levels[level.rawValue] else {
            throw OnDeviceRephraserError.unavailable("Swell can't correct at the \(level.title) level.")
        }
        return try await rewrite(text, kind: prompts.text, level: prompt, minWords: prompts.minWords)
    }

    static func withoutFillers(_ text: String, prompts: RephrasingPrompts) -> String {
        let fillers = try? NSRegularExpression(pattern: prompts.fillers, options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        let stripped = (fillers?.stringByReplacingMatches(in: text, range: range, withTemplate: "") ?? text)
            .trimmingCharacters(in: .whitespaces)
        // A filler that opened a sentence took its capital letter with it.
        guard let sentenceStart = try? NSRegularExpression(pattern: prompts.sentenceStart) else { return stripped }
        var result = stripped
        for match in sentenceStart.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)).reversed() {
            guard let matched = Range(match.range, in: result) else { continue }
            result.replaceSubrange(matched, with: result[matched].uppercased())
        }
        return result
    }

    static func accepted(_ original: String, _ result: String, wordRatio: [Double], minWords: Int) -> Bool {
        let words = original.split(whereSeparator: \.isWhitespace).count
        guard !result.isEmpty else { return false }
        // Ratios are noise on a few words.
        guard words >= minWords, wordRatio.count == 2 else { return true }
        let ratio = Double(result.split(whereSeparator: \.isWhitespace).count) / Double(words)
        return wordRatio[0] <= ratio && ratio <= wordRatio[1]
    }

    private static func rewrite(_ text: String, kind: RephrasingPrompts.Kind, level: RephrasingPrompts.Level, minWords: Int) async throws -> String {
        guard #available(macOS 26, *) else { throw OnDeviceRephraserError.unavailable(unavailableReason ?? "") }
        let result = try await AppleModel.rewrite(text, kind: kind, level: level)
        guard accepted(text, result, wordRatio: level.wordRatio, minWords: minWords) else {
            throw OnDeviceRephraserError.strayed
        }
        return result
    }
}

@available(macOS 26, *)
private enum AppleModel {
    // Apple's guardrails for rewriting the user's own text. The default ones refused "this flaky test is killing me".
    private static let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    static var unavailableReason: String? {
        switch model.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in System Settings to rephrase on this Mac."
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading its model. Try again in a few minutes."
        case .unavailable: "This Mac can't run Apple Intelligence."
        }
    }

    static func rewrite(_ text: String, kind: RephrasingPrompts.Kind, level: RephrasingPrompts.Level) async throws -> String {
        let examples = level.examples.map { "<\(kind.tag)>\($0[0])</\(kind.tag)>\n\($0[1])" }.joined(separator: "\n\n")
        let session = LanguageModelSession(model: model, instructions: kind.preamble + level.instructions + "\n\nExamples:\n\n" + examples)
        let words = text.split(whereSeparator: \.isWhitespace).count
        // A model that answers instead of editing otherwise writes until its 4,096-token context is full (58 s in testing).
        // This cap is well above any rewrite the word-count check would accept.
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: words * 3 + 64)
        do {
            return try await session.respond(to: "<\(kind.tag)>\(text)</\(kind.tag)>", options: options).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw OnDeviceRephraserError.tooLong
        } catch LanguageModelSession.GenerationError.guardrailViolation, LanguageModelSession.GenerationError.refusal {
            throw OnDeviceRephraserError.declined
        }
    }
}
