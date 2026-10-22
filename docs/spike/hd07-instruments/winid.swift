// winid.swift <pid> [secondes] : imprime le numéro de la fenêtre à l'écran de ce pid (CGWindowListCopyWindowInfo), ou NONE avec la liste de ses fenêtres sur stderr
// Sert à `screencapture -l<numéro>` : XCUITest ne voit pas une app lancée à la main
import CoreGraphics
import Foundation

func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}

let pid = Int32(CommandLine.arguments[1])!
let wait = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 10
let deadline = Date().addingTimeInterval(wait)
while Date() < deadline {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    // la plus grande fenêtre du pid : une feuille ou un menu est plus petit que la fenêtre principale
    let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    if let best = mine.max(by: { area($0) < area($1) }), let id = best[kCGWindowNumber as String] as? Int {
        print(id)
        exit(0)
    }
    usleep(200_000)
}
// diagnostic : toutes les fenêtres du pid, visibles ou non, sur la sortie d'erreur
let every = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in every where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    FileHandle.standardError.write(Data("fenêtre pid=\(pid) layer=\(w[kCGWindowLayer as String] ?? "?") onscreen=\(w[kCGWindowIsOnscreen as String] ?? "non") alpha=\(w[kCGWindowAlpha as String] ?? "?") aire=\(Int(area(w)))\n".utf8))
}
print("NONE")
exit(1)
