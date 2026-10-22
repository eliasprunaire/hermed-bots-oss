// build : swiftc -O -o hv-urlsession-control hv-urlsession-control.swift
// usage : hv-urlsession-control idle|shared|ephemeral, avec un faux serveur sur 127.0.0.1:18642
import Foundation

// processus témoin de la lane 3 : aucun accès au Trousseau
// argument 1 : "idle" n'ouvre aucune connexion, "shared" fait un GET avec URLSession.shared,
// "ephemeral" fait le même GET avec une session éphémère et un délégué, comme HermesClient
// dans tous les cas le processus attend 4 s
final class Collector: NSObject, URLSessionDataDelegate {
    let done: DispatchSemaphore
    var body = Data()
    init(_ done: DispatchSemaphore) { self.done = done }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { body.append(data) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("GET /health (ephemeral) -> \(String(decoding: body, as: UTF8.self))")
        done.signal()
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "idle"
let url = URL(string: "http://127.0.0.1:18642/health")!
let done = DispatchSemaphore(value: 0)
switch mode {
case "shared":
    URLSession.shared.dataTask(with: url) { data, _, _ in
        print("GET /health (shared) -> \(data.map { String(decoding: $0, as: UTF8.self) } ?? "erreur")")
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 4)
case "ephemeral":
    let session = URLSession(configuration: .ephemeral, delegate: Collector(done), delegateQueue: nil)
    session.dataTask(with: url).resume()
    _ = done.wait(timeout: .now() + 4)
default:
    break
}
Thread.sleep(forTimeInterval: 4)
