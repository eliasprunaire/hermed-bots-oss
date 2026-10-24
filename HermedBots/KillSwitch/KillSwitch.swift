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

    private func request(_ profile: String, run: String? = nil, stop: Bool = false, allow: @escaping @Sendable () async -> Bool = { true }) async throws -> (Int, Reply) {
        guard await allow() else { throw URLError(.cancelled) }
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

    func supportsCancel(profile: String, allow: @escaping @Sendable () async -> Bool = { true }) async throws -> Bool {
        let (status, reply) = try await request(profile, allow: allow)
        if status >= 500 || status == 401 || status == 403 { throw URLError(.cannotConnectToHost) }
        return status == 200 && reply.features?.run_stop == true
    }

    func cancel(_ run: KillSwitch.Run, allow: @escaping @Sendable () async -> Bool = { true }) async throws -> String {
        let (status, reply) = try await request(run.profile, run: run.id, stop: true, allow: allow)
        guard (200..<300).contains(status), reply.run_id == run.id,
              ["stopping", "cancelled", "completed", "failed", "interrupted"].contains(reply.status) else { throw URLError(.badServerResponse) }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            let (code, state) = try await request(run.profile, run: run.id, stop: false, allow: allow)
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
        var turn = ""
    }

    static let partialStop = "Le tunnel est coupé, mais le service distant tourne peut-être encore."

    private enum Turn: Hashable {
        case run(Run)
        case start(String)
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
    private let pending: @MainActor () -> [String]
    private let startWait: Duration
    private let setStopping: @MainActor (Bool) -> Void
    private let cancel: @MainActor (KillSwitchAPI, Run, @MainActor () -> Bool) async throws -> String
    private let canCancel: @MainActor (KillSwitchAPI, String, @MainActor () -> Bool) async throws -> Bool

    init(endpoint: @escaping @MainActor () -> KillSwitchAPI?, connection: @escaping @MainActor () -> String,
         runs: @escaping @MainActor () -> [Run], profiles: @escaping @MainActor () -> [String],
         confirmed: @escaping @MainActor (Run, String, String) -> Void,
         pending: @escaping @MainActor () -> [String] = { [] }, startWait: Duration = .seconds(5),
         setStopping: @escaping @MainActor (Bool) -> Void = { _ in },
         cancel: @escaping @MainActor (KillSwitchAPI, Run, @MainActor () -> Bool) async throws -> String = { api, run, allow in
             try await api.cancel(run, allow: { await MainActor.run { allow() } })
         },
         canCancel: @escaping @MainActor (KillSwitchAPI, String, @MainActor () -> Bool) async throws -> Bool = { api, profile, allow in
             try await api.supportsCancel(profile: profile, allow: { await MainActor.run { allow() } })
         }) {
        self.endpoint = endpoint
        self.connection = connection
        self.runs = runs
        self.profiles = profiles
        self.confirmed = confirmed
        self.pending = pending
        self.startWait = startWait
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
        let onHost = { self.connection() == host }
        do {
            for profile in Set(profiles() + runs().map(\.profile)) {
                guard try await canCancel(api, profile, onHost) else {
                    if onHost(), connections[host]?.stopping != true {
                        update(host) { $0.unavailable = true }
                    }
                    return
                }
                guard onHost(), connections[host]?.stopping != true else { return }
            }
            if onHost() { update(host) { $0.unavailable = false } }
        } catch {
            if onHost(), connections[host]?.stopping != true {
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
                for turn in pending() { $0.unconfirmed.insert(.start(turn)) }
            }
            return
        }
        update(host) { $0.stopping = true }
        defer { update(host) { $0.stopping = false } }
        var targets = Set(runs())
        let waiting = pending()
        let deadline = ContinuousClock.now + startWait
        while !pending().isEmpty, connection() == host, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        let stayed = connection() == host
        if stayed { targets = Set(runs()) }
        let unresolved = stayed ? pending() : waiting
        if !unresolved.isEmpty { update(host) { for turn in unresolved { $0.unconfirmed.insert(.start(turn)) } } }
        let onHost = { self.connection() == host }
        let tasks = targets.map { run in
            Task { @MainActor () -> (Run, String?) in
                (run, try? await self.cancel(api, run, onHost))
            }
        }
        for task in tasks {
            let (run, result) = await task.value
            if let result {
                confirmed(run, result, host)
                update(host) {
                    $0.unconfirmed.remove(.run(run))
                    $0.unconfirmed.remove(.start(run.turn))
                }
            } else {
                update(host) { $0.unconfirmed.insert(.run(run)) }
            }
        }
    }
}
