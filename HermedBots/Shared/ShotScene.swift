import Foundation

/// Scènes de capture XCUITest : données fictives seulement, sans hôte ni nom réel
enum ShotScene: String, CaseIterable {
    case footerReady = "footer-ready"
    case footerConnecting = "footer-connecting"
    case footerUntested = "footer-untested"
    case footerFailed = "footer-failed"
    case footerMissingKey = "footer-missing-key"
    case footerTunnel = "footer-tunnel"
    case bannerDegraded = "banner-degraded"
    case connection
    case error
    case emptyHome = "empty-home"
    case emptyConversation = "empty-conversation"
    case markdown
    case markdownStreaming = "markdown-streaming"
    case compacted
    case aboutConnecting = "about-connecting"
    case aboutReady = "about-ready"
    case aboutUntested = "about-untested"
    case aboutFailed = "about-failed"
}
