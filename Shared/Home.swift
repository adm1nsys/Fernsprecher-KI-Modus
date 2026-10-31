//
//  Home.swift
//  Fernsprecher-KI-Modus
//
//  Where the app and the CLI keep things, and the defaults the app hands to the CLI.
//  Compiled into both targets.
//

import Foundation

enum Home {
    static let commandName = "fernsprecher-ki-modus-an"

    /// ~/Library/Application Support/Fernsprecher-KI-Modus: bin/, whisper/, piper/, config.json, conferences.json.
    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Fernsprecher-KI-Modus", isDirectory: true)

    static var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    static var whisper: URL { root.appendingPathComponent("whisper", isDirectory: true) }
    static var piper: URL { root.appendingPathComponent("piper", isDirectory: true) }
    static var config: URL { root.appendingPathComponent("config.json") }
    static var conferences: URL { root.appendingPathComponent("conferences.json") }

    /// Piper / Whisper installs from the tool's earlier name (~/.facetimekicall) still work.
    static func engineRoot(_ name: String) -> URL {
        let current = root.appendingPathComponent(name, isDirectory: true)
        let legacy = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".facetimekicall/\(name)", isDirectory: true)
        let python = "venv/bin/python"
        if !FileManager.default.fileExists(atPath: current.appendingPathComponent(python).path),
           FileManager.default.fileExists(atPath: legacy.appendingPathComponent(python).path) { return legacy }
        return current
    }
}

/// The three kinds of agent the app keeps a profile for. Each gets its own session folder,
/// so all of them can sit in the same call.
enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claude, gpt, custom
    var id: String { rawValue }

    /// ~/.fernsprecher, ~/.fernsprecher-gpt, ~/.fernsprecher-agent
    var sessionDir: String {
        let home = NSHomeDirectory() as NSString
        switch self {
        case .claude: return home.appendingPathComponent(".fernsprecher")
        case .gpt: return home.appendingPathComponent(".fernsprecher-gpt")
        case .custom: return home.appendingPathComponent(".fernsprecher-agent")
        }
    }

    /// Which profile a bare `--name` most likely means.
    static func guess(name: String?) -> AgentKind {
        let n = (name ?? "").lowercased()
        if n.isEmpty || n.contains("claude") { return .claude }
        if n.contains("gpt") || n.contains("codex") { return .gpt }
        return .custom
    }
}

/// One agent's defaults, chosen in the app. Every value can still be overridden with a CLI flag.
struct Profile: Codable, Equatable {
    var name: String
    var language = "en-US"
    /// Speech in: "local" (Apple, on-device) or "whisper" (MLX).
    var stt = "local"
    /// Folder name under whisper/models.
    var whisperModel = "whisper-large-v3-turbo"
    /// Voice out: "system" (Apple voices) or "piper".
    var tts = "system"
    /// Apple voice identifier, or Piper voice name (de_DE-thorsten-medium). Empty = best voice for the language.
    var voice = ""
    var lengthScale: Double?
    /// Tile colours as hex: background top, background bottom, orb. Used by the custom agent.
    var colors = ["#0b0b14", "#17172a", "#8b7cf6"]
    /// Language of the words on the call tile; empty = the app's language.
    var tileLanguage = ""

    init(name: String, colors: [String]? = nil) {
        self.name = name
        if let colors { self.colors = colors }
    }

    /// Missing keys keep their defaults, so older config files still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        stt = try c.decodeIfPresent(String.self, forKey: .stt) ?? stt
        whisperModel = try c.decodeIfPresent(String.self, forKey: .whisperModel) ?? whisperModel
        tts = try c.decodeIfPresent(String.self, forKey: .tts) ?? tts
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? voice
        lengthScale = try c.decodeIfPresent(Double.self, forKey: .lengthScale)
        colors = try c.decodeIfPresent([String].self, forKey: .colors) ?? colors
        tileLanguage = try c.decodeIfPresent(String.self, forKey: .tileLanguage) ?? tileLanguage
    }

    static func defaults(_ kind: AgentKind) -> Profile {
        switch kind {
        case .claude: return Profile(name: "Claude", colors: ["#2b2a27", "#1a1917", "#d97757"])
        case .gpt: return Profile(name: "GPT", colors: ["#2a2b2e", "#202123", "#10a37f"])
        case .custom: return Profile(name: "KI-Agent")
        }
    }

    /// --brand for the tile.
    func brand(_ kind: AgentKind) -> String {
        kind == .custom ? colors.joined(separator: ",") : kind.rawValue
    }
}

/// config.json: a profile per agent kind, plus the app's language (the default for tile words).
struct Config: Codable, Equatable {
    var profiles: [String: Profile] = [:]
    var appLanguage = "en"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decodeIfPresent([String: Profile].self, forKey: .profiles) ?? [:]
        appLanguage = try c.decodeIfPresent(String.self, forKey: .appLanguage) ?? appLanguage
    }

    /// The language the tile's words are in.
    func tileLanguage(_ kind: AgentKind) -> String {
        let own = self[kind].tileLanguage
        return own.isEmpty ? appLanguage : own
    }

    subscript(kind: AgentKind) -> Profile {
        get { profiles[kind.rawValue] ?? Profile.defaults(kind) }
        set { profiles[kind.rawValue] = newValue }
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: Home.config) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Home.root, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Home.config, options: .atomic)
    }
}

/// A call the agent may be sent to, kept in the app's conference book.
struct Conference: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var link: String
    var details = ""
    /// Call language, e.g. de-DE; empty = the default from Config.
    var language = ""

    static func loadAll() -> [Conference] {
        guard let data = try? Data(contentsOf: Home.conferences) else { return [] }
        return (try? JSONDecoder().decode([Conference].self, from: data)) ?? []
    }

    static func saveAll(_ list: [Conference]) throws {
        try FileManager.default.createDirectory(at: Home.root, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(list).write(to: Home.conferences, options: .atomic)
    }
}
