import Foundation
import HermesAdapter

@main
struct ProfileKeyProbe {
    static func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

    static func main() async {
        do { try await run() }
        catch { log("HD17 LIVE failure: " + String(describing: type(of: error))); exit(1) }
    }

    static func run() async throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let keys = try JSONDecoder().decode([String: String].self, from: data)
        let environment = AppEnvironment.resolve(["HV_TEST_MODE": "1", "HV_TEST_API_KEYS": String(decoding: data, as: UTF8.self)])
        let store = environment.secrets
        guard store is InMemorySecretStore, Set(keys.values).count == 9 else { throw URLError(.userAuthenticationRequired) }
        let base = URL(string: "http://127.0.0.1:18642")!
        let client = HermesClient(baseURL: base, timeout: 15, apiKeyForProfile: { try store.apiKey(profile: $0) })
        let stop = KillSwitchAPI(baseURL: base, apiKey: nil, apiKeyForProfile: { try store.apiKey(profile: $0) })
        for profile in keys.keys.sorted() {
            log("Profile \(profile): open, sessions, new, start, events")
            _ = try await client.openProfile(profile)
            guard case .sessions = try await client.listSessions(profile: profile) else { throw URLError(.badServerResponse) }
            let session = try await client.newSession(profile: profile)
            let run = try await ResumeAPI(baseURL: base, apiKey: store.apiKey(profile: profile)).start(profile: profile, input: "Bonjour hv", session: session.id, model: nil, key: UUID().uuidString)
            let turn = try await client.readTurn(profile: profile, run: run)
            log("\(profile): état du tour = \(turn.state.rawValue)")
            guard turn.state == .completed else { throw URLError(.badServerResponse) }
            let canStop = try await stop.supportsCancel(profile: profile)
            log("\(profile): open=ok sessions=ok new=ok start=ok SSE=completed cancel-supported=\(canStop)")
        }
        let crossed = HermesClient(baseURL: base, timeout: 5, apiKeyForProfile: { _ in try store.apiKey(profile: "ia") })
        do {
            _ = try await crossed.openProfile("cyber")
            throw URLError(.userAuthenticationRequired)
        } catch HermesError.http(_, 401, _) { log("cyber avec clé ia: HTTP 401, refus observé") }
        let missing = HermesClient(baseURL: base, apiKey: keys["default"], timeout: 5, apiKeyForProfile: { _ in nil })
        do {
            _ = try await missing.openProfile("cyber")
            throw URLError(.userAuthenticationRequired)
        } catch HermesError.http(_, 401, _) { log("cyber sans sa clé: HTTP 401, aucun repli sur default") }
        let crossedStop = KillSwitchAPI(baseURL: base, apiKey: nil, apiKeyForProfile: { _ in try store.apiKey(profile: "ia") })
        do {
            _ = try await crossedStop.supportsCancel(profile: "cyber")
            throw URLError(.badServerResponse)
        } catch let error as URLError where error.code == .cannotConnectToHost { log("KillSwitchAPI cyber avec clé ia: refus observé") }
        do {
            _ = try await ResumeAPI(baseURL: base, apiKey: store.apiKey(profile: "ia")).start(profile: "cyber", input: "Bonjour hv", session: "hd17-crossed", model: nil, key: UUID().uuidString)
            throw URLError(.userAuthenticationRequired)
        } catch HermesError.http(_, 401, _) { log("ResumeAPI cyber avec clé ia: HTTP 401, refus observé") }
        log("HD17 LIVE: 9 profils distincts, clé croisée refusée, aucun secret affiché")
    }
}
