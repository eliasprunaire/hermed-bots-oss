import Foundation
import HermesAdapter
import Observation

struct KillSwitchAPI: Sendable {
    let baseURL: URL
    let apiKey: String?
    var apiKeyForProfile: (@Sendable (String) throws -> String?)? = nil

    private struct Reply: Decodable {
        let run_id: String?
        let status: String?
        let features: Features?
        struct Features: Decodable { let run_stop: Bool? }
    }

    private func request(_ profile: String, run: String? = nil, stop: Bool = false) async throws -> (Int, Reply) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let parts = ["p", profile, "v1"] + (run.map { ["runs", $0] } ?? ["capabilities"]) + (stop ? ["stop"] : [])
        components.percentEncodedPath = "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = stop ? "POST" : "GET"
        request.timeoutInterval = 5
        let key: String?
        if let apiKeyForProfile { key = try apiKeyForProfile(profile) }
        else { key = apiKey }
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Les erreurs HTTP ne garantissent aucune forme JSON
        let reply = (try? JSONDecoder().decode(Reply.self, from: data)) ?? Reply(run_id: nil, status: nil, features: nil)
        return (status, reply)
    }

    func supportsCancel(profile: String) async throws -> Bool {
        let (status, reply) = try await request(profile)
        if status >= 500 || status == 401 || status == 403 { throw URLError(.cannotConnectToHost) }
        return status == 200 && reply.features?.run_stop == true
    }

    func cancel(_ run: KillSwitch.Run) async throws -> String {
        let (status, reply) = try await request(run.profile, run: run.id, stop: true)
        guard (200..<300).contains(status), reply.run_id == run.id,
              ["stopping", "cancelled", "completed", "failed", "interrupted"].contains(reply.status) else { throw URLError(.badServerResponse) }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let (code, state) = try await request(run.profile, run: run.id, stop: false)
            guard code == 200, state.run_id == run.id, let value = state.status else { throw URLError(.badServerResponse) }
            if ["cancelled", "completed", "failed", "interrupted"].contains(value) { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw URLError(.timedOut)
    }
}

@Observable
@MainActor
final class KillSwitch {
    struct Run: Hashable, Sendable {
        let profile: String
        let id: String
    }

    static let partialStop = "Le tunnel est coupé, mais le service distant tourne peut-être encore."

    private enum Turn: Hashable {
        case run(Run)
        case start(UUID)
    }

    private struct ConnectionStop {
        var unconfirmed: Set<Turn> = []
        var unavailable = false
        var stopping = false
    }

    private var connections: [String: ConnectionStop] = [:]
    private let endpoint: @MainActor () -> KillSwitchAPI?
    private let connection: @MainActor () -> String
    private let runs: @MainActor () -> [Run]
    private let profiles: @MainActor () -> [String]
    private let confirmed: @MainActor (Run, String, String) -> Void
    private let pending: @MainActor () -> Bool
    private let setStopping: @MainActor (Bool) -> Void
    private let cancel: @MainActor (KillSwitchAPI, Run) async throws -> String
    private let canCancel: @MainActor (KillSwitchAPI, String) async throws -> Bool

    init(endpoint: @escaping @MainActor () -> KillSwitchAPI?, connection: @escaping @MainActor () -> String,
         runs: @escaping @MainActor () -> [Run], profiles: @escaping @MainActor () -> [String],
         confirmed: @escaping @MainActor (Run, String, String) -> Void,
         pending: @escaping @MainActor () -> Bool = { false }, setStopping: @escaping @MainActor (Bool) -> Void = { _ in },
         cancel: @escaping @MainActor (KillSwitchAPI, Run) async throws -> String = { try await $0.cancel($1) },
         canCancel: @escaping @MainActor (KillSwitchAPI, String) async throws -> Bool = { try await $0.supportsCancel(profile: $1) }) {
        self.endpoint = endpoint
        self.connection = connection
        self.runs = runs
        self.profiles = profiles
        self.confirmed = confirmed
        self.pending = pending
        self.setStopping = setStopping
        self.cancel = cancel
        self.canCancel = canCancel
    }

    var isStopping: Bool { connections[connection()]?.stopping == true }
    var isDisabled: Bool {
        if endpoint() == nil || isStopping { return true }
        return connections[connection()]?.unavailable == true
    }
    var message: String {
        connections[connection()]?.unconfirmed.isEmpty == false ? Self.partialStop : ""
    }

    private func update(_ host: String, _ body: (inout ConnectionStop) -> Void) {
        var value = connections[host] ?? ConnectionStop()
        body(&value)
        connections[host] = value
        setStopping(connections.values.contains(where: \.stopping))
    }

    func checkSupport() async {
        let host = connection()
        guard connections[host]?.stopping != true else { return }
        guard let api = endpoint() else {
            update(host) { $0.unavailable = true }
            return
        }
        do {
            for profile in Set(profiles() + runs().map(\.profile)) {
                guard try await canCancel(api, profile) else {
                    if host == connection(), connections[host]?.stopping != true {
                        update(host) { $0.unavailable = true }
                    }
                    return
                }
                guard host == connection(), connections[host]?.stopping != true else { return }
            }
            if host == connection() { update(host) { $0.unavailable = false } }
        } catch {
            if host == connection(), connections[host]?.stopping != true {
                update(host) { $0.unavailable = true }
            }
        }
    }

    func stopAll() async {
        let host = connection()
        guard connections[host]?.stopping != true else { return }
        guard let api = endpoint(), connections[host]?.unavailable != true else {
            update(host) {
                for run in runs() { $0.unconfirmed.insert(.run(run)) }
                if pending() { $0.unconfirmed.insert(.start(UUID())) }
            }
            return
        }
        update(host) { $0.stopping = true }
        defer { update(host) { $0.stopping = false } }
        var targets = Set(runs())
        let waiting = pending()
        let start = waiting ? UUID() : nil
        let deadline = ContinuousClock.now + .seconds(5)
        while pending(), connection() == host, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        let stayed = connection() == host
        if stayed { targets = Set(runs()) }
        if let start, !stayed || pending() {
            update(host) { $0.unconfirmed.insert(.start(start)) }
        }
        let tasks = targets.map { run in
            Task { @MainActor in
                (run, try? await self.cancel(api, run))
            }
        }
        for task in tasks {
            let (run, result) = await task.value
            if let result {
                confirmed(run, result, host)
                update(host) { $0.unconfirmed.remove(.run(run)) }
            } else {
                update(host) { $0.unconfirmed.insert(.run(run)) }
            }
        }
    }
}
