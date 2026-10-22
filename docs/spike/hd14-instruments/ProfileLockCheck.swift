import Foundation

@main
struct ProfileLockCheck {
    @MainActor static func main() async {
        var host = "a"
        var body = #"{"held":[]}"#
        var fails = false
        let lock = ProfileLock(connection: { host }, read: {
            if fails { throw URLError(.cannotConnectToHost) }
            return Data(body.utf8)
        })
        assert(lock.state("hv-bot-a") == .unknown)
        let allowed = await lock.permits("hv-bot-a", on: "a")
        assert(allowed)
        body = #"{"held":["hv-bot-a"]}"#
        await lock.refresh()
        assert(lock.state("hv-bot-a") == .held)
        assert(lock.state("hv-bot-b") == .free)
        let denied = await lock.permits("hv-bot-a", on: "a")
        assert(!denied)
        body = #"{"held":[]}"#
        await lock.refresh()
        assert(lock.state("hv-bot-a") == .free)
        host = "b"
        assert(lock.state("hv-bot-a") == .unknown)
        let wrongHost = await lock.permits("hv-bot-a", on: "a")
        assert(!wrongHost)
        body = #"{"held":null}"#
        await lock.refresh()
        assert(lock.state("hv-bot-a") == .unknown)
        body = #"{"held":[]}"#
        await lock.refresh()
        fails = true
        await lock.refresh()
        assert(lock.state("hv-bot-a") == .unknown)

        var continuation: CheckedContinuation<Data, Error>?
        let delayed = ProfileLock(connection: { host }, read: {
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        let request = Task { await delayed.permits("hv-bot-a", on: "b") }
        while continuation == nil { await Task.yield() }
        host = "c"
        continuation!.resume(returning: Data(#"{"held":[]}"#.utf8))
        let changedHost = await request.value
        assert(!changedHost)
        assert(delayed.state("hv-bot-a") == .unknown)
        print("HD14 ProfileLock checks OK: initial, free, held, isolation, release, malformed, transport, stale host")
    }
}
