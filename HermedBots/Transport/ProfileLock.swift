import Foundation
import Observation

@Observable
@MainActor
final class ProfileLock {
    enum State: Equatable {
        case free
        case held
        /// Aucune sonde, ou sonde pas encore revenue
        case unknown
        /// La sonde a constaté que la détection de Hermes Desktop est indisponible
        case degraded

        var reason: String? {
            switch self {
            case .free, .unknown: nil
            case .held: String(localized: "Hermes Desktop tient ce profil. Libérez-le dans Desktop avant de continuer.")
            case .degraded: String(localized: "Mode dégradé : la détection de Hermes Desktop est indisponible. Les écritures de ce profil sont bloquées.")
            }
        }

        /// Pastille courte de la carte et de la barre latérale ; le bandeau de conversation garde `reason`
        var sidebarLabel: String? {
            switch self {
            case .free, .unknown: nil
            case .held: String(localized: "Tenu par Desktop")
            case .degraded: String(localized: "Dégradé")
            }
        }
    }

    private struct Snapshot {
        let held: Set<String>
        let at: ContinuousClock.Instant
    }
    private var snapshots: [String: Snapshot] = [:]
    /// Hôtes dont la dernière sonde a échoué : l'état runtime reste inconnu, l'écran montre la dégradation
    private var unavailable: Set<String> = []
    /// Pourquoi la dernière lecture de cet hôte a échoué ; absent quand elle a réussi ou que l'erreur n'a rien à dire
    private var causes: [String: String] = [:]
    private var applied: [String: ContinuousClock.Instant] = [:]
    private var inflight: [String: Task<Bool, Never>] = [:]
    private var generations: [String: Int] = [:]
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

    /// L'état montré : dégradé seulement si une sonde l'a constaté, pas si le verrou est encore inconnu
    func shownState(_ profile: String, on host: String? = nil) -> State {
        let key = host ?? connection()
        if unavailable.contains(key) { return .degraded }
        return state(profile, on: key)
    }

    /// Le texte de `shownState(_:on:).reason`, suivi de la cause de la panne de la sonde quand elle est connue
    func reason(_ profile: String, on host: String? = nil) -> String? {
        let shown = shownState(profile, on: host)
        guard shown == .degraded, let base = shown.reason, let cause = causes[host ?? connection()] else { return shown.reason }
        return base + "\n" + String(localized: "Cause : \(cause)")
    }

    /// Pastille de la carte et de la barre latérale pour ce profil ; nil s'il est libre ou inconnu
    func sidebarLabel(_ profile: String, on host: String? = nil) -> String? {
        shownState(profile, on: host).sidebarLabel
    }

    #if DEBUG
    /// Capture : la sonde a constaté la dégradation, sans lancer de lecture
    func seedDegraded() {
        unavailable.insert(connection())
    }
    #endif

    func run() async {
        let host = connection()
        snapshots[host] = nil
        unavailable.remove(host)
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        let host = connection()
        if let existing = inflight[host] {
            return await existing.value
        }
        let started = ContinuousClock.now
        let generation = generations[host, default: 0] + 1
        generations[host] = generation
        let task = Task { @MainActor in await self.finish(host: host, started: started) }
        inflight[host] = task
        let ok = await task.value
        if generations[host] == generation {
            inflight[host] = nil
        }
        return ok
    }

    private func finish(host: String, started: ContinuousClock.Instant) async -> Bool {
        let held: Set<String>?
        var cause: String?
        do {
            struct Result: Decodable { let held: [String] }
            held = Set(try JSONDecoder().decode(Result.self, from: await read()).held)
        } catch {
            held = nil
            cause = Self.cause(of: error)
        }
        guard !Task.isCancelled, host == connection() else { return false }
        if let previous = applied[host], previous > started {
            return snapshots[host] != nil
        }
        applied[host] = started
        if let held {
            snapshots[host] = Snapshot(held: held, at: .now)
            unavailable.remove(host)
        } else {
            snapshots[host] = nil
            unavailable.insert(host)
        }
        causes[host] = cause
        return held != nil
    }

    /// Cause affichée pour un hôte injoignable : vouvoiement, sans ligne technique brute
    static let unreachableCause = String(localized: "hôte injoignable. Vérifiez le réseau, puis réessayez.")

