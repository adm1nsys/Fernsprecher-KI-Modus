//
//  Shell.swift
//  Fernsprecher
//
//  Runs helper programs (the CLI, python, pip) and streams what they print.
//

import Foundation

enum Shell {
    /// Runs `exe` with `args`; every output line goes to `line` on the main actor. Returns the exit status and all output.
    nonisolated static func run(_ exe: String, _ args: [String], env: [String: String] = [:],
                                line: (@MainActor @Sendable (String) -> Void)? = nil) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let collected = Collected()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                guard !chunk.isEmpty else { return }
                for l in collected.add(chunk) { if let line { Task { @MainActor in line(l) } } }
            }
            p.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                for l in collected.add(rest) + collected.flush() { if let line { Task { @MainActor in line(l) } } }
                cont.resume(returning: (p.terminationStatus, collected.text))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }

    /// Splits streamed output into lines; carriage returns (pip/tqdm progress bars) count as line ends.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var all = Data()
        private var partial = Data()

        nonisolated func add(_ d: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            all.append(d)
            partial.append(d)
            var lines: [String] = []
            while let i = partial.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let l = String(decoding: partial[partial.startIndex..<i], as: UTF8.self)
                partial.removeSubrange(partial.startIndex...i)
                if !l.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(l) }
            }
            return lines
        }

        nonisolated func flush() -> [String] {
            lock.lock(); defer { lock.unlock() }
            let l = String(decoding: partial, as: UTF8.self)
            partial.removeAll()
            return l.isEmpty ? [] : [l]
        }

        nonisolated var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: all, as: UTF8.self)
        }
    }

    /// The CLI inside this app bundle (Contents/MacOS).
    static var bundledCLI: String? {
        Bundle.main.url(forAuxiliaryExecutable: Home.commandName)?.path
    }

    /// PATH as the user's login shell sees it (apps don't inherit it from Terminal).
    static func loginPath() async -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let r = await run(shell, ["-lic", "print -r -- \"__PATH__$PATH\" 2>/dev/null || echo \"__PATH__$PATH\""])
        let line = r.output.split(separator: "\n").last { $0.hasPrefix("__PATH__") } ?? ""
        return line.dropFirst("__PATH__".count).split(separator: ":").map(String.init)
    }
}
