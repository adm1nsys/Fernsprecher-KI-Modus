//
//  Session.swift
//  fernsprecher-ki-modus-an
//
//  Files of a running call and the control socket the CLI commands talk to.
//

import Foundation

struct SessionPaths {
    let dir: URL

    static func resolve(_ explicit: String?) -> SessionPaths {
        let path = explicit ?? ProcessInfo.processInfo.environment["FTK_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".fernsprecher")
        return SessionPaths(dir: URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL)
    }

    var socket: URL { dir.appendingPathComponent("ctl.sock") }
    var transcriptJSONL: URL { dir.appendingPathComponent("transcript.jsonl") }
    var transcriptText: URL { dir.appendingPathComponent("transcript.txt") }
    var status: URL { dir.appendingPathComponent("status.json") }
    var log: URL { dir.appendingPathComponent("daemon.log") }
    var cursor: URL { dir.appendingPathComponent("listen.cursor") }
    var words: URL { dir.appendingPathComponent("words.txt") }

    func ensure() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

struct Utterance: Codable {
    let id: Int
    let time: Date
    let speaker: String   // "me", "them" (people), or the name of another agent in the call (e.g. "GPT")
    let text: String
}

/// Thread-safe transcript; appends to transcript.jsonl / transcript.txt and wakes `listen --wait` callers.
final class Transcript {
    private let lock = NSCondition()
    private(set) var items: [Utterance] = []
    private let paths: SessionPaths
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(paths: SessionPaths) {
        self.paths = paths
        for url in [paths.transcriptJSONL, paths.transcriptText] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        try? FileManager.default.removeItem(at: paths.cursor)   // a new call numbers utterances from 1 again
    }

    @discardableResult
    func append(speaker: String, text: String) -> Utterance {
        lock.lock()
        let u = Utterance(id: (items.last?.id ?? 0) + 1, time: Date(), speaker: speaker, text: text)
        items.append(u)
        if var line = try? encoder.encode(u) {
            line.append(0x0A)
            appendData(line, to: paths.transcriptJSONL)
        }
        appendData(Data("[\(clock.string(from: u.time))] \(speaker): \(text)\n".utf8), to: paths.transcriptText)
        lock.broadcast()
        lock.unlock()
        return u
    }

    func recent(_ n: Int) -> [Utterance] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.suffix(n))
    }

    var lastID: Int {
        lock.lock(); defer { lock.unlock() }
        return items.last?.id ?? 0
    }

    /// Utterances after `since`. With `waitFor`, blocks until one from that speaker arrives or the timeout passes.
    func read(since: Int, waitFor wakes: ((Utterance) -> Bool)?, timeout: TimeInterval) -> [Utterance] {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock(); defer { lock.unlock() }
        while true {
            let new = items.filter { $0.id > since }
            if wakes == nil || new.contains(where: wakes!) { return new }
            if !lock.wait(until: deadline) { return items.filter { $0.id > since } }
        }
    }

    private func appendData(_ data: Data, to url: URL) {
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    }
}

// MARK: - Control socket (one JSON request line, one JSON response line)

enum ControlSocket {
    typealias Handler = ([String: Any]) -> [String: Any]

    static func serve(at url: URL, handler: @escaping Handler) throws {
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var addr = try address(for: url)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 16) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(url.path, 0o600)
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                Thread.detachNewThread {
                    defer { close(c) }
                    guard let line = readLine(fd: c),
                          let req = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                    let resp = handler(req)
                    if var data = try? JSONSerialization.data(withJSONObject: resp) {
                        data.append(0x0A)
                        _ = data.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
                    }
                }
            }
        }
    }

    static func request(_ url: URL, _ req: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = try address(for: url)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw CLIError("no call is running (\(url.path)); start one with `fernsprecher-ki-modus-an join <link>`") }
        var data = try JSONSerialization.data(withJSONObject: req)
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard let line = readLine(fd: fd),
              let resp = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw CLIError("the call daemon closed the connection")
        }
        return resp
    }

    private static func address(for url: URL) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw CLIError("socket path too long: \(url.path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return addr
    }

    private static func readLine(fd: Int32) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return data.isEmpty ? nil : data }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buf[0..<nl])
                return data
            }
            data.append(contentsOf: buf[0..<n])
        }
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
