import Foundation

@main
struct StoreCheck {
    static func main() throws {
        let now = ContinuousClock.now
        let admission = RunAdmission(now: now)
        assert(admission.permitsRetry(at: now + .seconds(10)))
        assert(!admission.permitsRetry(at: now + .seconds(86_400)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ResumeStore(root: root)
        let a = ResumeStore.Record(session: "session-a", run: "run-a")
        let b = ResumeStore.Record(session: "session-b", run: "run-b")
        try store.save(a, connection: "host-a", bot: "bot-a")
        try store.save(b, connection: "host-a", bot: "bot-a")
        try store.save(a, connection: "host-a", bot: "bot-a")
        let restored = try store.records(connection: "host-a", bot: "bot-a")
        assert(Set(restored.map(\.run)) == [a.run, b.run])
        let otherHost = try store.records(connection: "host-b", bot: "bot-a")
        assert(otherHost.isEmpty)
        let otherBot = try store.records(connection: "host-a", bot: "bot-b")
        assert(otherBot.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files {
            let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: String]]
            assert(rows.allSatisfy { Set($0.keys) == ["session", "run"] })
        }
        try store.remove(a, connection: "host-a", bot: "bot-a")
        let remaining = try store.records(connection: "host-a", bot: "bot-a")
        assert(remaining == [b])
        print("STORE OK: ids only, concurrent sessions, connection/profile isolation, idempotent save, terminal cleanup")
    }
}
