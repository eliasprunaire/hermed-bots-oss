import Foundation

@main
struct OrbCheck {
    static func main() async throws {
        let base = URL(string: "http://127.0.0.1:18642")!
        let key = ProcessInfo.processInfo.environment["HV_TEST_API_KEY"]
        let api = KillSwitchAPI(baseURL: base, apiKey: key)
        let available = try await api.supportsCancel(profile: "hv-bot-a")
        precondition(available)
        var request = URLRequest(url: base.appendingPathComponent("p/hv-bot-a/v1/runs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(#"{"input":"HV_TOOL_SLEEP go"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 202)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let run = result["run_id"] as! String
        print("HD15 ORB started run=\(run)")
        fflush(stdout)
        try await Task.sleep(for: .seconds(3))
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        ps.arguments = ["docker", "exec", "hv-hermes-test", "ps", "-eo", "pid,ppid,pgid,sid,etime,args"]
        print("HD15 ORB processus avant cancel_run")
        try ps.run()
        ps.waitUntilExit()
        precondition(ps.terminationStatus == 0)
        let start = ContinuousClock.now
        let state = try await api.cancel(.init(profile: "hv-bot-a", id: run))
        precondition(state == "cancelled")
        print("HD15 ORB server=\(state) elapsed=\(ContinuousClock.now - start)")
        print("HD15 ORB processus après cancel_run")
        let after = Process()
        after.executableURL = ps.executableURL
        after.arguments = ps.arguments
        let output = Pipe()
        after.standardOutput = output
        try after.run()
        let processes = output.fileHandleForReading.readDataToEndOfFile()
        after.waitUntilExit()
        precondition(after.terminationStatus == 0)
        let text = String(decoding: processes, as: UTF8.self)
        print(text)
        precondition(!text.split(separator: "\n").contains { $0.hasSuffix("sleep 300") })
        print("HD15 ORB API OK. Le clic UI reste en attente du tunnel VM vers OrbStack.")
    }
}
