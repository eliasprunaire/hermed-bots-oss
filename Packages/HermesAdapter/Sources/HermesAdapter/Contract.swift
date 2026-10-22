import Foundation

/// Noms logiques des contrats, ceux des fixtures `contract.json`
/// Ce tableau est le seul endroit qui connaît les chemins : un changement de route ne touche que lui
public enum Contract: String, CaseIterable, Sendable {
    case version
    case profileServed = "profile_served"
    case listSessions = "list_sessions"
    case sessionMessages = "session_messages"
    case newSession = "new_session"
    case sendMessage = "send_message"
    case startRun = "start_run"
    case runEvents = "run_events"
    case setModel = "set_model"
    case approve

    var method: String {
        switch self {
        case .version, .profileServed, .listSessions, .sessionMessages, .runEvents: return "GET"
        case .newSession, .sendMessage, .startRun, .setModel, .approve: return "POST"
        }
    }

    var path: String {
        switch self {
        case .version: return "/p/{profile}/health"
        case .profileServed: return "/p/{profile}/v1/models"
        case .listSessions, .newSession: return "/p/{profile}/api/sessions"
        case .sendMessage: return "/p/{profile}/api/sessions/{session}/chat"
        case .sessionMessages: return "/p/{profile}/api/sessions/{session}/messages"
        case .startRun: return "/p/{profile}/v1/runs"
        case .runEvents: return "/p/{profile}/v1/runs/{run}/events"
        case .setModel: return "/p/{profile}/api/sessions/{session}/model"
        case .approve: return "/p/{profile}/v1/runs/{run}/approval"
        }
    }

    /// Chemin avec chaque variable encodée comme un seul segment
    func resolve(_ variables: [String: String]) -> String {
        var segment = CharacterSet.alphanumerics
        segment.insert(charactersIn: "-._~")
        var resolved = path
        for (name, value) in variables {
            let encoded = value.addingPercentEncoding(withAllowedCharacters: segment) ?? value
            resolved = resolved.replacingOccurrences(of: "{\(name)}", with: encoded)
        }
        return resolved
    }
}
