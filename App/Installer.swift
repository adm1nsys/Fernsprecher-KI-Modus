//
//  Installer.swift
//  Fernsprecher
//
//  Puts the CLI on the user's PATH without stepping on anyone's toes:
//  - the binary lives in ~/Library/Application Support/Fernsprecher-KI-Modus/bin,
//  - the only thing on PATH is a symlink in ~/.local/bin (user-owned, used by pipx, uv and friends),
//  - Homebrew prefixes, /usr/local and system folders are never touched,
//  - an existing command with the same name that isn't ours is reported, never replaced.
//

import Foundation
import Observation

@Observable
final class Installer {
    enum State: Equatable {
        case unknown, notInstalled, installed, outdated
        /// Another program already answers to this name; the path says where.
        case conflict(String)
    }

    var state: State = .unknown
    /// ~/.local/bin is on the login shell's PATH.
    var onPath = true
    var error: String?

    static let linkDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
    var installed: URL { Home.bin.appendingPathComponent(Home.commandName) }
    var link: URL { Self.linkDir.appendingPathComponent(Home.commandName) }

    private static let profileMarker = "# Added by Fernsprecher (fernsprecher-ki-modus-an); the app's Uninstall removes it."
    static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""
    private var profile: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".zprofile") }

    func refresh() async {
        let fm = FileManager.default
        let path = await Shell.loginPath()
        onPath = path.contains { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path == Self.linkDir.standardizedFileURL.path }
        // Anything else on PATH with our name? Then we stay out of the way.
        for dir in path {
            let candidate = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(Home.commandName)
            guard fm.fileExists(atPath: candidate.path), !isOurs(candidate) else { continue }
            state = .conflict(candidate.path)
            return
        }
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path), target == installed.path,
           fm.fileExists(atPath: installed.path) {
            let same = Shell.bundledCLI.flatMap { fm.contentsEqual(atPath: $0, andPath: installed.path) } ?? true
            state = same ? .installed : .outdated
        } else if fm.fileExists(atPath: link.path) || isSymlink(link) {
            state = .conflict(link.path)
        } else {
            state = .notInstalled
        }
    }

    func install() async {
        error = nil
        do {
            guard let src = Shell.bundledCLI else { throw CLIError("the CLI is missing from the app bundle") }
            if case .conflict(let p) = state { throw CLIError("\(p) is not ours; leaving it alone") }
            let fm = FileManager.default
            try fm.createDirectory(at: Home.bin, withIntermediateDirectories: true)
            try fm.createDirectory(at: Self.linkDir, withIntermediateDirectories: true)
            let tmp = Home.bin.appendingPathComponent(".\(Home.commandName).new")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(atPath: src, toPath: tmp.path)
            if fm.fileExists(atPath: installed.path) {
                _ = try fm.replaceItemAt(installed, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: installed)
            }
            if !isOurs(link) { try fm.createSymbolicLink(at: link, withDestinationURL: installed) }
        } catch { self.error = "\(error)" }
        await refresh()
    }

    func uninstall() async {
        error = nil
        let fm = FileManager.default
        if isOurs(link) { try? fm.removeItem(at: link) }
        try? fm.removeItem(at: installed)
        removeProfileLine()
        await refresh()
    }

    /// Appends the PATH line to ~/.zprofile (only when the user presses the button).
    func addToProfile() async {
        let current = (try? String(contentsOf: profile, encoding: .utf8)) ?? ""
        if !current.contains(Self.profileMarker) {
            let add = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + "\n\(Self.profileMarker)\n\(Self.pathLine)\n"
            do {
                if FileManager.default.fileExists(atPath: profile.path) {
                    let h = try FileHandle(forWritingTo: profile)
                    h.seekToEndOfFile(); h.write(Data(add.utf8)); try h.close()
                } else {
                    try add.write(to: profile, atomically: true, encoding: .utf8)
                }
            } catch { self.error = "\(error)" }
        }
        await refresh()
    }

    private func removeProfileLine() {
        guard let text = try? String(contentsOf: profile, encoding: .utf8), text.contains(Self.profileMarker) else { return }
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(of: Self.profileMarker) {
            lines.remove(at: i)
            if i < lines.count, lines[i] == Self.pathLine { lines.remove(at: i) }
            if i > 0, i <= lines.count, lines[i - 1].isEmpty { lines.remove(at: i - 1) }
        }
        try? lines.joined(separator: "\n").write(to: profile, atomically: true, encoding: .utf8)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Our symlink, or our installed copy.
    private func isOurs(_ url: URL) -> Bool {
        if url.standardizedFileURL.path == installed.path { return true }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == installed.path
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
