import Foundation

@main
struct StopAllCheck {
    @MainActor static func main() async {
        let endpoint = KillSwitchAPI(baseURL: URL(string: "http://127.0.0.1:18642")!, apiKey: nil)
        let runs = (0..<3).map { KillSwitch.Run(profile: "p\($0)", id: "r\($0)") }
        var sent: [KillSwitch.Run] = []
        var confirmed: [KillSwitch.Run] = []
        var targets = runs
        let model = KillSwitch(endpoint: { endpoint }, connection: { "test" }, runs: { targets }, profiles: { ["p0"] }, confirmed: { run, _, _ in confirmed.append(run) }, cancel: { _, run, _ in
            sent.append(run)
            try await Task.sleep(for: .milliseconds(10))
            return "cancelled"
        })
        async let first: Void = model.stopAll()
        async let second: Void = model.stopAll()
        _ = await (first, second)
        assert(Set(sent) == Set(runs) && sent.count == 3)
        assert(confirmed.count == 3)
        assert(model.message.isEmpty)
        targets = []
        await model.stopAll()
        assert(sent.count == 3 && model.message.isEmpty)
        targets = runs
        let dropped = KillSwitch(endpoint: { endpoint }, connection: { "test" }, runs: { targets }, profiles: { [] }, confirmed: { _, _, _ in }, cancel: { _, _, _ in throw URLError(.cannotConnectToHost) }, canCancel: { _, _, _ in true })
        await dropped.stopAll()
        assert(dropped.message == KillSwitch.partialStop)
        await dropped.checkSupport()
        assert(dropped.message == KillSwitch.partialStop)
        var starting = true
        targets = []
        sent = []
        let late = KillSwitch(endpoint: { endpoint }, connection: { "test" }, runs: { targets }, profiles: { [] }, confirmed: { _, _, _ in }, pending: { starting ? ["t"] : [] }, cancel: { _, run, _ in
            sent.append(run)
            return "cancelled"
        })
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            targets = [runs[0]]
            starting = false
        }
        await late.stopAll()
        assert(sent == [runs[0]])
        let unsupported = KillSwitch(endpoint: { endpoint }, connection: { "test" }, runs: { runs }, profiles: { ["p0"] }, confirmed: { _, _, _ in }, canCancel: { _, _, _ in false })
        await unsupported.checkSupport()
        assert(unsupported.isDisabled && unsupported.message.isEmpty)
        let disconnected = KillSwitch(endpoint: { nil }, connection: { "test" }, runs: { runs }, profiles: { [] }, confirmed: { _, _, _ in })
        await disconnected.stopAll()
        assert(disconnected.isDisabled && disconnected.message == KillSwitch.partialStop)
        var mixedResults = 0
        let mixed = KillSwitch(endpoint: { endpoint }, connection: { "test" }, runs: { runs }, profiles: { [] }, confirmed: { _, _, _ in mixedResults += 1 }, cancel: { _, run, _ in
            if run == runs[0] { throw URLError(.cannotConnectToHost) }
            return "cancelled"
        })
        await mixed.stopAll()
        assert(mixedResults == 2 && mixed.message == KillSwitch.partialStop)
        var machine = ConversationMachine()
        _ = machine.handle(.select(bot: "p0"))
        _ = machine.handle(.send("premier tour"))
        let unsaved = machine.screen!
        _ = machine.handle(.created(unsaved, session: "s0", message: "premier tour"))
        let saved = machine.screen!
        _ = machine.handle(.runStarted(saved, run: "r0"))
        _ = machine.handle(.observed(saved, tool: "terminal", approval: nil))
        _ = machine.handle(.stopped(saved, run: "r0", end: .cancelled))
        assert(machine.shown.conversation.end == .cancelled && machine.shown.tool == nil)
        assert(machine.threads.count == 1 && machine.shown.conversation.entries.count == 1)
        _ = machine.handle(.send("second tour"))
        _ = machine.handle(.runStarted(saved, run: "r1"))
        _ = machine.handle(.stopped(saved, run: "r0", end: .cancelled))
        assert(machine.shown.run == "r1" && machine.shown.step == .sending)
        print("HD15 CHECK trois tours, double clic, aucun tour, panne, démarrage en vol, liaison absente, échec partiel : OK")
    }
}
