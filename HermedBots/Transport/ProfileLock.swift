import Foundation
import Observation

@Observable
@MainActor
final class ProfileLock {
    enum State: Equatable {
        case free
        case held
        case unknown

        var reason: String? {
            switch self {
            case .free: nil
            case .held: String(localized: "Hermes Desktop tient ce profil. Libérez-le dans Desktop avant de continuer.")
            case .unknown: String(localized: "Mode dégradé : la détection de Hermes Desktop est indisponible. Les écritures de ce profil sont bloquées.")
            }
        }
    }

    private struct Snapshot {
        let held: Set<String>
        let at: ContinuousClock.Instant
    }
    private var snapshots: [String: Snapshot] = [:]
    private var reads: [String: Int] = [:]
    private let connection: @MainActor () -> String
    private let read: @MainActor () async throws -> Data

    init(connection: @escaping @MainActor () -> String, read: @escaping @MainActor () async throws -> Data) {
        self.connection = connection
        self.read = read
    }

    func state(_ profile: String, on host: String? = nil) -> State {
        guard let snapshot = snapshots[host ?? connection()], ContinuousClock.now - snapshot.at < .seconds(3) else { return .unknown }
        return snapshot.held.contains(profile) ? .held : .free
    }

    func run() async {
        snapshots[connection()] = nil
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        let host = connection()
        reads[host, default: 0] += 1
        let revision = reads[host]!
        let held: Set<String>?
        do {
            struct Result: Decodable { let held: [String] }
            held = Set(try JSONDecoder().decode(Result.self, from: await read()).held)
        } catch {
            held = nil
        }
        guard !Task.isCancelled, host == connection(), reads[host] == revision else { return false }
        snapshots[host] = held.map { Snapshot(held: $0, at: .now) }
        return held != nil
    }

    func permits(_ profile: String, on host: String) async -> Bool {
        guard host == connection(), await refresh(), host == connection() else { return false }
        return state(profile, on: host) == .free
    }

    // La commande reste fixe : aucun nom de profil ni argument utilisateur n'entre dans le shell distant
    nonisolated static var command: String { "python3 -c '" + probe.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    nonisolated static let probe = #"""
import json
import os
from pathlib import Path
import psutil

held = set()
for process in psutil.process_iter():
    try:
        if process.uids().real != os.getuid():
            continue
        args = process.cmdline()
        if 'serve' not in args:
            continue
        env = process.environ()
        if env.get('HERMES_DESKTOP') != '1':
            continue
        home = Path(env.get('HERMES_HOME') or Path.home() / '.hermes').resolve()
        profile = home.name if home.parent.name == 'profiles' else 'default'
        for flag in ('--profile', '-p'):
            if flag in args[:args.index('serve')]:
                profile = args[args.index(flag) + 1]
        held.add(profile)
        for opened in process.open_files():
            path = Path(opened.path)
            if path.name in ('state.db', 'state.db-wal', 'state.db-shm') and path.parent.parent.name == 'profiles':
                held.add(path.parent.name)
    except psutil.NoSuchProcess:
        continue
print(json.dumps({'held': sorted(held)}))
"""#
}
