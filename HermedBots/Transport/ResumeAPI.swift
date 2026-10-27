import Foundation
import HermesAdapter

struct ResumeAPI: Sendable {
    let baseURL: URL
    let apiKey: String?
    var apiKeyForProfile: (@Sendable (String) throws -> String?)? = nil

    /// Bearer du profil de l'URL seulement : jamais la clé d'un autre profil
    func authorization(for profile: String) throws -> String? {
        if let apiKeyForProfile { return try apiKeyForProfile(profile) }
        return apiKey
    }

    func makeRequest(profile: String, input: String, session: String, model: String?, key: String) throws -> URLRequest {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = profile.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "p/\(encoded)/v1/runs", relativeTo: baseURL)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        if let apiKey = try authorization(for: profile) {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body = ["input": input, "session_id": session]
        if let model { body["model"] = model }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func start(profile: String, input: String, session: String, model: String?, key: String) async throws -> String {
        let request = try makeRequest(profile: profile, input: input, session: session, model: model, key: key)
        let transport = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch { throw HermesError.unreachable(url: baseURL.absoluteString, reason: "\(error)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HermesError.http(contract: "start_run", status: status, detail: nil) }
        struct Reply: Decodable { let run_id: String }
        let run = try JSONDecoder().decode(Reply.self, from: data).run_id
        guard !run.isEmpty else { throw HermesError.decoding(contract: "start_run", detail: "run_id absent") }
        return run
    }
}
