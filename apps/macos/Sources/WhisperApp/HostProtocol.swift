import Foundation

// Swell's host protocol, v1. The wire format is defined in packages/protocol; keep these types in step with it.

struct HostHealth: Codable, Equatable {
    let `protocol`: Int
    let name: String
    let model: String
    let device: String
    let cleanup: Bool

    var summary: String {
        let hardware = device == "cuda" ? "GPU" : "CPU"
        return "\(model) on \(hardware)" + (cleanup ? " · cleanup on" : "")
    }
}

struct HostTranscription: Codable, Equatable {
    let text: String
}

struct HostErrorBody: Codable, Equatable {
    struct Detail: Codable, Equatable {
        let code: String
        let message: String
    }

    let error: Detail
}

/// `swell://pair?name=…&url=…&token=…`, which hands a host's address and token to this Mac.
struct PairingLink: Equatable {
    let name: String
    let url: URL
    let token: String

    init?(_ text: String) {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "swell", components.host == "pair" else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard let name = query["name"], !name.isEmpty,
              let token = query["token"], !token.isEmpty,
              let url = query["url"].flatMap(URL.init(string:)),
              ["http", "https"].contains(url.scheme), url.host != nil, url.path.isEmpty || url.path == "/" else { return nil }
        self.name = name
        self.url = url
        self.token = token
    }
}

enum HostError: LocalizedError, Equatable {
    case unreachable(String)
    case rejected(status: Int, code: String, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unreachable(let reason):
            "Couldn't reach it (\(reason)). Check that it's awake and Tailscale is on, on both machines."
        case .rejected(_, "unauthorized", _):
            "It rejected the token. Copy a fresh pairing link from Swell on that machine and add it again."
        case .rejected(_, "forbidden", _):
            "It only accepts connections over Tailscale. Use its Tailscale address (100.x.y.z)."
        case .rejected(_, _, let message):
            message
        case .badResponse:
            "It answered, but not like a Swell host. Update Swell on that machine."
        }
    }
}

/// Mono 16-bit PCM WAV, the body `POST /v1/transcribe` expects.
enum WAVEncoder {
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}

struct HostClient {
    let url: URL
    let token: String
    var session = URLSession(configuration: .ephemeral)

    func health(timeout: TimeInterval) async throws -> HostHealth {
        try await send(request("v1/health", timeout: timeout))
    }

    func transcribe(_ samples: [Float], language: DictationLanguage, timeout: TimeInterval) async throws -> String {
        var request = request("v1/transcribe", timeout: timeout, query: [URLQueryItem(name: "language", value: language.hostCode)])
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = WAVEncoder.encode(samples, sampleRate: Int(AudioRecorder.sampleRate))
        let transcription: HostTranscription = try await send(request)
        return transcription.text
    }

    private func request(_ path: String, timeout: TimeInterval, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: url.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        var request = URLRequest(url: components?.url ?? url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw HostError.unreachable(error.code == .timedOut ? "timed out" : error.localizedDescription)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw HostError.badResponse }
        guard (200..<300).contains(status) else {
            guard let body = try? JSONDecoder().decode(HostErrorBody.self, from: data) else { throw HostError.badResponse }
            throw HostError.rejected(status: status, code: body.error.code, message: body.error.message)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw HostError.badResponse }
        return decoded
    }
}
