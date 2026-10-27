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

    var body: some View {
        VStack(spacing: 0) {
            ErrorBanner(model: model)
            DegradedBanner(map: model.capabilities)
            StopAllButton(model: model.killSwitch).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            NavigationSplitView {
                BotListView(model: model.bots, profileLock: model.profileLock, selectedSession: model.conversation.sessionID, select: model.conversation.select(bot:), open: model.conversation.open(session:of:))
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                    .safeAreaInset(edge: .bottom) {
                        HStack(spacing: 4) {
                            Text("Version de Hermes")
                            model.version.text.accessibilityID(.statusVersion)
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
                        .padding(8)
                    }
            } detail: {
                if model.conversation.botID != nil {
                    ConversationView(model: model.conversation, killSwitch: model.killSwitch)
                } else {
                    Text("Aucun bot sélectionné").foregroundStyle(.secondary)
                }
            }
        }
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
            while !Task.isCancelled {
                await model.killSwitch.checkSupport()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            model.reconnectAfterWake()
        }
        .task(id: "\(model.apiURL?.absoluteString ?? "")#\((model.bots.list.shown ?? []).map(\.id).joined(separator: ","))") {
            await model.conversation.restoreAvailable()
        }
        .task { await model.start() }
        .task(id: model.apiURL) {
            guard model.apiURL != nil else { return }
            await model.profileLock.run()
        }
        .task(id: "\(model.tunnel.state)#\(model.versionProfile ?? "")#\(model.bots.phase)") {
            await model.refreshVersion()
        }
        // la liste se relit tant qu'une adresse d'API existe ; une nouvelle adresse (tunnel rouvert) relance la lecture
        .task(id: model.apiURL) {
            guard model.apiURL != nil else { return }
            await model.bots.run()
        }
    }
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
