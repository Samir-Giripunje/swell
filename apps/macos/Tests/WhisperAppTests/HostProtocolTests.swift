import Foundation
import Testing
@testable import WhisperApp

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../../packages/protocol/fixtures")
    .standardized

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
}

private struct PairingFixtures: Decodable {
    struct Valid: Decodable {
        let link: String
        let name: String
        let url: String
        let token: String
    }

    let valid: [Valid]
    let invalid: [String]
}

@Suite struct ProtocolFixtureTests {
    @Test func decodesResponses() throws {
        let health = try JSONDecoder().decode(HostHealth.self, from: fixture("health.json"))
        #expect(health == HostHealth(protocol: 1, name: "samir-Legion-5Pro-16ACH6H", model: "large-v3-turbo", device: "cuda", cleanup: .medium))
        #expect(health.summary == "large-v3-turbo on GPU")
        #expect(try JSONDecoder().decode(HostTranscription.self, from: fixture("transcription.json")).text.hasPrefix("Can you check"))
        #expect(try JSONDecoder().decode(HostErrorBody.self, from: fixture("error.json")).error.code == "unauthorized")
    }

    @Test func parsesPairingLinks() throws {
        let cases = try JSONDecoder().decode(PairingFixtures.self, from: fixture("pairing-links.json"))
        for valid in cases.valid {
            let link = try #require(PairingLink(valid.link))
            #expect(link.name == valid.name)
            #expect(link.url.absoluteString == valid.url)
            #expect(link.token == valid.token)
        }
        for invalid in cases.invalid {
            #expect(PairingLink(invalid) == nil, "accepted \(invalid)")
        }
    }
}

@Suite struct WAVEncoderTests {
    @Test func writesMono16BitPCM() {
        let data = WAVEncoder.encode([0, 1, -1, 2], sampleRate: 16_000)
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        let samples = data[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples == [0, Int16.max, -Int16.max, Int16.max], "out-of-range samples clip")
    }
}

@Suite struct EngineTests {
    @Test func rawValueRoundTrips() {
        let id = UUID()
        #expect(Engine(rawValue: Engine.machine(id).rawValue) == .machine(id))
        #expect(Engine(rawValue: Engine.onDevice.rawValue) == .onDevice)
        #expect(Engine(rawValue: "machine:not-a-uuid") == .onDevice)
        #expect(Engine(rawValue: "") == .onDevice)
    }

    @Test(arguments: [
        (loaded: false, engine: "onDevice", known: true, ready: false),
        (loaded: true, engine: "onDevice", known: true, ready: true),
        (loaded: false, engine: "machine", known: true, ready: true),
        (loaded: false, engine: "machine", known: false, ready: false),
        (loaded: true, engine: "machine", known: false, ready: true),
    ])
    func readiness(loaded: Bool, engine: String, known: Bool, ready: Bool) {
        let machine = Machine(id: UUID(), name: "gpu", url: URL(string: "http://100.1.2.3:8765")!, token: "t")
        let selected: Engine = engine == "machine" ? .machine(machine.id) : .onDevice
        #expect(AppState.isReady(loadedModelID: loaded ? "base" : nil, engine: selected, machines: known ? [machine] : []) == ready)
    }
}

/// Answers every request with a canned response, so tests exercise HostClient without a network.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: (URLRequest) throws -> (Int, Data) = { _ in (200, Data()) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let (status, body) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

@Suite(.serialized) struct HostClientTests {
    private let client: HostClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HostClient(url: URL(string: "http://100.1.2.3:8765")!, token: "secret", session: URLSession(configuration: configuration))
    }()

    @Test func transcribeSendsWAVWithTokenAndLanguage() async throws {
        nonisolated(unsafe) var sent: URLRequest?
        StubProtocol.respond = { request in
            sent = request
            return (200, try fixture("transcription.json"))
        }
        let text = try await client.transcribe([0, 0.5], language: .english, rephrase: .low, timeout: 5)
        #expect(text.hasPrefix("Can you check"))
        let request = try #require(sent)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://100.1.2.3:8765/v1/transcribe?language=en&cleanup=low")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
    }

    @Test func rephraseSendsJSON() async throws {
        nonisolated(unsafe) var sent: URLRequest?
        StubProtocol.respond = { request in
            sent = request
            return (200, Data(#"{"text":"Fixed."}"#.utf8))
        }
        #expect(try await client.rephrase("fixd", level: .high, timeout: 5) == "Fixed.")
        let request = try #require(sent)
        #expect(request.url?.absoluteString == "http://100.1.2.3:8765/v1/rephrase")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test(arguments: [
        (status: 401, body: #"{"error":{"code":"unauthorized","message":"Wrong or missing token."}}"#, expected: HostError.rejected(status: 401, code: "unauthorized", message: "Wrong or missing token.")),
        (status: 500, body: #"{"error":{"code":"internal","message":"Transcription failed on the host."}}"#, expected: HostError.rejected(status: 500, code: "internal", message: "Transcription failed on the host.")),
        (status: 502, body: "<html>Bad gateway</html>", expected: HostError.badResponse),
        (status: 200, body: #"{"unexpected":true}"#, expected: HostError.badResponse),
    ])
    func mapsHostResponses(status: Int, body: String, expected: HostError) async {
        StubProtocol.respond = { _ in (status, Data(body.utf8)) }
        await #expect(throws: expected) { try await client.health(timeout: 5) }
    }

    @Test func mapsNetworkFailures() async {
        StubProtocol.respond = { _ in throw URLError(.timedOut) }
        await #expect(throws: HostError.unreachable("timed out")) { try await client.health(timeout: 5) }
    }

    @Test func explainsWhatToDo() {
        #expect(HostError.rejected(status: 401, code: "unauthorized", message: "").localizedDescription.contains("pairing link"))
        #expect(HostError.unreachable("timed out").localizedDescription.contains("Tailscale"))
    }
}

@Suite struct MachineStoreTests {
    @Test func savesPrivatelyAndLoadsBack() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let machines = [Machine(id: UUID(), name: "gpu", url: URL(string: "http://100.1.2.3:8765")!, token: "secret")]
        try MachineStore.save(machines, to: file)
        #expect(MachineStore.load(from: file) == machines)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}

@Suite struct WordDiffTests {
    @Test(arguments: [
        (original: "the results was good", rewritten: "The results were good.", changed: [0, 2, 3]),
        (original: "Looks fine to me.", rewritten: "Looks fine to me.", changed: []),
        (original: "hey team", rewritten: "Hey team,\n\nI checked the logs.", changed: [0, 1, 2, 3, 4, 5]),
    ])
    func highlightsInsertedWords(original: String, rewritten: String, changed: [Int]) {
        #expect(WordDiff.changedWords(from: original, to: rewritten) == Set(changed))
    }

    @Test func keepsTheRewrittenTextExactly() {
        let rewritten = "Hey team,\n\nI checked  the logs."
        #expect(String(WordDiff.highlighted(rewritten, comparedTo: "hey team i checked the logs").characters) == rewritten)
    }
}
