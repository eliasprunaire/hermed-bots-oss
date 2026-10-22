import AppKit
import XCTest

/// Les six actions du PRD, vues par la barre latérale et la conversation : la liste des bots et leurs fils passés (HD-08), puis discuter et ouvrir une nouvelle session (HD-09)
/// Le faux serveur est lu sans l'app, par `HV_API_URL` : `/_hv/profile-list` donne la liste attendue, `/_hv/log` les requêtes reçues
@MainActor
final class SixActions: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var apiURL: String? { environment["HV_API_URL"] }

    // un test qui a échoué avant sa fin a laissé ses événements injectés : chaque test repart d'un flux sans eux
    override func setUp() {
        continueAfterFailure = false
        FakeServer.reset()
    }

    // MARK: outils

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_RESUME_SCOPE"] = UUID().uuidString
        for name in ["HV_API_URL", "HV_TEST_API_KEY", "HV_TEST_API_KEYS", "HV_SSH_HOST", "HV_SSH_USER", "HV_TEST_SSH_KEY"] {
            if let value = environment[name] { app.launchEnvironment[name] = value }
        }
        app.launch()
        return app
    }

    // un prédicat et non `matching(identifier:)` : XCUITest refuse une chaîne de plus de 128 caractères, et l'id d'un bot de 300 caractères en fait davantage
    private func element(_ id: String, in root: XCUIElementQuery) -> XCUIElement {
        root.matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        element(id, in: app.descendants(matching: .any))
    }

    private func element(_ id: AccessibilityID, in app: XCUIApplication) -> XCUIElement { element(id.rawValue, in: app) }

    private func count(_ id: String, in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).count
    }

    // SwiftUI expose le texte tantôt en valeur, tantôt en libellé
    private func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    /// Les identifiants des lignes de bot affichées : `hd.bots.row.<id>`, sans `.name`, `.model` ni `.threads`
    private func shownBotIDs(in app: XCUIApplication) -> Set<String> {
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", #"hd\.bots\.row\.[^.]+"#))
        return Set(rows.allElementsBoundByIndex.map { String($0.identifier.dropFirst("hd.bots.row.".count)) })
    }

    private func waitForRows(in app: XCUIApplication, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while shownBotIDs(in: app).isEmpty, Date() < deadline { usleep(100_000) }
    }

    private func serverData(_ path: String) -> Data? {
        guard let apiURL, let url = URL(string: apiURL + path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Les POST qui envoient ou créent quelque chose : la sonde inerte du sélecteur de modèle (`hd-probe-capabilities`, HD-10) vise une session qui n'existe pas et ne crée ni n'envoie rien
    private func sendingPosts(_ log: [Request]) -> [Request] {
        log.filter { $0.method == "POST" && !$0.isCapabilityProbe && !$0.path.contains("hd-probe-capabilities") }
    }

    private func serverMode() -> String? {
        guard let data = serverData("/_hv/ready"), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return body["mode"] as? String
    }

    private func configureFake(mode: String = "normal", drop: String = "set_model", profiles: [String]? = nil) throws {
        try XCTSkipIf(serverMode() == nil, "Ce scénario exige les contrôles du faux serveur")
        FakeServer.configure(mode: mode, drop: drop, profiles: profiles)
        addTeardownBlock { FakeServer.configure() }
    }

    private struct Request {
        let method: String
        let path: String
        /// Le statut HTTP que le faux serveur a rendu (une requête coupée par `/_hv/cut` y est un 503) ; nil pour une entrée sans statut
        let status: Int?
        let isCapabilityProbe: Bool
    }

    /// Les requêtes que le serveur a reçues depuis `since` : le journal garde aussi celles des passes précédentes
    private func serverLog(since: Date) -> [Request] {
        guard let data = serverData("/_hv/log"), let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let method = entry["m"] as? String, let path = entry["p"] as? String, let time = entry["t"] as? Double, time >= since.timeIntervalSince1970 else { return nil }
            return Request(method: method, path: path, status: entry["s"] as? Int, isCapabilityProbe: entry["probe"] as? Bool ?? false)
        }
    }

    /// Les profils actifs que le serveur annonce, lus à part : le Gateway `stopped` est décommissionné
    /// nil quand le serveur n'a pas de `/_hv/profile-list` (orb)
    private func activeProfileIDs() -> Set<String>? {
        guard let data = serverData("/_hv/profile-list") else { return nil }
        var ids = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count >= 3, words[0] != "Profile", !line.contains("───") else { continue }
            let id = String(words[0].drop { $0 == "◆" })
            if words[2] != "stopped", !id.isEmpty { ids.insert(id) }
        }
        return ids
    }

    private func expected(_ name: String, default fallback: [String]) -> [String] {
        environment[name].map { $0.split(separator: ",").map(String.init) } ?? fallback
    }

    func testResumeAfterSleep() {
        defer { FakeServer.cut(seconds: 0) }
        let app = launch()
        let since = Date()
        let bot = element("hd.bots.row.hv-bot-a", in: app)
        XCTAssertTrue(bot.waitForExistence(timeout: 20))
        bot.click()
        let input = element(.composerInput, in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("HV_SLOW go")
        element(.composerSend, in: app).click()
        XCTAssertTrue(element(.conversationView, in: app).waitForExistence(timeout: 10))
        usleep(1_500_000)
        FakeServer.cut(seconds: 10)
        let state = element(.conversationState, in: app)
        XCTAssertTrue(state.waitForExistence(timeout: 35))
        XCTAssertTrue(text(of: state).contains("terminé"))
        let starts = serverLog(since: since).filter { $0.method == "POST" && $0.path.hasSuffix("/v1/runs") && !$0.isCapabilityProbe && $0.status == 202 }
        XCTAssertEqual(starts.count, 1)
        HVShot.capture("hd13-cut", app)
    }

    // MARK: la liste

    func testListBots() {
        let app = launch()
        let wanted = ["hv-bot-a", "hv-bot-b"]
        XCTAssertTrue(element(AccessibilityID.botRow(wanted[0]), in: app).waitForExistence(timeout: 20), "hd.bots.row.hv-bot-a absent")
        for id in wanted {
            XCTAssertTrue(element(AccessibilityID.botRow(id), in: app).exists, "hd.bots.row.\(id) absent")
            // un identifiant désigne un seul élément : ni la ligne, ni son nom, ni son modèle ne le prêtent aux autres
            for identifier in [AccessibilityID.botRow(id), AccessibilityID.botName(id), AccessibilityID.botModel(id)] {
                XCTAssertEqual(count(identifier, in: app), 1, "\(identifier) désigne \(count(identifier, in: app)) éléments")
            }
            XCTAssertEqual(text(of: element(AccessibilityID.botName(id), in: app)), id)
            XCTAssertFalse(text(of: element(AccessibilityID.botModel(id), in: app)).isEmpty, "le modèle de \(id) est vide")
        }
        XCTAssertEqual(count(AccessibilityID.botsList.rawValue, in: app), 1)
        XCTAssertFalse(element(.botsEmpty, in: app).exists, "le message « aucun bot » reste affiché avec des bots")
        print("HV-BOTS rows=\(shownBotIDs(in: app).sorted())")
        HVShot.capture("hd08-bots", app)
    }

    /// Lane 2 : aucun profil décommissionné, et tous les actifs (pas une liste épinglée)
    func testADecommissionedProfileIsNeverListedAndEveryActiveOneIs() throws {
        let absent = expected("HV_EXPECT_ABSENT", default: ["hv-old"])
        let app = launch()
        waitForRows(in: app)
        // le dernier relevé peut arriver après la première ligne : une ligne de plus ne se rattrape pas, on laisse la liste se poser
        usleep(1_500_000)
        for id in absent { XCTAssertFalse(element(AccessibilityID.botRow(id), in: app).exists, "hd.bots.row.\(id) existe") }
        if let active = activeProfileIDs() {
            XCTAssertEqual(shownBotIDs(in: app), active, "la liste affichée n'est pas celle des profils actifs du serveur")
        }
        print("HV-BOTS no-old absent=\(absent) rows=\(shownBotIDs(in: app).sorted())")
        HVShot.capture("hd08-no-old", app)
    }

    /// Lane 8 : l'instance OrbStack, les profils du PRD sont tous là et le profil parqué n'y est pas
    func testTheSeededProfilesOfTheOrbInstanceShowAndTheParkedOneDoesNot() throws {
        let wanted = expected("HV_EXPECT_BOTS", default: [])
        try XCTSkipIf(wanted.isEmpty, "HV_EXPECT_BOTS absent : pas d'instance OrbStack à lire")
        let absent = expected("HV_EXPECT_ABSENT", default: ["hv-old"])
        let app = launch()
        XCTAssertTrue(element(AccessibilityID.botRow(wanted[0]), in: app).waitForExistence(timeout: 30), "hd.bots.row.\(wanted[0]) absent")
        usleep(1_500_000)
        let shown = shownBotIDs(in: app)
        print("HV-BOTS orb rows=\(shown.sorted())")
        XCTAssertTrue(Set(wanted).isSubset(of: shown), "manque : \(Set(wanted).subtracting(shown).sorted())")
        for id in absent { XCTAssertFalse(shown.contains(id), "\(id) est listé") }
        // la lane 13 donne des noms affichés (`HV_EXPECT_NAMES=id=Nom,...`) : la ligne porte l'id canonique et montre le nom
        for pair in expected("HV_EXPECT_NAMES", default: []) {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            XCTAssertEqual(parts.count, 2, "HV_EXPECT_NAMES mal formé : \(pair)")
            XCTAssertEqual(text(of: element(AccessibilityID.botName(parts[0]), in: app)), parts[1], "nom affiché de \(parts[0])")
        }
        // la lane 14 donne des modèles à espaces et à parenthèses (`HV_EXPECT_MODELS=id=modèle,...`) : la ligne porte l'id canonique et montre le modèle entier
        for pair in expected("HV_EXPECT_MODELS", default: []) {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            XCTAssertEqual(parts.count, 2, "HV_EXPECT_MODELS mal formé : \(pair)")
            XCTAssertEqual(text(of: element(AccessibilityID.botModel(parts[0]), in: app)), parts[1], "modèle de \(parts[0])")
        }
        // les lanes 12 à 14 rejouent ce test sur une table de plus de 8 Kio, sur des noms affichés et sur des modèles à parenthèses, et nomment leur capture
        HVShot.capture(environment["HV_SHOT_NAME"] ?? "hd08-orb-nine", app)
    }

    /// Lane 4 : `HV_FAKE_MODE=fields` retire `title` et ajoute un champ inconnu, aucun bot ni fil n'a de nom autre que son id
    func testWithoutNamesTheRowsShowTheProfileIdAndTheThreadsShowTheirId() throws {
        try configureFake(mode: "fields")
        let app = launch()
        let row = element(AccessibilityID.botRow("hv-bot-a"), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertEqual(text(of: element(AccessibilityID.botName("hv-bot-a"), in: app)), "hv-bot-a")
        row.click()
        let thread = element(AccessibilityID.threadRow("s-past-1"), in: app)
        XCTAssertTrue(thread.waitForExistence(timeout: 10), "hd.threads.row.s-past-1 absent")
        XCTAssertEqual(text(of: thread), "s-past-1", "un fil sans titre doit montrer son identifiant")
        print("HV-FIELDS bot-name=hv-bot-a thread-label=\(text(of: thread))")
        HVShot.capture("hd08-fields", app)
    }

    /// Lane 5 : aucun profil, un message clair, pas de plantage
    func testAnEmptyProfileListShowsAClearMessage() throws {
        try configureFake(profiles: [])
        let active = try XCTUnwrap(activeProfileIDs(), "pas de /_hv/profile-list")
        XCTAssertTrue(active.isEmpty)
        let app = launch()
        XCTAssertTrue(element(.botsEmpty, in: app).waitForExistence(timeout: 20), "hd.bots.empty absent")
        // le message dit que Hermes n'a aucun profil actif, il ne reste pas à « chargement »
        XCTAssertTrue(app.staticTexts["Hermes ne liste aucun profil actif."].waitForExistence(timeout: 10))
        XCTAssertTrue(shownBotIDs(in: app).isEmpty)
        XCTAssertFalse(element(.botsError, in: app).exists)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "l'app a planté")
        HVShot.capture("hd08-empty", app)
    }

    /// Lane 6 : un nom de 300 caractères, un nom emoji et un nom de droite à gauche
    func testLongEmojiAndRightToLeftNamesAreTruncatedAndReadable() throws {
        try configureFake(profiles: ["default", "long-" + String(repeating: "n", count: 295), "🤖-bot-🚀", "مرحبا-بوت", "hv-bot-a"])
        let active = try XCTUnwrap(activeProfileIDs(), "pas de /_hv/profile-list")
        XCTAssertTrue(active.contains { $0.count >= 300 })
        let app = launch()
        let list = element(.botsList, in: app)
        XCTAssertTrue(list.waitForExistence(timeout: 20))
        let first = active.sorted()[0]
        XCTAssertTrue(element(AccessibilityID.botRow(first), in: app).waitForExistence(timeout: 20))
        usleep(1_000_000)
        for id in active {
            let name = element(AccessibilityID.botName(id), in: app)
            XCTAssertTrue(name.exists, "le nom de \(id.prefix(20))… est absent")
            // tronqué : la ligne tient dans la barre latérale ; lisible : le nom entier reste le libellé d'accessibilité
            XCTAssertLessThanOrEqual(name.frame.maxX, list.frame.maxX + 1, "la ligne de \(id.prefix(20))… dépasse la barre latérale")
            XCTAssertGreaterThan(name.frame.width, 20)
            XCTAssertEqual(text(of: name), id)
        }
        print("HV-LONG rows=\(shownBotIDs(in: app).count) lengths=\(active.map(\.count).sorted()) list-width=\(Int(list.frame.width))")
        HVShot.capture("hd08-long-names", app)
    }

    /// Lane 7 : un profil ajouté pendant que l'app tourne n'apparaît qu'après la validation
    func testAProfileAddedWhileTheAppRunsShowsOnlyAfterTheValidation() throws {
        try configureFake()
        let added = "hv-new"
        let app = launch()
        XCTAssertTrue(element(AccessibilityID.botRow("hv-bot-a"), in: app).waitForExistence(timeout: 20))
        let before = shownBotIDs(in: app)
        XCTAssertFalse(before.contains(added), "\(added) est là avant d'avoir été ajouté")
        XCTAssertFalse(element(.botsChange, in: app).exists)
        FakeServer.configure(profiles: before.sorted() + [added])
        // le serveur change de liste en route ; l'app relit toutes les 30 s
        let deadline = Date().addingTimeInterval(120)
        while activeProfileIDs()?.contains(added) != true, Date() < deadline { sleep(1) }
        XCTAssertEqual(activeProfileIDs()?.contains(added), true, "le serveur n'a pas ajouté \(added)")
        XCTAssertTrue(element(.botsChange, in: app).waitForExistence(timeout: 60), "aucune invite de validation")
        XCTAssertTrue(element(.botsChangeApply, in: app).exists)
        XCTAssertFalse(element(AccessibilityID.botRow(added), in: app).exists, "\(added) s'affiche avant la validation")
        XCTAssertEqual(shownBotIDs(in: app), before, "la liste a bougé avant la validation")
        print("HV-CHANGE prompt shown, \(added) not listed, rows=\(shownBotIDs(in: app).count)")
        HVShot.capture("hd08-list-change-prompt", app)
        element(.botsChangeApply, in: app).click()
        XCTAssertTrue(element(AccessibilityID.botRow(added), in: app).waitForExistence(timeout: 10), "\(added) ne s'affiche pas après la validation")
        XCTAssertFalse(element(.botsChange, in: app).exists, "l'invite reste après la validation")
        XCTAssertEqual(shownBotIDs(in: app), before.union([added]))
        print("HV-CHANGE validated, \(added) listed, rows=\(shownBotIDs(in: app).count)")
        HVShot.capture("hd08-list-change", app)
    }

    // MARK: les fils

    /// Lane 3 : déplier un bot lit ses fils, une seule fois, sans rien envoyer
    func testExpandingABotListsItsPastThreadsWithOneRequest() throws {
        try XCTSkipIf(apiURL == nil, "HV_API_URL absent : pas de journal du serveur à lire")
        let start = Date()
        let app = launch()
        let row = element(AccessibilityID.botRow("hv-bot-a"), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        usleep(1_000_000)
        let listing = "/p/hv-bot-a/api/sessions"
        XCTAssertEqual(serverLog(since: start).filter { $0.path == listing && !$0.isCapabilityProbe }.count, 0, "les fils sont lus avant le dépli")
        XCTAssertFalse(element(AccessibilityID.botThreads("hv-bot-a"), in: app).exists)
        row.click()
        let group = element(AccessibilityID.botThreads("hv-bot-a"), in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 10), "hd.bots.row.hv-bot-a.threads absent")
        // le fil est dans son groupe, sous le bot
        let thread = element(AccessibilityID.threadRow("s-past-1"), in: group.descendants(matching: .any))
        XCTAssertTrue(thread.waitForExistence(timeout: 10), "hd.threads.row.s-past-1 absent du groupe")
        XCTAssertEqual(count(AccessibilityID.threadRow("s-past-1"), in: app), 1)
        XCTAssertEqual(text(of: thread), "Fil passé 1")
        XCTAssertEqual(count(AccessibilityID.botThreads("hv-bot-a"), in: app), 1)
        let log = serverLog(since: start)
        let lists = log.filter { $0.method == "GET" && $0.path == listing && !$0.isCapabilityProbe }.count
        let posts = sendingPosts(log).count
        print("HV-THREADS list_sessions=\(lists) send_message-or-any-POST=\(posts) log=\(log.map { "\($0.method) \($0.path)" })")
        XCTAssertEqual(lists, 1, "list_sessions doit être lu une fois")
        XCTAssertEqual(posts, 0, "aucun POST ne doit partir (send_message compris)")
        HVShot.capture("hd08-threads", app)
        // replier ne relit rien
        row.click()
        XCTAssertTrue(element(AccessibilityID.botThreads("hv-bot-a"), in: app).waitForNonExistence(timeout: 5), "le groupe reste après le repli")
    }

    /// Lane 9 : `HV_FAKE_MODE=drop-route HV_DROP=list_sessions` désactive les fils seuls
    func testDroppingListSessionsDisablesTheThreadsAloneWithAMessage() throws {
        try configureFake(mode: "drop-route", drop: "list_sessions")
        let app = launch()
        let row = element(AccessibilityID.botRow("hv-bot-a"), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "la liste des bots doit marcher")
        XCTAssertTrue(element(AccessibilityID.botRow("hv-bot-b"), in: app).exists)
        row.click()
        let message = element(AccessibilityID.threadsDisabled("hv-bot-a"), in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 10), "hd.threads.disabled.hv-bot-a absent")
        XCTAssertTrue(text(of: message).contains("la liste des fils passés"), text(of: message))
        // le message passe à la ligne : une ligne de 220 points ne le contient pas en entier
        XCTAssertGreaterThan(message.frame.height, 20, "le message est coupé à une ligne")
        // les autres bots restent utilisables
        XCTAssertTrue(element(AccessibilityID.botRow("hv-bot-b"), in: app).isHittable)
        XCTAssertEqual(app.state, .runningForeground)
        print("HV-DROP message=\(text(of: message)) height=\(Int(message.frame.height))")
        HVShot.capture("hd08-drop-sessions", app)
    }

    // MARK: la conversation (HD-09)

    private let messagePrefix = "hd.conversation.message."

    private func messages(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", messagePrefix))
    }

    /// Les textes des messages affichés, dans l'ordre de l'écran
    private func shownMessages(in app: XCUIApplication) -> [String] {
        messages(in: app).allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }.map { text(of: $0) }
    }

    /// Les identifiants de session des fils listés sous le bot ouvert : `hd.threads.row.<id>`
    private func threadIDs(in app: XCUIApplication) -> Set<String> {
        let prefix = "hd.threads.row."
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        return Set(rows.allElementsBoundByIndex.map { String($0.identifier.dropFirst(prefix.count)) })
    }

    /// Choisit le bot : la ligne se déplie et la conversation s'ouvre sur ce bot
    /// Clique un fil sous le bot ouvert : la ligne existe avant d'avoir sa place à l'écran, comme celle d'un bot, et un clic trop tôt ne rouvre rien
    private func openThread(_ id: String, in app: XCUIApplication) {
        let row = element(AccessibilityID.threadRow(id), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "hd.threads.row.\(id) absent")
        let hittable = Date().addingTimeInterval(10)
        while !row.isHittable, Date() < hittable { usleep(50_000) }
        print("HV-THREAD-CLICK id=\(id) hittable=\(row.isHittable) frame=\(row.frame) listed=\(threadIDs(in: app).count)")
        row.click()
    }

    private func openBot(_ id: String = "hv-bot-a", in app: XCUIApplication) {
        let row = element(AccessibilityID.botRow(id), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "hd.bots.row.\(id) absent")
        // la liste existe avant que ses lignes aient une place à l'écran : un clic trop tôt ne trouve pas de point à cliquer
        let hittable = Date().addingTimeInterval(10)
        while !row.isHittable, Date() < hittable { usleep(50_000) }
        row.click()
        XCTAssertTrue(element(.composerInput, in: app).waitForExistence(timeout: 10), "hd.composer.input absent")
    }

    /// Tape le message dans le champ, sans l'envoyer
    private func type(_ message: String, in app: XCUIApplication) {
        let input = element(.composerInput, in: app)
        input.click()
        input.typeText(message)
    }

    private func send(_ message: String, in app: XCUIApplication) {
        type(message, in: app)
        element(.composerSend, in: app).click()
    }

    /// Le texte que l'app montre pour chaque état terminal de Hermes (`completed`, `failed`, `cancelled`, `interrupted`) : les tests tournent en français, comme ceux du tunnel
    /// SwiftUI n'expose pas une valeur d'accessibilité sur ce texte : le libellé est ce que XCUITest lit
    private let stateLabels = ["completed": "Tour terminé", "failed": "Tour échoué", "cancelled": "Tour annulé", "interrupted": "Tour interrompu"]

    /// Attend que `hd.conversation.state` montre l'état attendu ; un état voisin ne passe pas
    private func waitForState(_ expected: String, in app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let state = element(.conversationState, in: app)
        let label = stateLabels[expected] ?? expected
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.exists, state.label == label || state.label.hasPrefix(label + " : ") { return true }
            usleep(50_000)
        }
        // la sortie dit ce que l'écran montrait à la place : un état absent, une autre valeur, un message d'erreur
        let seen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "hd.conversation.")).allElementsBoundByIndex
        print("HV-DEBUG état attendu \(expected), vu : \(seen.map { "\($0.identifier)[\($0.elementType.rawValue)] value=\(String(describing: $0.value)) label=\($0.label.prefix(80))" })")
        return false
    }

    private func waitForMessage(containing needle: String, in app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if shownMessages(in: app).contains(where: { $0.contains(needle) }) { return true }
            usleep(50_000)
        }
        return false
    }

    private func serverPost(_ path: String, _ body: [String: Any] = [:]) {
        guard let apiURL, let url = URL(string: apiURL + path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        done.wait()
    }

    /// Les corps JSON des POST reçus sur un chemin depuis `since`
    private func postBodies(on path: String, since: Date) -> [[String: Any]] {
        guard let data = serverData("/_hv/log"), let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard entry["probe"] as? Bool != true, entry["m"] as? String == "POST", entry["p"] as? String == path, let time = entry["t"] as? Double, time >= since.timeIntervalSince1970,
                  let body = entry["body"] as? String else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        }
    }

    private func posts(_ path: String, since: Date) -> Int { sendingPosts(serverLog(since: since)).filter { $0.path == path }.count }

    private let runs = "/p/hv-bot-a/v1/runs"
    private let sessions = "/p/hv-bot-a/api/sessions"

    /// Lane 1 : un message part, la réponse de la fixture arrive en flux, l'état terminal est `completed`
    /// Le tour part par `start_run` avec le `session_id` du fil : le chat de session ne rend aucun événement (S1) et répond HTTP 200 à un échec du fournisseur
    func testConversation() throws {
        let start = Date()
        let app = launch()
        openBot(in: app)
        XCTAssertFalse(element(.composerSend, in: app).isEnabled, "Envoyer doit être grisé tant que le champ est vide")
        XCTAssertTrue(element(.conversationView, in: app).exists)
        XCTAssertTrue(element(.conversationEmpty, in: app).exists, "une conversation neuve montre son message d'accueil")
        XCTAssertFalse(element(.conversationState, in: app).exists, "aucun état avant le premier tour")
        type("Bonjour hv", in: app)
        XCTAssertTrue(element(.composerSend, in: app).isEnabled)
        element(.composerSend, in: app).click()
        XCTAssertTrue(waitForMessage(containing: "Réponse de test", in: app), "la réponse de la fixture n'arrive pas")
        XCTAssertTrue(waitForState("completed", in: app), "hd.conversation.state ne lit pas completed")
        XCTAssertTrue(shownMessages(in: app).contains("Bonjour hv"))
        XCTAssertFalse(element(.conversationEmpty, in: app).exists)
        XCTAssertFalse(element(.conversationBusy, in: app).exists)
        XCTAssertFalse(element(.conversationError, in: app).exists)
        XCTAssertEqual(text(of: element(.composerInput, in: app)), "", "le champ est vidé à l'envoi")
        // Hermes a numéroté les deux lignes : l'identifiant porte son numéro, pas un rang local
        let identifiers = messages(in: app).allElementsBoundByIndex.map(\.identifier)
        XCTAssertEqual(identifiers.count, 2, "\(identifiers)")
        XCTAssertTrue(identifiers.allSatisfy { $0.dropFirst(messagePrefix.count).allSatisfy(\.isNumber) }, "\(identifiers)")
        // un tour : un fil créé, un run lancé dans ce fil, aucun chat de session
        let log = serverLog(since: start)
        let chats = sendingPosts(log).filter { $0.method == "POST" && $0.path.hasSuffix("/chat") }.count
        print("HV-CONVERSATION sessions=\(posts(sessions, since: start)) runs=\(posts(runs, since: start)) chats=\(chats) ids=\(identifiers) log=\(log.map { "\($0.method) \($0.path)" })")
        XCTAssertEqual(posts(sessions, since: start), 1)
        XCTAssertEqual(posts(runs, since: start), 1, "un seul envoi")
        XCTAssertEqual(chats, 0)
        let sent = try XCTUnwrap(postBodies(on: runs, since: start).first)
        XCTAssertEqual(sent["input"] as? String, "Bonjour hv")
        XCTAssertNotNil(sent["session_id"] as? String, "le tour continue le fil créé")
        HVShot.capture("hd09-send", app)
    }

    /// Lane 2 : le même parcours contre `hv-hermes-test` ; le fil de Hermes ne garde le message qu'une fois
    /// `HV_EXPECT_REPLY` donne le début de la réponse du faux fournisseur (le serveur orb n'a pas « Réponse de test »)
    func testSendingToTheOrbInstanceGetsTheModelReplyOnceInTheServerSession() throws {
        let expected = environment["HV_EXPECT_REPLY"] ?? ""
        try XCTSkipIf(expected.isEmpty, "HV_EXPECT_REPLY absent : pas d'instance OrbStack à interroger")
        let reply = expected
        let app = launch()
        openBot(in: app)
        send("bonjour hd09", in: app)
        XCTAssertTrue(waitForMessage(containing: reply, in: app), "la réponse du modèle n'arrive pas : \(shownMessages(in: app))")
        XCTAssertTrue(waitForState("completed", in: app))
        let identifiers = messages(in: app).allElementsBoundByIndex.map(\.identifier)
        print("HV-ORB-SEND messages=\(shownMessages(in: app)) ids=\(identifiers)")
        XCTAssertEqual(shownMessages(in: app).filter { $0 == "bonjour hd09" }.count, 1)
        HVShot.capture(environment["HV_SHOT_NAME"] ?? "hd09-orb-send", app)
    }

    /// Rouvrir un fil passé montre son transcript, avec les numéros de Hermes, sans rien envoyer
    func testReopeningAThreadShowsItsTranscriptAndSendsNothing() throws {
        let start = Date()
        let app = launch()
        openBot(in: app)
        openThread("s-past-1", in: app)
        XCTAssertTrue(waitForMessage(containing: "Réponse de test", in: app), "le transcript du fil n'arrive pas")
        XCTAssertEqual(shownMessages(in: app), ["Bonjour", "Réponse de test"])
        XCTAssertTrue(element(.conversationView, in: app).exists)
        XCTAssertFalse(element(.conversationState, in: app).exists, "un fil rouvert n'a pas d'état de tour")
        XCTAssertFalse(element(.conversationEmpty, in: app).exists)
        if serverMode() != nil {
            // le faux serveur numérote les deux premières lignes 13 et 14, comme la fixture
            XCTAssertTrue(element("\(messagePrefix)13", in: app).exists)
            XCTAssertTrue(element("\(messagePrefix)14", in: app).exists)
        }
        let log = serverLog(since: start)
        XCTAssertEqual(log.filter { $0.method == "GET" && $0.path == "\(sessions)/s-past-1/messages" }.count, 1, "le transcript se lit une fois")
        XCTAssertEqual(sendingPosts(log).count, 0, "rouvrir un fil n'envoie rien : \(log.filter { $0.method == "POST" }.map(\.path))")
        // écrire dans un fil rouvert continue ce fil
        send("suite", in: app)
        XCTAssertTrue(waitForState("completed", in: app))
        XCTAssertEqual(postBodies(on: runs, since: start).first?["session_id"] as? String, "s-past-1")
        HVShot.capture("hd09-reopen", app)
    }

    /// Lanes 3 et 4 : l'état terminal est celui que Hermes annonce, jamais « terminé » par défaut
    func testEveryTerminalStateShowsAsHermesSentIt() throws {
        try XCTSkipIf(serverMode() == nil, "pas de faux serveur : /_hv/inject n'existe pas")
        let cases: [(event: [String: Any], state: String, shot: String)] = [
            (["event": "run.completed", "status": "failed"], "failed", "hd09-failed"),
            (["event": "run.failed", "error": "HTTP 400: hv fake provider failure"], "failed", "hd09-failed-error"),
            (["event": "run.cancelled", "turn_exit_reason": "interrupted_by_user"], "cancelled", "hd09-cancelled"),
            (["event": "run.interrupted", "error": "The gateway restarted before this run settled."], "interrupted", "hd09-interrupted"),
        ]
        for item in cases {
            serverPost("/_hv/reset")
            serverPost("/_hv/inject", item.event)
            let app = launch()
            openBot(in: app)
            send("etat \(item.state)", in: app)
            XCTAssertTrue(waitForState(item.state, in: app), "\(item.event) : hd.conversation.state ne lit pas \(item.state), il lit \(element(.conversationState, in: app).label)")
            XCTAssertFalse(element(.conversationBusy, in: app).exists)
            XCTAssertFalse(element(.conversationError, in: app).exists, "un état terminal de Hermes n'est pas une erreur de lecture")
            if let error = item.event["error"] as? String {
                XCTAssertTrue(element(.conversationState, in: app).label.contains(error), "l'erreur de Hermes accompagne l'état")
            }
            // on peut écrire de nouveau après chaque fin
            XCTAssertTrue(element(.composerInput, in: app).isEnabled)
            print("HV-STATE event=\(item.event["event"] ?? "") status=\(item.event["status"] ?? "-") expected=\(item.state) shown=\(element(.conversationState, in: app).label)")
            HVShot.capture(item.shot, app)
            app.terminate()
        }
        serverPost("/_hv/reset")
    }

    /// Lane 5 : un événement inconnu dans le flux ne casse pas le tour
    func testAnUnknownEventInTheStreamDoesNotBreakTheTurn() throws {
        try XCTSkipIf(serverMode() == nil, "pas de faux serveur : /_hv/inject n'existe pas")
        serverPost("/_hv/reset")
        serverPost("/_hv/inject", ["event": "hv.unknown_future_event", "payload": ["x": 2]])
        let app = launch()
        openBot(in: app)
        send("evenement inconnu", in: app)
        XCTAssertTrue(waitForMessage(containing: "Réponse de test", in: app))
        XCTAssertTrue(waitForState("completed", in: app))
        XCTAssertFalse(element(.conversationError, in: app).exists)
        XCTAssertEqual(app.state, .runningForeground, "l'app a planté")
        HVShot.capture("hd09-unknown", app)
        serverPost("/_hv/reset")
    }

    /// Lane 6 : des espaces seuls ne s'envoient pas
    func testAMessageOfSpacesCannotBeSent() throws {
        let start = Date()
        let app = launch()
        openBot(in: app)
        type("     ", in: app)
        XCTAssertFalse(element(.composerSend, in: app).isEnabled, "Envoyer doit rester grisé pour des espaces")
        // ⏎ ne contourne pas le bouton
        element(.composerInput, in: app).typeKey(.return, modifierFlags: [])
        usleep(500_000)
        XCTAssertEqual(posts(runs, since: start), 0)
        XCTAssertEqual(posts(sessions, since: start), 0, "un message refusé ne crée pas de fil")
        XCTAssertTrue(element(.conversationEmpty, in: app).exists)
        type("\n\t ", in: app)
        XCTAssertFalse(element(.composerSend, in: app).isEnabled)
        HVShot.capture("hd09-blank", app)
    }

    /// Lane 7 : 100 000 caractères collés, une seule requête, la fenêtre répond
    func testAHundredThousandCharacterMessageGoesOutOnce() throws {
        let start = Date()
        let app = launch()
        openBot(in: app)
        let long = String(repeating: "é", count: 100_000)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(long, forType: .string)
        let input = element(.composerInput, in: app)
        input.click()
        input.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(element(.composerSend, in: app).waitForExistence(timeout: 10))
        let enabled = Date().addingTimeInterval(30)
        while !element(.composerSend, in: app).isEnabled, Date() < enabled { usleep(100_000) }
        XCTAssertTrue(element(.composerSend, in: app).isEnabled, "le collage n'a pas rempli le champ")
        element(.composerSend, in: app).click()
        XCTAssertTrue(waitForState("completed", in: app, timeout: 60), "le tour de 100 000 caractères ne finit pas")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element(.composerInput, in: app).isHittable, "la fenêtre ne répond plus")
        let sent = postBodies(on: runs, since: start)
        print("HV-LONG-SEND runs=\(sent.count) input_chars=\((sent.first?["input"] as? String)?.count ?? -1)")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual((sent.first?["input"] as? String)?.count, 100_000, "le message part entier")
        HVShot.capture("hd09-long", app)
    }

    /// Lane 8 : un double clic sur Envoyer ne lance qu'un tour
    func testADoubleClickOnSendSendsOnce() throws {
        let start = Date()
        let app = launch()
        openBot(in: app)
        type("double clic", in: app)
        element(.composerSend, in: app).doubleClick()
        XCTAssertTrue(waitForState("completed", in: app))
        usleep(500_000)
        XCTAssertEqual(posts(runs, since: start), 1, "un double clic doit lancer un seul tour")
        XCTAssertEqual(posts(sessions, since: start), 1)
        XCTAssertEqual(shownMessages(in: app).filter { $0 == "double clic" }.count, 1)
        HVShot.capture("hd09-double", app)
    }

    /// Lane 9 : pendant un tour, Envoyer est grisé, le champ reste libre et rien de plus ne part
    /// Un message qui contient HV_SLOW espace les événements d'une seconde (faux serveur) ou fait parler le faux fournisseur vingt secondes (orb)
    func testSendingWhileATurnRunsIsRefusedWithoutSendingAnythingExtra() throws {
        let start = Date()
        let app = launch()
        openBot(in: app)
        send("HV_SLOW go", in: app)
        let busy = element(.conversationBusy, in: app)
        XCTAssertTrue(busy.waitForExistence(timeout: 10), "hd.conversation.busy absent pendant le tour")
        XCTAssertFalse(element(.composerSend, in: app).isEnabled, "Envoyer doit être grisé pendant le tour")
        XCTAssertFalse(element(.conversationState, in: app).exists, "pas d'état avant la fin du tour")
        // l'utilisateur peut déjà écrire la suite : le brouillon reste, rien ne part
        type("suite en attente", in: app)
        XCTAssertFalse(element(.composerSend, in: app).isEnabled)
        element(.composerInput, in: app).typeKey(.return, modifierFlags: [])
        usleep(500_000)
        XCTAssertEqual(posts(runs, since: start), 1, "aucun second envoi pendant le tour")
        HVShot.capture("hd09-busy", app)
        XCTAssertTrue(waitForState("completed", in: app, timeout: 60))
        XCTAssertFalse(element(.conversationBusy, in: app).exists)
        XCTAssertTrue(element(.composerSend, in: app).isEnabled, "le brouillon gardé peut partir une fois le tour fini")
        XCTAssertEqual(posts(runs, since: start), 1)
    }

    /// Lane 10 : « Nouvelle session » vide la conversation, l'ancien fil devient un fil passé, rouvrir un fil montre ses messages
    func testNewSessionEmptiesTheConversationAndTheOldOneBecomesAThread() throws {
        let start = Date()
        let app = launch()
        openBot(in: app)
        let button = element(.sessionNew, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "hd.session.new absent")
        XCTAssertEqual(button.label, "Nouvelle session")
        XCTAssertTrue(element(AccessibilityID.threadRow("s-past-1"), in: app).waitForExistence(timeout: 10), "les fils du bot ne sont pas listés")
        let before = threadIDs(in: app)
        send("avant la nouvelle session", in: app)
        XCTAssertTrue(waitForState("completed", in: app))
        // le faux serveur garde les fils des tests précédents : le fil du premier envoi est celui qui s'ajoute aux fils déjà listés
        let deadline = Date().addingTimeInterval(10)
        var after = threadIDs(in: app)
        while after.subtracting(before).isEmpty, Date() < deadline { usleep(100_000); after = threadIDs(in: app) }
        let created = after.subtracting(before)
        XCTAssertEqual(created.count, 1, "le fil du premier envoi n'est pas listé : \(created)")
        let oldID = try XCTUnwrap(created.first)
        button.click()
        XCTAssertTrue(element(.conversationEmpty, in: app).waitForExistence(timeout: 10), "la conversation doit être vide")
        XCTAssertEqual(messages(in: app).count, 0)
        XCTAssertFalse(element(.conversationState, in: app).exists)
        let rowsAfter = Date().addingTimeInterval(10)
        var final = threadIDs(in: app)
        while final.subtracting(after).isEmpty, Date() < rowsAfter { usleep(100_000); final = threadIDs(in: app) }
        XCTAssertTrue(final.contains(oldID), "l'ancien fil doit rester listé")
        // une liste plus longue que la fenêtre ne montre pas ses dernières lignes : on compte ce qui s'ajoute, pas le total
        XCTAssertEqual(final.subtracting(after).count, 1, "le fil vide de « Nouvelle session » doit s'ajouter à la liste : \(final.subtracting(after))")
        let log = serverLog(since: start)
        print("HV-NEW posts=\(log.filter { $0.method == "POST" }.map(\.path)) old=\(oldID)")
        XCTAssertEqual(posts(sessions, since: start), 2, "un fil créé au premier envoi, un par « Nouvelle session »")
        XCTAssertFalse(log.contains { $0.path.contains("reset") }, "jamais /reset")
        XCTAssertEqual(posts(runs, since: start), 1, "« Nouvelle session » n'envoie aucun message")
        HVShot.capture("hd09-new", app)
        // rouvrir un fil passé montre ses messages
        openThread("s-past-1", in: app)
        XCTAssertTrue(waitForMessage(containing: "Réponse de test", in: app), "le transcript du fil n'arrive pas : \(shownMessages(in: app))")
        XCTAssertEqual(shownMessages(in: app), ["Bonjour", "Réponse de test"])
        HVShot.capture("hd09-reopen-past", app)
    }

    // MARK: le modèle de la session (HD-10)

    /// Un faux serveur en mode normal : lui seul règle la table des profils et sert vite ; en slow, drop-route ou fields, chaque lane lance le sien
    private func requireFakeServer() throws {
        try XCTSkipUnless(serverMode() == "normal", "le faux serveur n'est pas en mode normal")
    }

    /// Le sélecteur n'a qu'une option tant que les profils ont tous le même modèle : `hv-bot-b` prend `model-y`
    private func launchWithTwoModels() -> XCUIApplication {
        FakeServer.setProfileModels(["hv-bot-b": "model-y"])
        return launch()
    }

    /// Ouvre le sélecteur et clique l'option : les lignes du menu n'existent que pendant qu'il est ouvert
    /// `lenient` : le sélecteur peut déjà être grisé ou l'option absente (un second choix pendant le premier)
    private func pickModel(_ id: String, in app: XCUIApplication, lenient: Bool = false) {
        let picker = element(.modelPicker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "hd.model.picker absent")
        picker.click()
        let option = element(AccessibilityID.modelOption(id), in: app)
        guard option.waitForExistence(timeout: lenient ? 1 : 5) else {
            if !lenient {
                let seen = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "hd.model.")).allElementsBoundByIndex
                print("HV-DEBUG option \(id) absente, vu : \(seen.map { "\($0.identifier)[\($0.elementType.rawValue)] value=\(String(describing: $0.value)) enabled=\($0.isEnabled)" })")
                XCTFail("hd.model.option.\(id) absent")
            }
            app.typeKey(.escape, modifierFlags: [])
            return
        }
        option.click()
    }

    /// Attend que le sélecteur montre `expected` ; l'état que l'écran montrait à la place s'imprime en cas d'échec
    private func waitForModel(_ expected: String, in app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        let picker = element(.modelPicker, in: app)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if picker.exists, text(of: picker) == expected { return true }
            usleep(20_000)
        }
        print("HV-DEBUG modèle attendu \(expected), vu : \(picker.exists ? text(of: picker) : "aucun sélecteur") enabled=\(picker.exists && picker.isEnabled)")
        return false
    }

    /// Les `set_model` reçus depuis `since`, dans l'ordre : le chemin de la session et le modèle demandé
    /// La sonde inerte du sélecteur (`hd-probe-capabilities`, modèle vide) n'est pas un choix de l'utilisateur
    private func setModelRequests(since: Date) -> [(path: String, model: String)] {
        guard let data = serverData("/_hv/log"), let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard entry["m"] as? String == "POST", let path = entry["p"] as? String, path.hasSuffix("/model"), !path.contains("hd-probe-capabilities"),
                  let time = entry["t"] as? Double, time >= since.timeIntervalSince1970,
                  let body = (entry["body"] as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }) else { return nil }
            return (path, body["model"] as? String ?? "")
        }
    }

    /// Lane 1 : choisir `model-y` le montre dans le sélecteur, et le serveur reçoit un seul `set_model` pour la session ouverte
    /// Le message suivant part avec le modèle choisi : `POST /v1/runs` ignore le verrou de la session (S4)
    func testModelSwitch() throws {
        try requireFakeServer()
        let app = launchWithTwoModels()
        openBot(in: app)
        let picker = element(.modelPicker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "hd.model.picker absent")
        XCTAssertEqual(text(of: picker), "hv-fake-1", "avant tout choix, le sélecteur montre le modèle du profil")
        openThread("s-past-1", in: app)
        XCTAssertTrue(waitForMessage(containing: "Réponse de test", in: app))
        let start = Date()
        pickModel("model-y", in: app)
        XCTAssertTrue(waitForModel("model-y", in: app), "le sélecteur ne montre pas model-y")
        XCTAssertEqual(count(AccessibilityID.modelPicker.rawValue, in: app), 1)
        usleep(300_000)
        let requests = setModelRequests(since: start)
        print("HV-MODEL pick requests=\(requests.map { "\($0.path) \($0.model)" })")
        XCTAssertEqual(requests.count, 1, "un seul set_model attendu : \(requests)")
        XCTAssertEqual(requests.first?.path, "/p/hv-bot-a/api/sessions/s-past-1/model")
        XCTAssertEqual(requests.first?.model, "model-y")
        HVShot.capture("hd10-pick", app)

        send("après le choix", in: app)
        XCTAssertTrue(waitForState("completed", in: app))
        let sent = try XCTUnwrap(postBodies(on: runs, since: start).last)
        XCTAssertEqual(sent["model"] as? String, "model-y", "le run porte le modèle choisi")
        XCTAssertEqual(sent["session_id"] as? String, "s-past-1")
        XCTAssertEqual(text(of: picker), "model-y")
    }

    /// Un choix fait avant le premier message : affiché tout de suite, verrouillé à la création du fil, et le premier tour part avec le modèle confirmé
    func testAModelPickedBeforeTheFirstMessageIsLockedOnCreationAndTheFirstTurnUsesIt() throws {
        try requireFakeServer()
        let app = launchWithTwoModels()
        openBot(in: app)
        let start = Date()
        pickModel("model-y", in: app)
        XCTAssertTrue(waitForModel("model-y", in: app), "le choix doit s'afficher avant que le fil existe")
        XCTAssertEqual(setModelRequests(since: start).count, 0, "aucune session où verrouiller")
        send("premier message", in: app)
        XCTAssertTrue(waitForState("completed", in: app))
        let sent = try XCTUnwrap(postBodies(on: runs, since: start).last)
        let session = try XCTUnwrap(sent["session_id"] as? String)
        XCTAssertEqual(sent["model"] as? String, "model-y", "le premier tour part avec le modèle confirmé")
        let requests = setModelRequests(since: start)
        print("HV-MODEL first-turn requests=\(requests.map { "\($0.path) \($0.model)" })")
        XCTAssertEqual(requests.count, 1, "\(requests)")
        XCTAssertEqual(requests.first?.path, "/p/hv-bot-a/api/sessions/\(session)/model")
        XCTAssertEqual(requests.first?.model, "model-y")
        XCTAssertTrue(waitForModel("model-y", in: app))
    }

    /// Lane 2 : le choix reste sur la session ; une nouvelle session montre le modèle du profil
    func testAChosenModelStaysOnItsSessionAndANewSessionShowsTheProfileModel() throws {
        try requireFakeServer()
        let app = launchWithTwoModels()
        openBot(in: app)
        openThread("s-past-1", in: app)
        XCTAssertTrue(waitForMessage(containing: "Réponse de test", in: app))
        let start = Date()
        pickModel("model-y", in: app)
        XCTAssertTrue(waitForModel("model-y", in: app))
        element(.sessionNew, in: app).click()
        XCTAssertTrue(element(.conversationEmpty, in: app).waitForExistence(timeout: 10), "la conversation doit être vide")
        XCTAssertTrue(waitForModel("hv-fake-1", in: app), "la nouvelle session montre le modèle du profil")
        HVShot.capture("hd10-persist", app)
        openThread("s-past-1", in: app)
        XCTAssertTrue(waitForModel("model-y", in: app), "la session d'origine garde son choix")
        XCTAssertEqual(setModelRequests(since: start).count, 1, "ni la nouvelle session ni la réouverture n'écrivent un modèle")
    }

    /// Lane 3 : un nom que l'app ne connaît pas s'affiche tel que Hermes l'envoie, et reste un choix du menu
    func testAnUnknownModelNameShowsAsSentAndNothingCrashes() throws {
        try requireFakeServer()
        let unknown = "Modèle inconnu (x) 9"
        FakeServer.lockModel(profile: "hv-bot-a", session: "s-past-1", model: unknown)
        let app = launchWithTwoModels()
        openBot(in: app)
        openThread("s-past-1", in: app)
        XCTAssertTrue(waitForModel(unknown, in: app), "le nom envoyé par Hermes doit s'afficher tel quel")
        element(.modelPicker, in: app).click()
        let option = element(AccessibilityID.modelOption(unknown), in: app)
        XCTAssertTrue(option.waitForExistence(timeout: 5), "le nom inconnu reste une option du menu")
        app.typeKey(.escape, modifierFlags: [])
        // la capture attend que le menu soit refermé : un menu qui s'efface y laisse son ombre
        XCTAssertTrue(option.waitForNonExistence(timeout: 5), "le menu reste ouvert")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(waitForModel(unknown, in: app))
        HVShot.capture("hd10-unknown", app)
    }

    /// Lane 4 : `HV_FAKE_MODE=drop-route HV_DROP=set_model` désactive le sélecteur seul, avec son message ; envoyer marche
    func testDroppingSetModelDisablesThePickerAloneWithItsMessageAndSendingStillWorks() throws {
        try configureFake(mode: "drop-route", drop: "set_model")
        let start = Date()
        let app = launch()
        openBot(in: app)
        let picker = element(.modelPicker, in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "hd.model.picker absent")
        let message = element(.modelDisabled, in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 15), "hd.model.disabled absent")
        XCTAssertTrue(text(of: message).contains("le changement de modèle"), text(of: message))
        XCTAssertFalse(picker.isEnabled, "le sélecteur doit être désactivé")
        XCTAssertTrue(element(AccessibilityID.botRow("hv-bot-b"), in: app).isHittable, "les autres bots restent utilisables")
        send("ça marche sans le sélecteur", in: app)
        XCTAssertTrue(waitForState("completed", in: app), "l'envoi doit marcher")
        XCTAssertFalse(element(.conversationError, in: app).exists)
        XCTAssertEqual(setModelRequests(since: start).count, 0, "un sélecteur désactivé ne demande rien")
        XCTAssertEqual(posts(runs, since: start), 1)
        print("HV-DROP-MODEL message=\(text(of: message))")
        HVShot.capture("hd10-drop", app)
    }

    /// Lane 6 : le même choix deux fois de suite ne part qu'une fois
    func testSelectingTheSameOptionTwiceFastSendsOneSetModel() throws {
        try requireFakeServer()
        let app = launchWithTwoModels()
        openBot(in: app)
        openThread("s-past-1", in: app)
        XCTAssertTrue(waitForMessage(containing: "Réponse de test", in: app))
        let start = Date()
        pickModel("model-y", in: app)
        pickModel("model-y", in: app, lenient: true)
        XCTAssertTrue(waitForModel("model-y", in: app))
        usleep(500_000)
        let requests = setModelRequests(since: start)
        print("HV-MODEL double requests=\(requests.map { "\($0.path) \($0.model)" })")
        XCTAssertEqual(requests.count, 1, "\(requests)")
        HVShot.capture("hd10-double", app)
    }

    /// Lane 7 : choisir pendant un tour ne casse pas le tour ; le choix vaut pour le tour suivant
    /// Un message qui contient HV_SLOW espace les événements d'une seconde (faux serveur)
    func testSwitchingWhileATurnRunsLeavesTheTurnAloneAndAppliesToTheNextOne() throws {
        try requireFakeServer()
        let app = launchWithTwoModels()
        openBot(in: app)
        openThread("s-past-1", in: app)
        XCTAssertTrue(waitForMessage(containing: "Réponse de test", in: app))
        let start = Date()
        send("HV_SLOW go", in: app)
        XCTAssertTrue(element(.conversationBusy, in: app).waitForExistence(timeout: 10), "hd.conversation.busy absent pendant le tour")
        pickModel("model-y", in: app)
        XCTAssertTrue(waitForModel("model-y", in: app), "le sélecteur doit changer pendant le tour")
        XCTAssertTrue(element(.conversationBusy, in: app).exists, "le tour tourne encore")
        XCTAssertFalse(element(.composerSend, in: app).isEnabled)
        HVShot.capture("hd10-busy", app)
        XCTAssertTrue(waitForState("completed", in: app, timeout: 60), "le tour en cours doit finir completed")
        XCTAssertFalse(element(.conversationError, in: app).exists)
        XCTAssertEqual(posts(runs, since: start), 1)
        XCTAssertNil(postBodies(on: runs, since: start).first?["model"], "le tour en cours est parti avec le modèle d'avant")
        send("tour suivant", in: app)
        XCTAssertTrue(waitForMessage(containing: "Réponse de test", in: app))
        let deadline = Date().addingTimeInterval(20)
        while posts(runs, since: start) < 2, Date() < deadline { usleep(100_000) }
        XCTAssertEqual(postBodies(on: runs, since: start).last?["model"] as? String, "model-y", "le tour suivant part avec le modèle choisi")
    }

    /// Lane 8 : `HV_FAKE_MODE=slow` (chaque réponse attend 8 s) : le sélecteur montre l'attente, la fenêtre répond
    func testASlowServerShowsAWaitStateAndTheWindowStaysResponsive() throws {
        try configureFake(mode: "slow")
        let app = launchWithTwoModels()
        openBot(in: app)
        // la liste des fils et le transcript attendent 8 s chacun
        let row = element(AccessibilityID.threadRow("s-past-1"), in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 40), "hd.threads.row.s-past-1 absent")
        row.click()
        pickModel("model-y", in: app)
        let waiting = element(.modelWaiting, in: app)
        XCTAssertTrue(waiting.waitForExistence(timeout: 5), "hd.model.waiting absent : le sélecteur doit montrer l'attente")
        XCTAssertFalse(element(.modelPicker, in: app).isEnabled, "le sélecteur attend la confirmation")
        // la fenêtre répond pendant l'attente : le champ prend le texte tapé
        type("encore réactif", in: app)
        XCTAssertEqual(text(of: element(.composerInput, in: app)), "encore réactif")
        XCTAssertEqual(app.state, .runningForeground)
        HVShot.capture("hd10-slow", app)
        XCTAssertTrue(waitForModel("model-y", in: app, timeout: 40), "le modèle n'est jamais confirmé")
        XCTAssertFalse(element(.modelWaiting, in: app).exists, "l'attente doit disparaître")
    }

    /// Lane 9 : un fil rouvert dont la session a un autre modèle le montre
    func testReopeningAThreadShowsTheModelOfItsSession() throws {
        try requireFakeServer()
        FakeServer.lockModel(profile: "hv-bot-a", session: "s-past-1", model: "model-y")
        let start = Date()
        let app = launchWithTwoModels()
        openBot(in: app)
        XCTAssertEqual(text(of: element(.modelPicker, in: app)), "hv-fake-1", "un fil neuf suit le modèle du profil")
        openThread("s-past-1", in: app)
        XCTAssertTrue(waitForModel("model-y", in: app), "le fil rouvert doit montrer le modèle de sa session")
        XCTAssertEqual(setModelRequests(since: start).count, 0, "rouvrir un fil n'écrit aucun modèle")
        HVShot.capture("hd10-thread-model", app)
        send("avec le modèle de la session", in: app)
        XCTAssertTrue(waitForState("completed", in: app))
        XCTAssertEqual(postBodies(on: runs, since: start).last?["model"] as? String, "model-y")
    }

    // MARK: les approbations et l'outil en cours (HD-11)

    /// Les décisions envoyées à Hermes depuis `since` (le chemin finit par `/approval`), sans la sonde inerte de la route (`hd-probe-capabilities`)
    private func decisions(since: Date) -> [Request] {
        serverLog(since: since).filter { $0.method == "POST" && $0.path.hasSuffix("/approval") && !$0.path.contains("hd-probe-capabilities") }
    }

    /// Envoie un message qui fait demander une approbation (`HV_APPROVAL` : `file.write` veut écrire `/tmp/hv.txt`) et attend la feuille
    @discardableResult
    private func askForApproval(_ input: String = "HV_APPROVAL go", in app: XCUIApplication) -> XCUIElement {
        send(input, in: app)
        let sheet = element(.approvalSheet, in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 20), "hd.approval.sheet absent")
        return sheet
    }

    /// Lanes 1 et 2 : la feuille montre l'outil et ses paramètres avant toute réponse ; Oui envoie une décision et le tour finit
    func testApprovalYes() throws {
        try requireFakeServer()
        let start = Date()
        let app = launch()
        openBot(in: app)
        askForApproval(in: app)
        XCTAssertEqual(text(of: element(.approvalTool, in: app)), "file.write")
        XCTAssertTrue(text(of: element(.approvalParams, in: app)).contains("/tmp/hv.txt"), "hd.approval.params ne montre pas /tmp/hv.txt")
        XCTAssertTrue(element(.approvalYes, in: app).isEnabled)
        XCTAssertTrue(element(.approvalNo, in: app).isEnabled)
        XCTAssertEqual(decisions(since: start).count, 0, "rien ne part avant le clic")
        XCTAssertFalse(element(.conversationState, in: app).exists, "le tour attend l'utilisateur")
        HVShot.capture("hd11-sheet", app)
        element(.approvalYes, in: app).click()
        XCTAssertTrue(waitForState("completed", in: app), "le tour ne finit pas après Oui")
        XCTAssertTrue(element(.approvalSheet, in: app).waitForNonExistence(timeout: 5), "la feuille reste après la réponse")
        XCTAssertTrue(waitForMessage(containing: "Fichier /tmp/hv.txt écrit", in: app), "l'outil n'a pas tourné : \(shownMessages(in: app))")
        let sent = decisions(since: start)
        let bodies = postBodies(on: try XCTUnwrap(sent.first).path, since: start)
        print("HV-APPROVAL yes decisions=\(sent.map { "\($0.path) \($0.status ?? 0)" }) bodies=\(bodies.map { "\($0["choice"] ?? "?")" })")
        XCTAssertEqual(sent.count, 1, "une seule décision")
        XCTAssertEqual(bodies.first?["choice"] as? String, "once")
        XCTAssertEqual(sent.first?.status, 200)
        HVShot.capture("hd11-yes", app)
    }

    /// Lane 3 : Non envoie `deny` ; le tour montre l'état que Hermes annonce, l'outil ne tourne pas
    func testApprovalNo() throws {
        try requireFakeServer()
        let start = Date()
        let app = launch()
        openBot(in: app)
        askForApproval(in: app)
        XCTAssertEqual(text(of: element(.approvalTool, in: app)), "file.write")
        XCTAssertTrue(text(of: element(.approvalParams, in: app)).contains("/tmp/hv.txt"))
        element(.approvalNo, in: app).click()
        XCTAssertTrue(waitForState("completed", in: app), "le tour ne finit pas après Non")
        XCTAssertTrue(element(.approvalSheet, in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForMessage(containing: "Refus pris en compte", in: app), "le refus n'est pas montré : \(shownMessages(in: app))")
        XCTAssertFalse(shownMessages(in: app).contains { $0.contains("écrit") && !$0.contains("rien") }, "l'outil ne doit pas tourner après un refus")
        let sent = decisions(since: start)
        XCTAssertEqual(sent.count, 1, "une seule décision")
        XCTAssertEqual(postBodies(on: try XCTUnwrap(sent.first).path, since: start).first?["choice"] as? String, "deny")
        print("HV-APPROVAL no decisions=\(sent.map { "\($0.path) \($0.status ?? 0)" }) state=\(element(.conversationState, in: app).label)")
        HVShot.capture("hd11-no", app)
    }

    /// Échap ne ferme pas la feuille sans réponse : il refuse, le choix sans effet
    func testEscapeRefusesTheRequestAndNeverClosesTheSheetWithoutAnAnswer() throws {
        try requireFakeServer()
        let start = Date()
        let app = launch()
        openBot(in: app)
        askForApproval(in: app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForState("completed", in: app), "le tour ne finit pas après Échap")
        let sent = decisions(since: start)
        XCTAssertEqual(sent.count, 1, "Échap envoie une décision, pas zéro (feuille fermée sans réponse) ni deux")
        XCTAssertEqual(postBodies(on: try XCTUnwrap(sent.first).path, since: start).first?["choice"] as? String, "deny")
        XCTAssertTrue(waitForMessage(containing: "Refus pris en compte", in: app))
    }

    /// Lane 4 : `hd.tool.current` nomme l'outil pendant l'appel et s'efface à `tool.completed`
    func testCurrentTool() throws {
        try requireFakeServer()
        let app = launch()
        openBot(in: app)
        XCTAssertFalse(element(.toolCurrent, in: app).exists, "aucun outil avant le tour")
        send("HV_TOOL_SHELL go", in: app)
        let tool = element(.toolCurrent, in: app)
        XCTAssertTrue(tool.waitForExistence(timeout: 10), "hd.tool.current absent pendant l'appel")
        XCTAssertEqual(text(of: tool), "Outil en cours : shell.exec")
        XCTAssertFalse(element(.approvalSheet, in: app).exists, "un outil sans demande n'ouvre pas de feuille")
        HVShot.capture("hd11-current-tool", app)
        XCTAssertTrue(tool.waitForNonExistence(timeout: 20), "hd.tool.current reste après tool.completed")
        XCTAssertTrue(waitForState("completed", in: app))
        XCTAssertTrue(waitForMessage(containing: "Outil terminé", in: app))
    }

    /// Lane 5 : 200 000 caractères, dont des caractères de contrôle : la feuille défile, marque ce qu'elle ne montre pas, la fenêtre répond
    func testAHugeParameterScrollsAndMarksWhatItDoesNotShow() throws {
        try requireFakeServer()
        let app = launch()
        openBot(in: app)
        askForApproval("HV_APPROVAL_HUGE go", in: app)
        let params = element(.approvalParams, in: app)
        XCTAssertTrue(params.waitForExistence(timeout: 10), "hd.approval.params absent")
        let shown = text(of: params)
        XCTAssertTrue(shown.hasPrefix("HUGE-BEGIN "), "le début des paramètres n'est pas montré : \(shown.prefix(40))")
        XCTAssertLessThan(shown.count, 200_000, "la feuille ne montre pas tout : elle doit le dire")
        let cut = element(.approvalCut, in: app)
        XCTAssertTrue(cut.waitForExistence(timeout: 5), "hd.approval.cut absent : une coupure doit se voir")
        print("HV-HUGE shown_chars=\(shown.count) cut=\(text(of: cut))")
        XCTAssertTrue(text(of: cut).contains("non affichés"), text(of: cut))
        XCTAssertTrue(text(of: cut).contains("200"), "le marqueur donne la taille totale : \(text(of: cut))")
        params.scroll(byDeltaX: 0, deltaY: -2000)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(element(.approvalNo, in: app).isHittable, "la fenêtre ne répond plus")
        HVShot.capture("hd11-huge-params", app)
        element(.approvalNo, in: app).click()
        XCTAssertTrue(waitForState("completed", in: app))
    }

    /// Lane 6 : un double clic sur Oui n'envoie qu'une décision
    func testADoubleClickOnYesSendsOneDecision() throws {
        try requireFakeServer()
        let start = Date()
        let app = launch()
        openBot(in: app)
        askForApproval(in: app)
        element(.approvalYes, in: app).doubleClick()
        XCTAssertTrue(waitForState("completed", in: app))
        usleep(500_000)
        let sent = decisions(since: start)
        print("HV-APPROVAL double decisions=\(sent.map { "\($0.path) \($0.status ?? 0)" })")
        XCTAssertEqual(sent.count, 1, "un double clic doit envoyer une seule décision")
        HVShot.capture("hd11-double", app)
    }

    /// Lane 7 : la liaison est coupée pendant que la feuille attend ; la réponse ne part pas, la feuille reste, la décision part une fois au retour
    func testACutWhileTheSheetWaitsKeepsItAndTheDecisionGoesOutOnceWhenTheLinkReturns() throws {
        try requireFakeServer()
        let start = Date()
        let app = launch()
        openBot(in: app)
        let sheet = askForApproval(in: app)
        serverPost("/_hv/cut", ["seconds": 8])
        let cutAt = Date()
        element(.approvalYes, in: app).click()
        let status = element(.approvalStatus, in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5), "hd.approval.status absent")
        let queued = Date().addingTimeInterval(5)
        while !text(of: status).contains("part dès"), Date() < queued { usleep(100_000) }
        XCTAssertTrue(text(of: status).contains("part dès"), "la feuille ne dit pas que la réponse attend la liaison : \(text(of: status))")
        XCTAssertTrue(sheet.exists, "la feuille doit rester pendant la coupure")
        XCTAssertEqual(decisions(since: start).filter { $0.status == 200 }.count, 0, "aucune décision n'est prise pendant la coupure")
        HVShot.capture("hd11-cut", app)
        XCTAssertTrue(waitForState("completed", in: app, timeout: 40), "le tour ne finit pas après le retour de la liaison")
        let sent = decisions(since: start)
        let accepted = sent.filter { $0.status == 200 }
        print("HV-APPROVAL cut elapsed=\(Int(Date().timeIntervalSince(cutAt)))s decisions=\(sent.map { "\($0.path) \($0.status ?? 0)" })")
        XCTAssertEqual(accepted.count, 1, "la décision doit partir une fois au retour de la liaison")
        XCTAssertGreaterThanOrEqual(sent.filter { $0.status == 503 }.count, 1, "la coupure n'a refusé aucun essai : le test ne prouve rien")
        XCTAssertTrue(element(.approvalSheet, in: app).waitForNonExistence(timeout: 5))
    }

    /// Lane 8 : `HV_FAKE_MODE=drop-route HV_DROP=approve` : la feuille montre la demande, grise la réponse et nomme le kill switch
    func testADroppedApproveRouteShowsTheRequestWithTheDisabledMessageAndTheKillSwitch() throws {
        try configureFake(mode: "drop-route", drop: "approve")
        let start = Date()
        let app = launch()
        openBot(in: app)
        askForApproval(in: app)
        XCTAssertEqual(text(of: element(.approvalTool, in: app)), "file.write")
        XCTAssertTrue(text(of: element(.approvalParams, in: app)).contains("/tmp/hv.txt"), "la demande doit rester affichée")
        let disabled = element(.approvalDisabled, in: app)
        XCTAssertTrue(disabled.waitForExistence(timeout: 10), "hd.approval.disabled absent")
        XCTAssertTrue(text(of: disabled).contains("la réponse à une approbation"), text(of: disabled))
        let kill = element(.approvalKillSwitch, in: app)
        XCTAssertTrue(kill.exists, "hd.approval.kill-switch absent")
        XCTAssertTrue(text(of: kill).contains("kill switch"), text(of: kill))
        XCTAssertFalse(element(.approvalYes, in: app).isEnabled, "Oui doit être grisé")
        XCTAssertFalse(element(.approvalNo, in: app).isEnabled, "Non doit être grisé")
        XCTAssertEqual(decisions(since: start).count, 0, "une route retirée ne reçoit rien")
        print("HV-APPROVAL drop message=\(text(of: disabled)) kill=\(text(of: kill))")
        HVShot.capture("hd11-drop", app)
    }

    /// Lane 10 : 60 s sans réponse : l'écran dit que le bot attend l'utilisateur, la feuille et la fenêtre répondent
    func testASheetLeftWaitingForAMinuteSaysTheBotWaitsAndTheWindowStaysResponsive() throws {
        try requireFakeServer()
        let app = launch()
        openBot(in: app)
        askForApproval(in: app)
        let status = element(.approvalStatus, in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5), "hd.approval.status absent")
        XCTAssertTrue(text(of: status).contains("attend votre réponse"), text(of: status))
        let hang = element(.perfHang, in: app)
        // la feuille vient de s'ouvrir : sa présentation peut bloquer le fil principal un instant, ce n'est pas l'attente ; on mesure les 60 s qui suivent
        let presentedAt = Date()
        sleep(2)
        let waitStart = Date()
        let deadline = waitStart.addingTimeInterval(60)
        while Date() < deadline {
            sleep(5)
            XCTAssertEqual(app.state, .runningForeground, "l'app a quitté le premier plan")
            XCTAssertTrue(element(.approvalSheet, in: app).exists, "la feuille a disparu sans réponse")
            XCTAssertTrue(element(.approvalYes, in: app).isHittable, "la fenêtre ne répond plus")
        }
        // le chien de garde du fil principal (mode test) donne chaque blocage de 50 ms ou plus : [début en secondes depuis 1970, durée en ms]
        let report = (try? JSONSerialization.jsonObject(with: Data(text(of: hang).utf8))) as? [String: Any]
        let hangs = (report?["hangs"] as? [[Double]] ?? []).map { (start: $0[0], ms: Int($0[1])) }
        let during = hangs.filter { $0.start >= waitStart.timeIntervalSince1970 }
        let before = hangs.filter { $0.start < waitStart.timeIntervalSince1970 }
        let longest = during.map(\.ms).max() ?? 0
        print("HV-APPROVAL wait60 presented_at=\(presentedAt.timeIntervalSince1970) samples=\(report?["samples"] ?? "?") hangs_before_wait=\(before.map { "\($0.start)/\($0.ms)ms" }) hangs_during_wait=\(during.map { "\($0.start)/\($0.ms)ms" }) longest_during_wait_ms=\(longest) status=\(text(of: status))")
        XCTAssertNotNil(report, "hd.perf.hang ne rend pas de rapport : \(text(of: hang))")
        XCTAssertLessThan(longest, 250, "le fil principal a été bloqué pendant l'attente de la feuille : \(text(of: hang))")
        XCTAssertTrue(text(of: status).contains("attend votre réponse"), text(of: status))
        HVShot.capture("hd11-wait", app)
        element(.approvalNo, in: app).click()
        XCTAssertTrue(waitForState("completed", in: app))
    }
}
