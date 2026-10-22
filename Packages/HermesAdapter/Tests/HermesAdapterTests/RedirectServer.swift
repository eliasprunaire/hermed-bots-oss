import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Serveur HTTP local minimal : répond 302 vers `location(port)` à la première requête, puis 200 à la suivante
final class RedirectServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var seen: [String] = []

    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    init(location: @escaping (UInt16) -> String) throws {
        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let descriptor = socket(AF_INET, stream, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")  // port 0 : le système choisit
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard bound == 0, named == 0, listen(descriptor, 8) == 0 else { close(descriptor); throw POSIXError(.EADDRNOTAVAIL) }
        self.descriptor = descriptor
        self.port = UInt16(bigEndian: address.sin_port)
        let target = location(port)
        Thread.detachNewThread { [self] in serve(target) }
    }

    deinit { close(descriptor) }

    private func serve(_ target: String) {
        while true {
            let connection = accept(descriptor, nil, nil)
            if connection < 0 { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(connection, &buffer, buffer.count, 0)
            let line = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self).split(separator: "\r\n").first ?? ""
            lock.lock()
            seen.append(line.split(separator: " ").dropFirst().first.map(String.init) ?? "")
            let first = seen.count == 1
            lock.unlock()
            let reply = first
                ? "HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"data\":[]}"
            _ = reply.withCString { send(connection, $0, strlen($0), 0) }
            close(connection)
        }
    }
}
