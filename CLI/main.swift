//
//  main.swift
//  fernsprecher-ki-modus-an
//
//  Created by Heorhii on 30.10.26.
//
//  A phone for an AI agent: join a FaceTime link, hear the people on it as text, speak text back.
//

import AppKit
import AVFoundation
import WebKit

let usage = """
fernsprecher-ki-modus-an — FaceTime calls for an AI agent (audio only, no FaceTime.app).

  join <link> [--name Claude] [--lang en-US] [--voice <name|id>] [--rate 0.5]
              [--piper <voice> [--length-scale 1.0]] [--tts-command '<cmd>']
        --piper: a Piper voice installed by the app, full name (en_US-lessac-medium) or short
        (denis, thorsten) completed with --lang. --tts-command: any synthesizer; gets the text in FTK_TEXT and
        stdin, writes a WAV to FTK_OUT.
              [--pause 0.8] [--words "Nikita,Kubernetes"] [--monitor] [--record] [--stt local|whisper|server] [--whisper-model whisper-large-v3-turbo] [--tile-lang de] [--avatar orb|human|bot] [--brand claude|gpt|'#bg1,#bg2,#orb'] [--barge-in] [--no-video] [--no-chime] [--verbose] [--foreground] [--wait 60]
        Joins the call in the background and returns once inside (or waiting to be let in).
        Once in, first say who you are: an AI agent, which model, and that everyone is heard as text.
        Instead of a camera the agent shows a tile: its name, status (listening / hearing / thinking /
        speaking) and captions. A soft chime confirms each phrase it heard.
        --words and <dir>/words.txt (one per line) list names and slang the recognizer should expect;
        a line "GPT: chat petit, gee pity" replaces those misheard words with GPT.
        --barge-in: saying words over the agent stops its speech (checked by the recognizer, so noise
        and echo don't count). Off by default; switch it during the call with `barge-in on|off`.
        --respond '<shell command>' keeps an agent on the line: after every phrase the command runs with
        FTK_TEXT (what was heard), FTK_HISTORY / stdin (last 30 transcript lines), FTK_NAME, FTK_DIR,
        and whatever it prints to stdout is spoken. Example:
          --respond 'codex exec --skip-git-repo-check "You are $FTK_NAME on a voice call. Reply in one or two short spoken sentences. Call so far: $FTK_HISTORY"'

  say <text…>            Speak into the call; returns when finished. `-` reads stdin. [--no-wait]
  listen [--wait] [--timeout 60] [--all] [--json]
        New lines of the transcript since the last listen. --wait blocks until someone speaks.
  wait [--timeout 21600]   For an agent whose turn ended: start it in the background. It returns as soon as
        someone speaks, so the agent's app wakes it up with what was said. Tile: "Listening" while an agent waits,
        "Calling <name>…" when speech wakes it, "Away" when no agent listens at all.
  ask <text…> [--timeout 60]
        say, then wait for the answer and print it.
  status [--json]        Phase of the call, remote audio tracks, input level, transcript path.
  think [text] [--seconds 30]   Show "thinking" on the tile (auto after every phrase heard).
  show <text> | show --image <file> | show --screen [--interval 1] [--display 0] | show --clear
                         Put a note, a picture or the live Mac screen on the tile.
  participants [--json]  Who is in the call and whose video is on.
  look [--who <name>] [--max-width 1600]   Save the current frame of the remote videos (cameras,
                         screen shares) as JPEG and print the paths; --who picks one person's.
                         Only look when asked or when it matters for the answer, and say so.
  stop                   Cut off what is being said right now.
  voice <piper voice> [--length-scale 1.1] | voice --system <name> | voice system
                         Switch the speaking voice during the call.
  barge-in [on|off]      Let callers interrupt the agent by talking (default off); no argument prints it.
  hangup                 Leave the call and stop the background process.
  voices [--lang de]     Installed speech voices.
  tts <text…> -o out.wav [--lang en-US] [--voice …]   Render speech to a file (no call).
  stt <audio-file> [--lang en-US] [--words a,b]        Transcribe a file on-device (no call).
  setup [--lang en-US]   Download the on-device speech model.

--agent claude|gpt|custom (or $FTK_AGENT) picks the agent's profile from the Fernsprecher app: name, language,
speech-in model, voice, tile colours and its own session folder (~/.fernsprecher, ~/.fernsprecher-gpt,
~/.fernsprecher-agent), so several agents can share a call. Without it, --name decides. Flags win over the profile.

Common: --dir <path> (default: the agent's folder, or $FTK_DIR) holds transcript.txt,
transcript.jsonl, status.json, daemon.log and the control socket.
"""

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    static let valued: Set<String> = ["name", "lang", "voice", "rate", "pause", "dir", "timeout", "o", "output", "since", "image", "seconds", "max-width", "words", "interval", "display", "respond", "tts-command", "piper", "length-scale", "avatar", "brand", "stt", "agent-turns", "whisper-model", "agent", "who", "tile-lang"]

    init(_ raw: [String]) {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("-"), a != "-" {
                var key = String(a.drop(while: { $0 == "-" }))
                var value: String?
                if let eq = key.firstIndex(of: "=") { value = String(key[key.index(after: eq)...]); key = String(key[..<eq]) }
                if Args.valued.contains(key) {
                    if value == nil, i + 1 < raw.count { i += 1; value = raw[i] }
                    flags[key] = value ?? ""
                } else if key == "wait", let v = value ?? (i + 1 < raw.count && Double(raw[i + 1]) != nil ? raw[i + 1] : nil) {
                    // `--wait` is a switch for listen and a number of seconds for join.
                    if value == nil { i += 1 }
                    flags[key] = v
                    switches.insert(key)
                } else {
                    switches.insert(key)
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    /// Index of the command word; global flags may come before it (`--agent gpt join …`).
    static func commandIndex(_ raw: [String]) -> Int? {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            guard a.hasPrefix("-"), a != "-" else { return i }
            let key = String(a.drop(while: { $0 == "-" }))
            if Args.valued.contains(key) || (key == "wait" && i + 1 < raw.count && Double(raw[i + 1]) != nil) { i += 1 }
            i += 1
        }
        return nil
    }

    func has(_ s: String) -> Bool { switches.contains(s) }
    var text: String { positional.joined(separator: " ") }
}

func out(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data("fernsprecher-ki-modus-an: \(s)\n".utf8)); exit(1) }

