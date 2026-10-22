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

    enum State: Equatable {
        case ready
        case stopping
        case settled(Int, Int)
        case unavailable(String)
    }

    static let fallback = "Couper le tunnel n'arrête pas la VM. K3 : Ayo arrête le gateway du profil sur la VM. Voir docs/runbook/kill-switch.md."
    private(set) var state = State.ready
    private var stateConnection = ""
    private let endpoint: @MainActor () -> KillSwitchAPI?
    private let connection: @MainActor () -> String
    private let runs: @MainActor () -> [Run]
    private let profiles: @MainActor () -> [String]
    private let confirmed: @MainActor (Run, String) -> Void
    private let pending: @MainActor () -> Bool
    private let setStopping: @MainActor (Bool) -> Void
    private let cancel: @MainActor (KillSwitchAPI, Run) async throws -> String

    init(endpoint: @escaping @MainActor () -> KillSwitchAPI?, connection: @escaping @MainActor () -> String,
         runs: @escaping @MainActor () -> [Run], profiles: @escaping @MainActor () -> [String],
         confirmed: @escaping @MainActor (Run, String) -> Void,
         pending: @escaping @MainActor () -> Bool = { false }, setStopping: @escaping @MainActor (Bool) -> Void = { _ in },
         cancel: @escaping @MainActor (KillSwitchAPI, Run) async throws -> String = { try await $0.cancel($1) }) {
        self.endpoint = endpoint
        self.connection = connection
        self.runs = runs
        self.profiles = profiles
        self.confirmed = confirmed
        self.pending = pending
        self.setStopping = setStopping
        self.cancel = cancel
    }

    var isStopping: Bool { state == .stopping }
    var isDisabled: Bool {
        if endpoint() == nil || isStopping { return true }
        if stateConnection == connection(), case .unavailable = state { return true }
        return false
    }
    var message: String {
        guard endpoint() != nil else { return Self.fallback }
        guard stateConnection == connection() else { return Self.fallback }
        switch state {
        case .ready: return Self.fallback
        case .stopping: return "Annulation demandée. Attente de la confirmation serveur…"
        case .settled(0, 0): return "Aucun tour en cours. Aucune annulation envoyée."
        case .settled(let cancelled, let other):
            return "Annulation confirmée par Hermes pour \(cancelled) tour(s). \(other) tour(s) déjà terminé(s)."
        case .unavailable(let reason): return "\(reason) \(Self.fallback)"
        }
    }

    func checkSupport() async {
        guard !isStopping else { return }
        let host = connection()
        stateConnection = host
        guard let api = endpoint() else { state = .unavailable("Liaison indisponible."); return }
        do {
            for profile in Set(profiles() + runs().map(\.profile)) {
                guard try await api.supportsCancel(profile: profile) else {
                    if host == connection(), !isStopping { state = .unavailable("cancel_run est désactivée pour \(profile).") }
                    return
                }
                guard host == connection(), !isStopping else { return }
            }
            if case .unavailable = state { state = .ready }
        } catch {
            if host == connection(), !isStopping { state = .unavailable("Hermes ne répond pas.") }
        }
    }

    func stopAll() async {
        guard !isDisabled, let api = endpoint() else { return }
        let host = connection()
        stateConnection = host
        state = .stopping
        setStopping(true)
        defer { setStopping(false) }
        let deadline = ContinuousClock.now + .seconds(5)
        while pending(), host == connection(), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        guard host == connection() else { state = .ready; return }
        let unstarted = pending()
        let targets = Set(runs())
        guard !targets.isEmpty else {
            state = unstarted ? .unavailable("Un démarrage reste sans réponse.") : .settled(0, 0)
            return
        }
        var cancelled = 0
        var other = 0
        var failed = unstarted
        let tasks = targets.map { run in
            Task { @MainActor in
                guard host == self.connection() else { return (run, Optional<String>.none) }
                return (run, try? await self.cancel(api, run))
            }
        }
        for task in tasks {
            let (run, result) = await task.value
            guard host == connection() else { continue }
            guard let result else { failed = true; continue }
            confirmed(run, result)
            if result == "cancelled" { cancelled += 1 } else { other += 1 }
        }
        guard host == connection() else { state = .ready; return }
        state = failed ? .unavailable("L'arrêt de tous les tours n'est pas confirmé.") : .settled(cancelled, other)
    }
}
