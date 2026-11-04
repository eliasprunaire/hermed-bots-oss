import AppSettings
import HermesAdapter
import LoopGuard
import Observation
import SwiftUI
import Sparkle
import UpdateCheck

extension View {
    func accessibilityID(_ id: AccessibilityID) -> some View { accessibilityIdentifier(id.rawValue) }
}

extension AppModel.Version {
    var text: Text {
        switch self {
        case .loading: Text(verbatim: "…")
        case .known(let version): Text(verbatim: version)
        case .unknown: Text("inconnue")
        }
    }
}

struct ContentView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            // pied sous la liste, pas en safeAreaInset : une ligne glissée sous un pied opaque reste « atteignable » pour XCUITest mais le clic tombe sur le pied
            VStack(spacing: 0) {
                BotListView(model: model.bots, profileLock: model.profileLock, selectedBot: model.conversation.botID,
                            activity: model.conversation.activity(of:), select: model.conversation.activate(bot:))
                SidebarFooter(model: model)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                ErrorBanner(model: model)
                DegradedBanner(map: model.capabilities)
                if let bot = shownBot {
                    ConversationView(model: model.conversation, killSwitch: model.killSwitch, bot: bot)
                } else {
                    HomeView(bots: model.bots, profileLock: model.profileLock, activity: model.conversation.activity(of:), needsConnection: needsConnection,
                             open: open(bot:), configure: { openSettings() })
                }
            }
            .overlay(alignment: .top) { ConnectingPill(model: model) }
            // dans la barre d'outils et non dans la barre latérale : l'arrêt reste visible quand l'utilisateur masque la barre latérale
            .toolbar {
                ToolbarItem(placement: .primaryAction) { StopAllButton(model: model.killSwitch) }
            }
            .animation(.easeOut(duration: 0.2), value: model.isCheckingAPI)
        }
        .frame(minWidth: 720, minHeight: 480)
        .environment(\.motion, !model.isTestMode && !reduceMotion)
        .preferredColorScheme(model.testDarkAppearance ? .dark : nil)
        .background { if let size = model.testWindowSize { TestWindowSize(size: size) } }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            if let watch = model.mainThreadWatch {
                HangProbe(watch: watch, conversation: model.conversation, hangMilliseconds: model.testHangMilliseconds)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.mainThreadWatch != nil {
                ModelSwitchProbe(conversation: model.conversation)
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(model.conversation.storedResumeState)
                    .accessibilityID(.resumeState)
            }
        }
        #endif
        .task(id: "\(model.apiURL?.absoluteString ?? "")#\((model.bots.list.shown ?? []).map(\.id).joined(separator: ","))") {
            guard !model.isShotPreview else { return }
            while !Task.isCancelled {
                await model.killSwitch.checkSupport()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            model.reconnectAfterWake()
        }
        .task(id: "\(model.apiURL?.absoluteString ?? "")#\((model.bots.list.shown ?? []).map(\.id).joined(separator: ","))") {
            guard !model.isShotPreview else { return }
            await model.conversation.restoreAvailable()
        }
        .task { if !model.isShotPreview { await model.start() } }
        .task(id: model.apiURL) {
            guard !model.isShotPreview, model.apiURL != nil else { return }
            await model.profileLock.run()
        }
        .task(id: "\(model.tunnel.state)#\(model.versionProfile ?? "")#\(model.bots.phase)") {
            if !model.isShotPreview { await model.refreshVersion() }
        }
        // la liste se relit tant qu'une adresse d'API existe ; une nouvelle adresse (tunnel rouvert) relance la lecture
        .task(id: model.apiURL) {
            guard !model.isShotPreview, model.apiURL != nil else { return }
            await model.bots.run()
        }
    }
}

extension ContentView {
    /// Le bot ouvert, tel que la liste le montre ; un bot sorti de la liste garde son identifiant pour nom
    private var shownBot: Bot? {
        guard let id = model.conversation.botID else { return nil }
        return model.bots.list.shown?.first { $0.id == id } ?? Bot(id: id, name: id, model: nil)
    }

    /// Aucune adresse d'API, et aucun tunnel en train de s'ouvrir : l'accueil propose la connexion
    private var needsConnection: Bool {
        switch model.tunnel.state {
        case .opening, .reopening: false
        case .idle, .open, .failed: model.apiURL == nil
        }
    }

    /// Une carte de l'accueil ouvre le fil unique du bot
    private func open(bot id: String) {
        model.conversation.activate(bot: id)
    }
}

