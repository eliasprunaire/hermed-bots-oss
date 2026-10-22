import CryptoKit
import Foundation

struct RunAdmission {
    let key = UUID().uuidString
    private let deadline: ContinuousClock.Instant

    init(now: ContinuousClock.Instant = .now) {
        // S2 retient la clé 24 h ; le dernier essai garde ses 15 s de transport
        deadline = now + .seconds(86_400 - 15)
    }

    func permitsRetry(at now: ContinuousClock.Instant = .now) -> Bool { now < deadline }
}

struct ResumeStore {
    struct Record: Codable, Equatable, Sendable {
        let session: String
        let run: String
    }

    let root: URL

    static var applicationStore: ResumeStore {
        ResumeStore(root: URL.applicationSupportDirectory.appendingPathComponent("Hermed Bots/Resume", isDirectory: true))
    }

    private func file(connection: String, bot: String) -> URL {
        let identity = Data((connection + "\0" + bot).utf8)
        let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(hash + ".json")
    }

    func data(connection: String, bot: String) throws -> Data {
        let url = file(connection: connection, bot: bot)
        guard FileManager.default.fileExists(atPath: url.path) else { return Data("[]".utf8) }
        return try Data(contentsOf: url)
    }

    func records(connection: String, bot: String) throws -> [Record] {
        try JSONDecoder().decode([Record].self, from: data(connection: connection, bot: bot))
    }

    func save(_ record: Record, connection: String, bot: String) throws {
        var records = try records(connection: connection, bot: bot)
        records.removeAll { $0.session == record.session }
        records.append(record)
        try write(records, connection: connection, bot: bot)
    }

    func remove(_ record: Record, connection: String, bot: String) throws {
        try write(records(connection: connection, bot: bot).filter { $0 != record }, connection: connection, bot: bot)
    }

    private func write(_ records: [Record], connection: String, bot: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = file(connection: connection, bot: bot)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
