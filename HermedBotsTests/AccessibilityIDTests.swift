import AppSettings
import XCTest

final class AccessibilityIDTests: XCTestCase {
    // hd.<écran>.<élément>, minuscules, kebab-case
    private let convention = /hd(\.[a-z]+(-[a-z]+)*)+/

    func testEveryFixedIdFollowsTheConventionAndIsUnique() {
        let ids = AccessibilityID.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertNotNil(id.wholeMatch(of: convention), id)
        }
    }

    func testTheShellIdsAreTheOnesTheVerifySkillNames() {
        XCTAssertEqual(AccessibilityID.botsList.rawValue, "hd.bots.list")
        XCTAssertEqual(AccessibilityID.statusVersion.rawValue, "hd.status.version")
        XCTAssertEqual(AccessibilityID.statusPort.rawValue, "hd.status.port")
    }

    func testTheConnectionViewIdsAreStable() {
        XCTAssertEqual(AccessibilityID.connectionOpen.rawValue, "hd.connection.open")
        XCTAssertEqual(AccessibilityID.connectionHost.rawValue, "hd.connection.host")
        XCTAssertEqual(AccessibilityID.connectionAuthMode.rawValue, "hd.connection.auth-mode")
        XCTAssertEqual(AccessibilityID.connectionWrapper.rawValue, "hd.connection.wrapper")
        XCTAssertEqual(AccessibilityID.connectionKeyCommand.rawValue, "hd.connection.key-command")
        XCTAssertEqual(AccessibilityID.connectionUser.rawValue, "hd.connection.user")
        XCTAssertEqual(AccessibilityID.connectionResolvedHost.rawValue, "hd.connection.resolved-host")
        XCTAssertEqual(AccessibilityID.connectionPort.rawValue, "hd.connection.port")
        XCTAssertEqual(AccessibilityID.connectionIdentity.rawValue, "hd.connection.identity")
        XCTAssertEqual(AccessibilityID.connectionIdentityPresent.rawValue, "hd.connection.identity-present")
        XCTAssertEqual(AccessibilityID.connectionTunnelState.rawValue, "hd.connection.tunnel-state")
        XCTAssertEqual(AccessibilityID.connectionMessage.rawValue, "hd.connection.message")
        XCTAssertEqual(AccessibilityID.updatesCheck.rawValue, "hd.updates.check")
        XCTAssertEqual(AccessibilityID.settingsConnection.rawValue, SettingsPane.connection.accessibilityID)
        XCTAssertEqual(AccessibilityID.settingsUpdates.rawValue, SettingsPane.updates.accessibilityID)
    }

    func testTheBotListIdsAreStable() {
        XCTAssertEqual(AccessibilityID.botsChange.rawValue, "hd.bots.change")
        XCTAssertEqual(AccessibilityID.botsChangeApply.rawValue, "hd.bots.change.apply")
        XCTAssertEqual(AccessibilityID.botsEmpty.rawValue, "hd.bots.empty")
        XCTAssertEqual(AccessibilityID.botsError.rawValue, "hd.bots.error")
        XCTAssertEqual(AccessibilityID.botsRetry.rawValue, "hd.bots.retry")
        XCTAssertEqual(AccessibilityID.threadsDisabled("hv-bot-a"), "hd.threads.disabled.hv-bot-a")
        XCTAssertEqual(AccessibilityID.threadsEmpty("hv-bot-a"), "hd.threads.empty.hv-bot-a")
        XCTAssertEqual(AccessibilityID.threadsError("hv-bot-a"), "hd.threads.error.hv-bot-a")
    }

    func testTheConversationIdsAreStable() {
        XCTAssertEqual(AccessibilityID.conversationView.rawValue, "hd.conversation.view")
        XCTAssertEqual(AccessibilityID.conversationState.rawValue, "hd.conversation.state")
        XCTAssertEqual(AccessibilityID.conversationEmpty.rawValue, "hd.conversation.empty")
        XCTAssertEqual(AccessibilityID.conversationBusy.rawValue, "hd.conversation.busy")
        XCTAssertEqual(AccessibilityID.conversationError.rawValue, "hd.conversation.error")
        XCTAssertEqual(AccessibilityID.composerInput.rawValue, "hd.composer.input")
        XCTAssertEqual(AccessibilityID.composerSend.rawValue, "hd.composer.send")
        XCTAssertEqual(AccessibilityID.sessionNew.rawValue, "hd.session.new")
        // un message que Hermes n'a pas encore numéroté porte une clé locale, préfixée pour ne jamais ressembler à un numéro
        XCTAssertEqual(AccessibilityID.conversationMessage(7), "hd.conversation.message.7")
        XCTAssertEqual(AccessibilityID.conversationMessagePending(3), "hd.conversation.message.pending-3")
    }

    func testThePerfProbeIdIsStable() {
        XCTAssertEqual(AccessibilityID.perfHang.rawValue, "hd.perf.hang")
        XCTAssertEqual(AccessibilityID.perfModel.rawValue, "hd.perf.model")
    }

    func testTheApprovalAndCurrentToolIdsAreStable() {
        XCTAssertEqual(AccessibilityID.approvalSheet.rawValue, "hd.approval.sheet")
        XCTAssertEqual(AccessibilityID.approvalTool.rawValue, "hd.approval.tool")
        XCTAssertEqual(AccessibilityID.approvalParams.rawValue, "hd.approval.params")
        XCTAssertEqual(AccessibilityID.approvalYes.rawValue, "hd.approval.yes")
        XCTAssertEqual(AccessibilityID.approvalNo.rawValue, "hd.approval.no")
        XCTAssertEqual(AccessibilityID.approvalStatus.rawValue, "hd.approval.status")
        XCTAssertEqual(AccessibilityID.approvalCut.rawValue, "hd.approval.cut")
        XCTAssertEqual(AccessibilityID.approvalDisabled.rawValue, "hd.approval.disabled")
        XCTAssertEqual(AccessibilityID.approvalKillSwitch.rawValue, "hd.approval.kill-switch")
        XCTAssertEqual(AccessibilityID.toolCurrent.rawValue, "hd.tool.current")
    }

    func testTheModelPickerIdsAreStable() {
        XCTAssertEqual(AccessibilityID.modelPicker.rawValue, "hd.model.picker")
        XCTAssertEqual(AccessibilityID.modelWaiting.rawValue, "hd.model.waiting")
        XCTAssertEqual(AccessibilityID.modelError.rawValue, "hd.model.error")
        XCTAssertEqual(AccessibilityID.modelDisabled.rawValue, "hd.model.disabled")
    }

    func testDynamicIdsAppendTheHermesIdentifier() {
        XCTAssertEqual(AccessibilityID.botRow("hv-bot-a"), "hd.bots.row.hv-bot-a")
        XCTAssertEqual(AccessibilityID.botName("hv-bot-a"), "hd.bots.row.hv-bot-a.name")
        XCTAssertEqual(AccessibilityID.botModel("hv-bot-a"), "hd.bots.row.hv-bot-a.model")
        XCTAssertEqual(AccessibilityID.botThreads("hv-bot-a"), "hd.bots.row.hv-bot-a.threads")
        XCTAssertEqual(AccessibilityID.threadRow("s1"), "hd.threads.row.s1")
        XCTAssertEqual(AccessibilityID.conversationMessage(7), "hd.conversation.message.7")
        XCTAssertEqual(AccessibilityID.modelOption("gpt-x"), "hd.model.option.gpt-x")
        XCTAssertEqual(AccessibilityID.degradedFeature("set_model"), "hd.banner.degraded.feature.set_model")
    }
}
