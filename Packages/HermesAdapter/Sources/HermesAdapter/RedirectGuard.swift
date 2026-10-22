import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Suit une redirection seulement vers la même origine (schéma, hôte, port) : sinon un 3xx vers `127.1` ou vers un autre hôte contournerait la liste des cibles permises
public final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    public override init() { super.init() }

    public static func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b, let schemeA = a.scheme?.lowercased(), let hostA = a.host?.lowercased() else { return false }
        func port(_ url: URL, _ scheme: String) -> Int { url.port ?? (scheme == "https" ? 443 : 80) }
        return schemeA == b.scheme?.lowercased() && hostA == b.host?.lowercased() && port(a, schemeA) == port(b, schemeA)
    }

    /// `nil` laisse la réponse 3xx au code appelant, qui la traite comme une erreur HTTP
    static func target(of task: URLSessionTask, redirectedTo request: URLRequest) -> URLRequest? {
        let original = task.originalRequest?.url
        guard sameOrigin(original, request.url) else { return nil }
        func profile(_ url: URL?) -> String? {
            guard let parts = url?.pathComponents, parts.count > 2, parts[1] == "p" else { return nil }
            return parts[2]
        }
        return profile(original) == profile(request.url) ? request : nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.target(of: task, redirectedTo: request))
    }
}
