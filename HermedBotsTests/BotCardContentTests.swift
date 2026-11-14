import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte
/// Contenu produit de la carte d'accueil en mode dégradé : le modèle, la pastille, l'aide — pas le texte du bandeau
final class BotCardContentTests: XCTestCase {
    @MainActor
    func testADegradedCardShowsTheModelThePillAndTheHelpNotTheBannerText() async {
        let connection: @MainActor () -> String = { "http://hermes.invalid" }
        let lock = ProfileLock(connection: connection, read: {
            throw SSHFailure.unreachable("détection Desktop indisponible")
        })
        let refreshed: Bool = await lock.refresh()
        XCTAssertFalse(refreshed)
        let bot = Bot(id: "hv-bot-a", name: "Bot de capture", model: "demo")
        let content = BotCardContent(bot: bot, lockLabel: lock.sidebarLabel(bot.id), lockHelp: lock.reason(bot.id))
        XCTAssertEqual(content.subtitle, "demo")
        XCTAssertEqual(content.lockLabel, "Dégradé")
        XCTAssertEqual(content.lockHelp, lock.reason(bot.id))
        XCTAssertTrue(content.lockHelp?.contains("la détection de Hermes") == true, content.lockHelp ?? "")
        XCTAssertFalse(content.subtitle.contains("Mode dégradé"))
        XCTAssertFalse(content.lockHelp?.contains("détection Desktop indisponible") == true)
    }

    func testACardWithoutALockKeepsTheModelAndHasNoPill() {
        let bot = Bot(id: "hv-bot-a", name: "Bot de capture", model: "demo")
        let content = BotCardContent(bot: bot, lockLabel: nil, lockHelp: nil)
        XCTAssertEqual(content.subtitle, "demo")
        XCTAssertNil(content.lockLabel)
        XCTAssertNil(content.lockHelp)
        XCTAssertFalse(content.subtitle.contains("Mode dégradé"))
    }

    func testACardWithoutAModelKeepsTheFallbackSubtitleAndThePill() {
        let bot = Bot(id: "hv-bot-a", name: "Bot de capture", model: nil)
        let content = BotCardContent(bot: bot, lockLabel: "Dégradé", lockHelp: "Mode dégradé : la détection de Hermes Desktop est indisponible. Les écritures de ce profil sont bloquées.")
        XCTAssertEqual(content.subtitle, "Modèle du profil")
        XCTAssertEqual(content.lockLabel, "Dégradé")
        XCTAssertTrue(content.lockHelp?.contains("la détection de Hermes") == true)
        XCTAssertFalse(content.subtitle.contains("Mode dégradé"))
    }
}