func printJSON(_ obj: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    out(String(decoding: data, as: UTF8.self))
}

func formatUtterances(_ list: [[String: Any]]) -> String {
    list.map { u in
        let time = (u["time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let clock = time.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? ""
        return "[\(clock)] \(u["speaker"] ?? "?"): \(u["text"] ?? "")"
    }.joined(separator: "\n")
}

/// Runs async work for commands that do not need the AppKit run loop.
func runBlocking(_ body: @escaping () async throws -> Void) -> Never {
    Task {
        do { try await body(); exit(0) } catch { fail("\(error)") }
    }
    dispatchMain()
}

func splitWords(_ s: String?) -> [String] {
    (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// --piper <voice> [--length-scale 1.1] or --tts-command '<cmd writing a WAV to $FTK_OUT>'.
func ttsOptions(_ args: Args) throws -> (String?, String?) {
    if let v = args.flags["piper"] {
        return (try Speaker.piperCommand(voice: v, language: args.flags["lang"] ?? "en-US", lengthScale: args.flags["length-scale"].flatMap(Double.init)), "Piper \(v)")
    }
    if let c = args.flags["tts-command"] { return (c, nil) }
    return (nil, nil)
}

/// Makes a spawned child its own "responsible process", so macOS privacy prompts (Speech Recognition) are
/// asked for this tool with its embedded Info.plist, not for the app the CLI was started from.
func disclaimResponsibility(_ attr: inout posix_spawnattr_t?) {
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
        _ = unsafeBitCast(sym, to: Disclaim.self)(&attr, 1)
    }
}

/// Re-runs this command as its own responsible process (once) and exits with its status.
func rerunDisclaimed() -> Never {
    var attr = posix_spawnattr_t(nil as OpaquePointer?)
    posix_spawnattr_init(&attr)
    disclaimResponsibility(&attr)
    var env = ProcessInfo.processInfo.environment
    env["FTK_DISCLAIMED"] = "1"
    let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    let argv = [executablePath()] + Array(CommandLine.arguments.dropFirst())
    let cargs = argv.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    guard posix_spawn(&pid, argv[0], nil, &attr, cargs, cenv) == 0 else { fail("cannot re-run disclaimed") }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    exit((status >> 8) & 0xff)
}

func executablePath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
}

/// Fills flags the caller left out from the agent's profile in the app's config.json.
/// The profile comes from --agent (or $FTK_AGENT), else from --name.
func applyConfigDefaults(_ args: inout Args) {
    let kind = (args.flags["agent"] ?? ProcessInfo.processInfo.environment["FTK_AGENT"]).flatMap(AgentKind.init(rawValue:))
        ?? AgentKind.guess(name: args.flags["name"])
    let c = Config.load()[kind]
    if args.flags["dir"] == nil, ProcessInfo.processInfo.environment["FTK_DIR"] == nil { args.flags["dir"] = kind.sessionDir }
    if args.flags["lang"] == nil { args.flags["lang"] = c.language }
    if args.flags["name"] == nil { args.flags["name"] = c.name }
    if args.flags["brand"] == nil { args.flags["brand"] = c.brand(kind) }
    if args.flags["tile-lang"] == nil { args.flags["tile-lang"] = Config.load().tileLanguage(kind) }
    if args.flags["stt"] == nil, c.stt != "local" { args.flags["stt"] = c.stt }
    WhisperTranscriber.model = args.flags["whisper-model"] ?? c.whisperModel
    let voiceGiven = ["voice", "piper", "tts-command"].contains { args.flags[$0] != nil }
    if !voiceGiven, !c.voice.isEmpty {
        if c.tts == "piper" {
            args.flags["piper"] = c.voice
            if args.flags["length-scale"] == nil, let l = c.lengthScale { args.flags["length-scale"] = String(l) }
        } else {
            args.flags["voice"] = c.voice
        }
    }
}

// MARK: - commands

func join(_ args: Args, paths: SessionPaths) -> Never {
    guard let linkString = args.positional.first, let link = URL(string: linkString),
          link.host?.hasSuffix("facetime.apple.com") == true else {
        fail("join needs a https://facetime.apple.com/join#… link")
    }
    if (try? ControlSocket.request(paths.socket, ["cmd": "status"])) != nil {
        fail("already in a call (see `fernsprecher-ki-modus-an status`); `fernsprecher-ki-modus-an hangup` first")
    }
    var opts = JoinOptions(link: link)
    if let v = args.flags["name"] { opts.name = v }
    if let v = args.flags["lang"] { opts.language = v }
    opts.voice = args.flags["voice"]
    if let v = args.flags["rate"] { opts.rate = Float(v) }
    if let v = args.flags["pause"], let d = Double(v) { opts.pause = d }
    opts.monitor = args.has("monitor")
    opts.verbose = args.has("verbose")
    opts.record = args.has("record")
    opts.video = !args.has("no-video")
    opts.chime = !args.has("no-chime")
    opts.words = splitWords(args.flags["words"])
    opts.bargeIn = args.has("barge-in")
    opts.respond = args.flags["respond"].flatMap { $0.isEmpty ? nil : $0 }
    do { (opts.ttsCommand, opts.ttsLabel) = try ttsOptions(args) } catch { fail("\(error)") }
    if let a = args.flags["avatar"] { opts.avatar = a }
    if let b = args.flags["brand"] { opts.brand = b }
    opts.tileLanguage = args.flags["tile-lang"]
    if let n = args.flags["agent-turns"].flatMap(Int.init) { opts.agentTurns = n }
    if let v = args.flags["stt"] { guard ["local", "server", "whisper"].contains(v) else { fail("--stt is local, whisper or server") }; opts.stt = v }
    do { try paths.ensure() } catch { fail("cannot create \(paths.dir.path): \(error)") }

    if args.has("foreground") {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let daemon = CallDaemon(opts: opts, paths: paths)
        Task {
            do { try await daemon.run() } catch { daemon.log("fatal: \(error)"); exit(1) }
        }
        app.run()
        exit(0)
    }

    // Start ourselves in a new session so the call survives the shell that launched it.
    try? FileManager.default.removeItem(at: paths.status)
    FileManager.default.createFile(atPath: paths.log.path, contents: nil)
    // The daemon runs from its own copy: rebuilding or replacing the CLI while a call is up would otherwise get the
    // running process killed (its code pages no longer match the signature on disk).
    let daemonBinary = paths.dir.appendingPathComponent(".fernsprecher-daemon")
    try? FileManager.default.removeItem(at: daemonBinary)
    do { try FileManager.default.copyItem(atPath: executablePath(), toPath: daemonBinary.path) } catch {
        fail("cannot copy the daemon binary to \(daemonBinary.path): \(error)")
    }
    var childArgs = [daemonBinary.path, "join", linkString, "--foreground", "--dir", paths.dir.path,
                     "--name", opts.name, "--lang", opts.language, "--pause", String(opts.pause)]
    if let v = opts.voice { childArgs += ["--voice", v] }
    if let v = opts.rate { childArgs += ["--rate", String(v)] }
    if opts.monitor { childArgs.append("--monitor") }
    if opts.verbose { childArgs.append("--verbose") }
    if opts.record { childArgs.append("--record") }
    if !opts.video { childArgs.append("--no-video") }
    if !opts.chime { childArgs.append("--no-chime") }
    if !opts.words.isEmpty { childArgs += ["--words", opts.words.joined(separator: ",")] }
    if opts.bargeIn { childArgs.append("--barge-in") }
    if let r = opts.respond { childArgs += ["--respond", r] }
    for key in ["tts-command", "piper", "length-scale", "avatar", "brand", "stt", "agent-turns", "whisper-model", "agent", "tile-lang"] { if let v = args.flags[key] { childArgs += ["--\(key)", v] } }

    var attr = posix_spawnattr_t(nil as OpaquePointer?)
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    if opts.stt == "server" { disclaimResponsibility(&attr) }
    var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, paths.log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    posix_spawn_file_actions_addopen(&actions, 2, paths.log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    var pid: pid_t = 0
    let cargs = childArgs.map { strdup($0) } + [nil]
    let rc = posix_spawn(&pid, childArgs[0], &actions, &attr, cargs, environ)
    guard rc == 0 else { fail("cannot start the call process: \(String(cString: strerror(rc)))") }

    let wait = Double(args.flags["wait"] ?? "") ?? 60
    let deadline = Date().addingTimeInterval(wait)
    var lastPhase = ""
    while Date() < deadline {
        usleep(300_000)
        if kill(pid, 0) != 0 {
            let tail = (try? String(contentsOf: paths.log, encoding: .utf8))?.split(separator: "\n").suffix(8).joined(separator: "\n") ?? ""
            fail("the call process exited:\n\(tail)")
        }
        guard let data = try? Data(contentsOf: paths.status),
              let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = st["phase"] as? String else { continue }
        if phase != lastPhase { FileHandle.standardError.write(Data("… \(phase)\n".utf8)); lastPhase = phase }
        switch phase {
        case "in-call":
            out("in call as \(opts.name) (pid \(pid)). transcript: \(paths.transcriptText.path)")
            out(introduceHint)
            exit(0)
        case "waiting":
            out("waiting to be let in — someone in the call has to admit \(opts.name). pid \(pid). check with `fernsprecher-ki-modus-an status`.")
            out("once you are in: " + introduceHint)
            exit(0)
        case "ended", "declined", "unsupported":
            fail("call \(phase); see \(paths.log.path)")
        default: continue
        }
    }
    out("still \(lastPhase.isEmpty ? "starting" : lastPhase) after \(Int(wait))s (pid \(pid)); see `fernsprecher-ki-modus-an status` and \(paths.log.path)")
    exit(0)
}

/// Printed by `join`, because the agent may never have read AGENTUR.md: people in the call should know
/// they are talking to an AI and that what they say is written down.
let introduceHint = "first say who you are, in one friendly sentence of your own: that you are an AI agent, which model you are, "
    + "and that you hear everyone as text that goes into a transcript on this Mac (if your provider sees that text, say so). "
    + "Tell people who join later, too."

func request(_ paths: SessionPaths, _ req: [String: Any]) -> [String: Any] {
    do {
        let r = try ControlSocket.request(paths.socket, req)
        if r["ok"] as? Bool != true { fail(r["error"] as? String ?? "failed") }
        return r
    } catch { fail("\(error)") }
}

/// Position of the last utterance already shown; clamped to the running call, whose numbering starts at 1 again.
func readCursor(_ paths: SessionPaths) -> Int {
    let saved = Int((try? String(contentsOf: paths.cursor, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    let last = (try? ControlSocket.request(paths.socket, ["cmd": "status"]))
        .flatMap { ($0["status"] as? [String: Any])?["utterances"] as? Int } ?? saved
    return min(saved, last)
}

func writeCursor(_ paths: SessionPaths, _ id: Int) {
    try? String(id).write(to: paths.cursor, atomically: true, encoding: .utf8)
}

func listen(_ args: Args, paths: SessionPaths) -> Never {
    let since = args.has("all") ? 0 : (Int(args.flags["since"] ?? "") ?? readCursor(paths))
    let timeout = Double(args.flags["timeout"] ?? "") ?? 60
    let r = request(paths, ["cmd": "listen", "since": since, "wait": args.has("wait"), "timeout": timeout])
    let list = r["utterances"] as? [[String: Any]] ?? []
    if let last = list.last?["id"] as? Int { writeCursor(paths, last) }
    if args.has("json") { printJSON(list) } else if list.isEmpty { out(args.has("wait") ? "(silence for \(Int(timeout))s)" : "(nothing new)") } else { out(formatUtterances(list)) }
    exit(0)
}

func say(_ text: String, args: Args, paths: SessionPaths) -> [String: Any] {
    let body = text == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : text
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("nothing to say") }
    return request(paths, ["cmd": "say", "text": body, "wait": !args.has("no-wait")])
}

// MARK: - dispatch

var argv = Array(CommandLine.arguments.dropFirst())
guard let commandAt = Args.commandIndex(argv) else { out(usage); exit(0) }
let command = argv.remove(at: commandAt)
var args = Args(argv)
applyConfigDefaults(&args)
let paths = SessionPaths.resolve(args.flags["dir"])

switch command {
case "join":
    join(args, paths: paths)

case "say":
    let r = say(args.text, args: args, paths: paths)
    if let w = r["warning"] as? String { FileHandle.standardError.write(Data("warning: \(w)\n".utf8)) }
    out(r["queued"] as? Bool == true ? "queued" : r["interrupted"] as? Bool == true ? "interrupted after \(r["seconds"] ?? "?")s (they started talking)" : "said (\(r["seconds"] ?? "?")s)")

case "ask":
    let mark = (request(paths, ["cmd": "status"])["status"] as? [String: Any])?["utterances"] as? Int ?? 0
    let r = say(args.text, args: Args([]), paths: paths)
    if let w = r["warning"] as? String { FileHandle.standardError.write(Data("warning: \(w)\n".utf8)) }
    // Whatever is said after our line counts as the answer; keep collecting until a short silence.
    let timeout = Double(args.flags["timeout"] ?? "") ?? 60
    var cursor = mark
    var list: [[String: Any]] = []
    var window = timeout
    while true {
        let resp = request(paths, ["cmd": "listen", "since": cursor, "wait": true, "timeout": window])
        let theirs = (resp["utterances"] as? [[String: Any]] ?? []).filter { $0["speaker"] as? String != "me" }
        cursor = resp["last"] as? Int ?? cursor
        if theirs.isEmpty { break }
        list += theirs
        window = 2.5
    }
    if let last = list.last?["id"] as? Int { writeCursor(paths, last) }
    out(list.isEmpty ? "(no answer within \(Int(timeout))s)" : formatUtterances(list))

case "listen":
    listen(args, paths: paths)

case "wait":
    // For agents whose turn ended: run in the background; it returns (and the agent's harness wakes the agent)
    // as soon as someone speaks. Meanwhile the tile says the agent can be called by just talking.
    let total = Double(args.flags["timeout"] ?? "") ?? 6 * 3600
    let deadline = Date().addingTimeInterval(total)
    // Unread phrases count too: if someone already spoke since the agent last listened, return at once.
    var cursor = args.has("all") ? 0 : (Int(args.flags["since"] ?? "") ?? readCursor(paths))
    while Date() < deadline {
        let r = request(paths, ["cmd": "listen", "since": cursor, "wait": true, "wake": true, "timeout": min(600, deadline.timeIntervalSinceNow)])
        let theirs = (r["utterances"] as? [[String: Any]] ?? []).filter { $0["speaker"] as? String != "me" }
        if !theirs.isEmpty {
            if let last = (r["utterances"] as? [[String: Any]])?.last?["id"] as? Int { writeCursor(paths, last) }
            out(args.has("json") ? "" : "someone is talking to you in the call:")
            if args.has("json") { printJSON(theirs) } else { out(formatUtterances(theirs)) }
            exit(0)
        }
        cursor = r["last"] as? Int ?? cursor
        if (try? ControlSocket.request(paths.socket, ["cmd": "status"])) == nil { fail("the call ended") }
    }
    out("(nobody spoke for \(Int(total))s)")

case "status":
    if let r = try? ControlSocket.request(paths.socket, ["cmd": "status"]), let st = r["status"] as? [String: Any] {
        if args.has("json") { printJSON(st) } else {
            out("\(st["phase"] ?? "?") as \(st["name"] ?? "?") · remote audio tracks: \(st["remoteAudioTracks"] ?? 0) · utterances: \(st["utterances"] ?? 0)\(st["speaking"] as? Bool == true ? " · speaking" : "")")
            let h = st["hearing"] as? [String: Any] ?? [:]
            out(String(format: "input level %.3f (threshold %.3f)%@ · voice %@ · %@", h["level"] as? Double ?? 0, h["threshold"] as? Double ?? 0,
                       h["inSpeech"] as? Bool == true ? " · hearing speech" : "", "\(st["voice"] ?? "")", "\(st["transcript"] ?? "")"))
            if let e = st["lastError"] { out("last error: \(e)") }
        }
    } else {
        let last = (try? Data(contentsOf: paths.status)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        out("no call running" + (last.map { " (last phase: \($0["phase"] ?? "?"))" } ?? ""))
    }

case "think":
    var req: [String: Any] = ["cmd": "think"]
    if !args.text.isEmpty { req["text"] = args.text }
    if let s = args.flags["seconds"].flatMap(Double.init) { req["seconds"] = s }
    _ = request(paths, req)

case "show":
    if args.has("clear") {
        _ = request(paths, ["cmd": "show", "clear": true])
    } else if args.has("screen") {
        var req: [String: Any] = ["cmd": "show", "screen": true]
        if let v = args.flags["interval"].flatMap(Double.init) { req["interval"] = v }
        if let v = args.flags["display"].flatMap(Int.init) { req["display"] = v }
        out("showing the \(request(paths, req)["result"] ?? "screen") (until `show --clear`)")
    } else if let image = args.flags["image"] {
        let path = URL(fileURLWithPath: (image as NSString).expandingTildeInPath).standardizedFileURL.path
        out("showing \(request(paths, ["cmd": "show", "image": path])["result"] ?? "")")
    } else {
        guard !args.text.isEmpty else { fail("show needs text, --image <file> or --clear") }
        _ = request(paths, ["cmd": "show", "text": args.text])
    }

case "look":
    let who = args.flags["who"] ?? ""
    let r = request(paths, ["cmd": "look", "maxWidth": Int(args.flags["max-width"] ?? "") ?? 1600, "who": who])
    let frames = r["frames"] as? [[String: Any]] ?? []
    if args.has("json") { printJSON(frames) } else if frames.isEmpty {
        out(who.isEmpty ? "no remote video right now (\(r["tracks"] ?? 0) video tracks)"
                        : "no video from \(who) right now; see `participants`")
    } else {
        for f in frames {
            let extra = [f["who"] as? String ?? "", f["surface"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: "\t")
            out("\(f["path"] ?? "")\t\(f["width"] ?? 0)x\(f["height"] ?? 0)\(extra.isEmpty ? "" : "\t" + extra)")
        }
    }

case "participants":
    let r = request(paths, ["cmd": "participants"])
    let list = r["participants"] as? [[String: Any]] ?? []
    if args.has("json") { printJSON(list) } else if list.isEmpty { out("(nobody else in the call)") } else {
        for p in list { out("\(p["name"] ?? "?")\t\((p["video"] as? Bool) == true ? "video on (\(p["shows"] ?? "video"))" : "no video")") }
    }

case "voice":
    guard let name = args.positional.first else { fail("voice <piper voice> | voice --system <name> | voice system") }
    var req: [String: Any] = ["cmd": "voice", "name": name]
    if args.has("system") { req["system"] = true }
    if let l = args.flags["length-scale"].flatMap(Double.init) { req["lengthScale"] = l }
    out("voice: \(request(paths, req)["voice"] ?? "")")

case "agent-turns":
    // How many replies agents may exchange without a person speaking (default 2).
    var req: [String: Any] = ["cmd": "agent-turns"]
    if let n = args.positional.first.flatMap(Int.init) { req["n"] = n }
    out("agent turns: \(request(paths, req)["n"] ?? "?")")

case "barge-in":
    var req: [String: Any] = ["cmd": "barge-in"]
    if let a = args.positional.first { req["on"] = ["on", "yes", "1", "true"].contains(a.lowercased()) }
    out("barge-in \(request(paths, req)["on"] as? Bool == true ? "on" : "off")")

case "stop":
    _ = request(paths, ["cmd": "stop"])

case "hangup":
    _ = request(paths, ["cmd": "hangup"])
    for _ in 0..<30 where FileManager.default.fileExists(atPath: paths.socket.path) { usleep(200_000) }
    out("hung up")

case "eval":
    out(request(paths, ["cmd": "eval", "js": args.text])["result"] as? String ?? "")

case "dom":
    out(request(paths, ["cmd": "eval", "js": "return window.__ftk ? window.__ftk.dump() : document.body.innerText"])["result"] as? String ?? "")

case "voices":
    let lang = args.flags["lang"]?.lowercased()
    for v in AVSpeechSynthesisVoice.speechVoices().sorted(by: { ($0.language, -$0.quality.rawValue) < ($1.language, -$1.quality.rawValue) })
    where lang == nil || v.language.lowercased().hasPrefix(lang!) {
        let q = [.premium: "premium", .enhanced: "enhanced"][v.quality] ?? "default"
        out("\(v.language)\t\(q)\t\(v.name)\t\(v.identifier)")
    }

case "tts":
    guard let o = args.flags["o"] ?? args.flags["output"] else { fail("tts needs -o out.wav") }
    runBlocking {
        let s = try Speaker(language: args.flags["lang"] ?? "en-US", voice: args.flags["voice"], rate: args.flags["rate"].flatMap(Float.init))
        let (cmd, label) = try ttsOptions(args)
        s.command = cmd
        let t0 = Date()
        try await s.render(args.text, to: URL(fileURLWithPath: o))
        out(String(format: "wrote %@ with %@ in %.2fs", o, label ?? (cmd != nil ? "external command" : "voice \(s.voice?.name ?? "default")"), Date().timeIntervalSince(t0)))
    }

case "stt":
    guard let file = args.positional.first else { fail("stt needs an audio file") }
    runBlocking {
        let lang = args.flags["lang"] ?? "en-US"
        if args.flags["stt"] == "whisper" {
            let t = try WhisperTranscriber(language: lang, words: splitWords(args.flags["words"])) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            out(try await t.transcribe(file: URL(fileURLWithPath: file)))
        } else if args.flags["stt"] == "server" {
            // Needs NSSpeechRecognitionUsageDescription embedded in the binary; not built in by default (see README).
            if ProcessInfo.processInfo.environment["FTK_DISCLAIMED"] == nil { rerunDisclaimed() }
            let t = try await ServerTranscriber(language: lang, words: splitWords(args.flags["words"]))
            out(try await t.transcribe(file: URL(fileURLWithPath: file)))
        } else {
            let t = try await Transcriber(language: lang)
            try await t.prepare { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            await t.setWords(splitWords(args.flags["words"]))
            out(try await t.transcribe(file: URL(fileURLWithPath: file)))
        }
    }

case "hear":
    // Feeds a file through the same VAD + recognizer path the call uses (faster than real time).
    guard let file = args.positional.first else { fail("hear needs an audio file") }
    runBlocking {
        let t = try await Transcriber(language: args.flags["lang"] ?? "en-US")
        try await t.prepare { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        var got = 0
        let listener = Listener(transcriber: t, pause: Double(args.flags["pause"] ?? "") ?? 0.8, record: nil,
                                onText: { out("them: \($0)"); got += 1 },
                                log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: file))
        let src = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: src)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Listener.rate, channels: 1, interleaved: true)!
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.processingFormat.sampleRate, channels: 1, interleaved: false)!
        let m = f.processingFormat.channelCount == 1 ? src : convert(src, to: mono)!
        let pcm = convert(m, to: fmt)!
        let samples = Array(UnsafeBufferPointer(start: pcm.int16ChannelData![0], count: Int(pcm.frameLength)))
        for i in stride(from: 0, to: samples.count, by: 1365) {
            listener.feed(Array(samples[i..<min(i + 1365, samples.count)]))
            try await Task.sleep(for: .milliseconds(10))
        }
        listener.feed([Int16](repeating: 0, count: 16_000 * 2))
        try await Task.sleep(for: .seconds(4))
        FileHandle.standardError.write(Data("\(got) utterances; vad \(listener.stats)\n".utf8))
    }

case "preview":
    // Renders the tile in each state to PNGs without a call: preview -o dir [--name] [--avatar] [--lang].
    let dir = URL(fileURLWithPath: ((args.flags["o"] ?? args.flags["output"] ?? ".") as NSString).expandingTildeInPath)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let cfg = WKWebViewConfiguration()
    cfg.userContentController.addUserScript(WKUserScript(
        source: BridgeJS.source(name: args.flags["name"] ?? "Claude", language: args.flags["tile-lang"] ?? args.flags["lang"] ?? "en-US",
                                avatar: args.flags["avatar"] ?? "orb", brand: args.flags["brand"] ?? "", monitor: false, video: true, verbose: false),
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let win = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    let web = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
    win.contentView!.addSubview(web)
    win.orderBack(nil)
    WebCall.keepActive(web)
    web.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://localhost/"))
    let states = ["listening", "hearing", "thinking", "speaking", "waking", "away"]
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        let js = """
        const s = await navigator.mediaDevices.getUserMedia({ video: true });
        const v = document.createElement('video'); v.muted = true; v.srcObject = s; await v.play();
        const out = {};
        for (const st of states) {
          window.__ftk.tile({ state: st, caption: st === 'speaking' ? 'Hello! This is my new look.' : (st === 'thinking' ? '“How are you?”' : '') });
          await new Promise(r => setTimeout(r, 500));
          const c = document.createElement('canvas'); c.width = v.videoWidth; c.height = v.videoHeight;
          c.getContext('2d').drawImage(v, 0, 0); out[st] = c.toDataURL('image/png').split(',')[1];
        }
        return JSON.stringify(out);
        """
        web.callAsyncJavaScript(js, arguments: ["states": states], in: nil, in: .page) { result in
            guard let json = try? result.get() as? String, let data = json.data(using: .utf8),
                  let frames = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { fail("preview failed: \(result)") }
            for st in states { if let b = frames[st], let png = Data(base64Encoded: b) { try? png.write(to: dir.appendingPathComponent("tile-\(st).png")); out(dir.appendingPathComponent("tile-\(st).png").path) } }
            exit(0)
        }
    }
    app.run()

case "setup":
    runBlocking {
        let t = try await Transcriber(language: args.flags["lang"] ?? "en-US")
        try await t.prepare { out($0) }
        out("speech model for \(t.locale.identifier) installed")
    }

case "help", "-h", "--help":
    out(usage)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
