import Foundation

/// Another computer running a Swell host, paired with a pairing link.
struct Machine: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var url: URL
    var token: String
}

/// Where dictation is transcribed.
enum Engine: Hashable {
    case onDevice
    case machine(UUID)

    private static let machinePrefix = "machine:"

    init(rawValue: String) {
        if rawValue.hasPrefix(Self.machinePrefix), let id = UUID(uuidString: String(rawValue.dropFirst(Self.machinePrefix.count))) {
            self = .machine(id)
        } else {
            self = .onDevice
        }
    }

    var rawValue: String {
        switch self {
        case .onDevice: "onDevice"
        case .machine(let id): Self.machinePrefix + id.uuidString
        }
    }
}

enum MachineStatus: Equatable {
    case unknown
    case checking
    case online(HostHealth, milliseconds: Int)
    case offline(String)
}

/// Paired machines and their tokens, in a file only this user can read, like ~/.ssh.
/// Not the Keychain: Swell is signed without an Apple team ID, so macOS would ask for the login password after every update.
enum MachineStore {
    static let file = AppPaths.support.appendingPathComponent("machines.json")

    static func load(from file: URL = file) -> [Machine] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Machine].self, from: data)) ?? []
    }

    static func save(_ machines: [Machine], to file: URL = file) throws {
        let data = try JSONEncoder().encode(machines)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try data.write(to: file)
    }
}