    private static func cause(of error: Error) -> String? {
        switch error {
        case let failure as ProfileProbeFailure:
            return failure.message
        case let failure as SSHFailure:
            switch failure {
            case .tunnelClosed:
                return nil
            case .unreachable(let detail):
                if detail == "délai dépassé" { return String(localized: "la machine Hermes ne répond pas") }
                return unreachableCause
            default:
                return failure.message
            }
        default:
            return nil
        }
    }

    func permits(_ profile: String, on host: String) async -> Bool {
        guard host == connection() else { return false }
        switch state(profile, on: host) {
        case .free: return true
        case .held: return false
        case .unknown, .degraded:
            _ = await refresh()
            guard host == connection() else { return false }
            return state(profile, on: host) == .free
        }
    }

    /// Code de sortie de la sonde quand `psutil` manque : le lanceur essaie alors `python3`, puis l'app nomme le module
    nonisolated static let moduleMissingStatus: Int32 = 3

    // La commande reste fixe : aucun nom de profil ni argument utilisateur n'entre dans le shell distant
    // Elle passe par le shell de connexion, comme `hermes` : le PATH du profil de l'hôte (dossier bin personnel, environnement de Hermes) s'applique
    nonisolated static var command: String { RemoteShell.loginCommand(["sh", "-c", launcher, "hb-probe", probe]) }

    /// Lance la sonde (`$1`) avec l'interpréteur de Hermes ; sans lui, ou s'il rend 3 (module absent), avec `python3`
    /// L'interpréteur se lit comme le lanceur `libexec/hermes` le calcule : liens suivis, `<racine>/.venv/bin/python` avec `<racine>` au-dessus du dossier du lanceur
    /// À défaut, la ligne #! d'un script `hermes` en Python
    /// Un autre code de l'interpréteur de Hermes est rendu tel quel : le repli ne masque pas une vraie erreur
    // shortcut: deux dispositions de Hermes sont reconnues (lanceur avec .venv, script Python), à remplacer par un chemin d'interpréteur réglable si une autre apparaît
    nonisolated static let launcher = #"""
    interpreter=
    tool=$(command -v hermes 2>/dev/null)
    if [ -f "$tool" ] && [ -r "$tool" ]; then
      self=$tool
      while [ -L "$self" ]; do
        target=$(readlink "$self")
        case $target in
          /*) self=$target ;;
          *) self=$(dirname "$self")/$target ;;
        esac
      done
      root=$(cd "$(dirname "$self")/.." 2>/dev/null && pwd)
      if [ -n "$root" ] && [ -x "$root/.venv/bin/python" ]; then
        interpreter=$root/.venv/bin/python
      else
        IFS= read -r first < "$tool"
        case $first in
          '#!'/*)
            interpreter=${first#'#!'}
            interpreter=${interpreter%% *}
            case ${interpreter##*/} in python*) ;; *) interpreter= ;; esac ;;
        esac
      fi
    fi
    if [ -n "$interpreter" ] && [ -x "$interpreter" ]; then
      "$interpreter" -c "$1"
      status=$?
      [ "$status" -eq 3 ] || exit "$status"
    fi
    exec python3 -c "$1"
    """#

    nonisolated static let probe = #"""
import json
import os
from pathlib import Path
import sys

try:
    import psutil
except ImportError:
    sys.stderr.write('module psutil absent\n')
    sys.exit(3)

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

/// Pourquoi la sonde de Hermes Desktop n'a pas répondu ; sa sortie d'erreur n'est pas gardée ici, elle va au journal local
enum ProfileProbeFailure: Error, Equatable, Sendable {
    /// Ni l'interpréteur de Hermes ni `python3` n'a le module
    case moduleMissing(String)
    /// Le shell de connexion de l'hôte ne trouve pas `python3` (code 127)
    case toolNotFound
    case failed(status: Int32)
    case timedOut

    /// La cause, pour la fin du message du verrou de profil
    var message: String {
        switch self {
        case .moduleMissing(let name): String(localized: "le module Python \(name) est absent de l'interpréteur de Hermes et de python3 sur l'hôte")
        case .toolNotFound: String(localized: "python3 est introuvable dans le PATH du shell de connexion de l'hôte")
        case .failed(let status): String(localized: "la sonde a échoué (code \(status))")
        case .timedOut: String(localized: "la sonde n'a pas répondu à temps")
        }
    }
}