/// Le pied de la barre latérale : pastille de santé, mention discrète de compatibilité, version pour les tests, réglages
private struct SidebarFooter: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StopAllStatus(model: model.killSwitch)
            HStack(spacing: 6) {
                Circle()
                    .fill(health)
                    .frame(width: 7, height: 7)
                    .shadow(color: health.opacity(0.7), radius: 3)
                    .accessibilityHidden(true)
                Text(footerLabel)
                    .accessibilityID(.statusCompat)
                model.version.text.accessibilityID(.statusVersion)
                if let port = model.displayedPort {
                    Text(verbatim: port.statusText).accessibilityID(.statusPort)
                }
                Spacer()
                SettingsLink {
                    Label("Réglages", systemImage: "gearshape").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Réglages")
                .accessibilityID(.connectionOpen)
            }
            .lineLimit(1)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.bar)
    }

    private var status: CompatibilityStatus {
        CompatibilityStatus.of(
            map: model.capabilities,
            checking: model.isCheckingAPI || model.conversation.isOpening,
            hasError: model.apiError != nil || model.conversation.openError != nil || {
                if case .failed = model.tunnel.state { return true }
                return false
            }()
        )
    }

    private var footerLabel: String {
        var label = CompatibilityStatus.footerLabel(status: status, tunnelFailed: tunnelFailed)
        if status == .ready, model.conversation.compaction.percent > 0 {
            let compaction = model.conversation.compaction
            label += " · contexte \(compaction.percent) %"
            if compaction.source == .estimate { label += " (estimation)" }
        }
        return label
    }

    private var tunnelFailed: Bool {
        if case .failed = model.tunnel.state { return true }
        #if DEBUG
        return model.testTunnelFailed
        #else
        return false
        #endif
    }

    /// Vert : prêt ; bleu info : version non testée ; rouge : échec ; orange : connexion
    private var health: Color {
        switch status {
        case .ready: .green
        case .untested: .blue
        case .failed: .red
        case .connecting: .orange
        }
    }
}

/// Mode test seulement : donne au contenu de la fenêtre la taille de `HV_WINDOW_SIZE` dès que la vue rejoint sa fenêtre
/// Une taille gardée par un lancement précédent l'emporterait sur `defaultSize`, d'où la fenêtre réglée ici
private struct TestWindowSize: NSViewRepresentable {
    let size: CGSize

    final class Sizer: NSView {
        var size = CGSize.zero
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isRestorable = false
            // au tour suivant : macOS pose le cadre restauré après l'arrivée de la vue dans la fenêtre
            DispatchQueue.main.async { [size] in window.setContentSize(size) }
        }
    }

    func makeNSView(context: Context) -> Sizer {
        let view = Sizer()
        view.size = size
        return view
    }

    func updateNSView(_ view: Sizer, context: Context) {}
}

#if DEBUG
/// Mode test seulement : un point sans pixel dont l'étiquette porte le rapport du chien de garde du fil principal
/// Avec `HV_HANG_MS`, il bloque aussi le fil principal au départ de chaque tour : c'est le contrôle positif de la sonde de perf
private struct HangProbe: View {
    let watch: MainThreadWatch
    let conversation: ConversationModel
    let hangMilliseconds: Int

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(watch.report)
            .accessibilityID(.perfHang)
            .onChange(of: conversation.conversation.phase) { _, phase in
                if phase == .running, hangMilliseconds > 0 { Thread.sleep(forTimeInterval: Double(hangMilliseconds) / 1000) }
            }
    }
}

/// Mode test seulement : un point sans pixel dont l'étiquette liste, en ms, chaque durée du clic sur l'option de modèle (tel que l'app le reçoit) au modèle confirmé dans le sélecteur
private struct ModelSwitchProbe: View {
    let conversation: ConversationModel

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel(conversation.pickMilliseconds.map(String.init).joined(separator: ","))
            .accessibilityID(.perfModel)
            .onChange(of: conversation.shownModel) { conversation.selectorShowsModel() }
    }
}
#endif

@main
struct HermedBotsApp: App {
    #if !DEBUG
    private let sparkleDelegate: SparkleCycleDelegate
    private let updater: SPUStandardUpdaterController
    #endif
    @State private var model: AppModel

    init() {
        let environment = AppEnvironment.resolve(ProcessInfo.processInfo.environment)
        let notifyPause: @Sendable (LoopGuard.Cause) async -> String = { await LoopPauseNotifications.shared.post(cause: $0) }
        #if DEBUG
        let updates = UpdateCheck(driver: NullUpdateDriver())
        _model = State(initialValue: AppModel(environment: environment, updates: updates, notifyPause: notifyPause))
        #else
        let driver = SparkleUpdateDriver()
        let updates = UpdateCheck(driver: driver)
        let delegate = SparkleCycleDelegate(updates: updates)
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        driver.attach(updater)
        updater.startUpdater()
        sparkleDelegate = delegate
        self.updater = updater
        _model = State(initialValue: AppModel(environment: environment, updates: updates, notifyPause: notifyPause))
        #endif
    }

    var body: some Scene {
        Window("Hermed Bots", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(SettingsCopy.checkForUpdates) { model.checkForUpdates() }
                    .disabled(!model.canCheckForUpdates)
            }
        }
        Settings {
            SettingsWindow(model: model)
        }
        .defaultSize(width: SettingsLayout.defaultWidth, height: SettingsLayout.defaultHeight)
    }
}
