//
//  CallDaemon.swift
//  fernsprecher-ki-modus-an
//
//  The long-running process behind `join`: holds the web call, hears, speaks and answers the control socket.
//

import AppKit
import AVFoundation

struct JoinOptions {
    var link: URL
    var name = "Claude"
    var language = "en-US"
    /// Language of the words on the tile (labels); nil = the call language.
    var tileLanguage: String?
    var voice: String?
    var rate: Float?
    var pause = 0.8
    var monitor = false
    var record = false
    var video = true
    var chime = true
    var words: [String] = []
    var bargeIn = false
    var agentTurns = 2
    var avatar = "orb"
    var stt = "local"
    var brand = ""
    var ttsCommand: String?
    var ttsLabel: String?
    var respond: String?
    var verbose = false
}

final class CallDaemon {
    private let opts: JoinOptions
    private let paths: SessionPaths
    private let transcript: Transcript
    private let started = Date()

    private var call: WebCall!
    private var listener: Listener!
    private var speaker: Speaker!
    private var stt: (any SpeechToText)!
    private var speakingText = ""

    private let stateLock = NSLock()
    private var phase = "starting"
    private var tracks = 0
    private var lastError: String?
    private var speaking = false

    private let sayQueue = DispatchQueue(label: "ftk.say")
    private var playID = 0
    private var playWaiters: [Int: DispatchSemaphore] = [:]

    init(opts: JoinOptions, paths: SessionPaths) {
        self.opts = opts
        self.paths = paths
        self.transcript = Transcript(paths: paths)
    }

    func log(_ s: String) {
        let f = ISO8601DateFormatter()
        FileHandle.standardError.write(Data("\(f.string(from: Date())) \(s)\n".utf8))
    }

    func run() async throws {
        speaker = try Speaker(language: opts.language, voice: opts.voice, rate: opts.rate)
        speaker.command = opts.ttsCommand
        speaker.commandLabel = opts.ttsLabel
        log("voice: \(opts.ttsLabel ?? opts.ttsCommand.map { "command: \($0)" } ?? "\(speaker.voice?.name ?? "default") (\(speaker.voice?.identifier ?? "-"))")")
        let local = try await Transcriber(language: opts.language)
        await local.setWords(vocabulary())
        let words = await local.words
        log("vocabulary: \(words.joined(separator: ", "))")
        if opts.stt == "whisper" {
            stt = try WhisperTranscriber(language: opts.language, words: words, log: log)
            log("speech recognition: Whisper large-v3-turbo (MLX), on-device")
        } else if opts.stt == "server" {
            stt = try await ServerTranscriber(language: opts.language, words: words)
            log("speech recognition: \(opts.language), Apple server")
        } else {
            try await local.prepare(log: log)
            stt = local
            log("speech recognition: \(local.locale.identifier), on-device")
        }
        listener = Listener(transcriber: stt, pause: opts.pause,
                            record: opts.record ? paths.dir.appendingPathComponent("incoming-16k-s16le.raw") : nil, onText: { [weak self] text in
            guard let self else { return }
            // Our own voice coming back from someone's speaker: drop it.
            let current = self.stateLock.withLock { self.speaking ? self.speakingText : "" }
            let recent = self.transcript.recent(3).last(where: { $0.speaker == "me" && Date().timeIntervalSince($0.time) < 10 })?.text ?? ""
            if Self.isEcho(text, of: current + " " + recent), !(current + recent).isEmpty {
                self.log("echo of our own line dropped: \(text)")
                return
            }
            // Who said it: another agent in this call (its own transcript has the same words), or a person.
            let speaker = self.identifySpeaker(text)
            // Who is on the line is decided before the transcript wakes the waiting `listen`s.
            let who = self.lineState()
            // People's phrases go to the agent they name, or else to whoever spoke last (see route()).
            let forMe = speaker == "them" ? self.route(text) : self.addressesMe(text)
            let id = self.stateLock.withLock { () -> Int in
                let id = self.transcript.lastID + 1
                if forMe && speaker == "them" { self.mineIDs.insert(id) }
                return id
            }
            self.transcript.append(speaker: speaker, text: text)
            self.log("\(speaker)#\(id)\(forMe ? "" : " (not for me)"): \(text)")
            if forMe {
                self.gotUtterance(text, line: who, from: speaker)
            } else if speaker != "them", self.opts.respond != nil {
                // Another agent's line not naming us: the responder may still answer (it can say SKIP), but agents
                // get at most two replies in a row without a person speaking, so they can't loop forever.
                self.queueResponse(text, from: speaker)
            }
        }, log: log)
        listener.onActivity = { [weak self] talking in self?.heard(talking: talking) }

        try ControlSocket.serve(at: paths.socket) { [weak self] req in
            self?.handle(req) ?? ["ok": false]
        }

        await MainActor.run {
            call = WebCall(url: opts.link, name: opts.name, language: opts.tileLanguage ?? opts.language, avatar: opts.avatar, brand: opts.brand, monitor: opts.monitor, video: opts.video, verbose: opts.verbose)
            call.onAudio = { [weak self] samples in self?.listener.feed(samples) }
            call.onEvent = { [weak self] ev in self?.event(ev) }
            call.start()
        }
        setPhase("loading")
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.hangup(reason: "signal") }
            src.resume()
            signalSources.append(src)
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.writeStatus() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshIdleTile() }
    }
    private var signalSources: [DispatchSourceSignal] = []

    /// --words, plus words.txt in the session folder (one per line), plus the agent's own name.
    private func vocabulary() -> [String] {
        let file = (try? String(contentsOf: paths.words, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") } ?? []
        return [opts.name, "Claude"] + opts.words + file
    }

    // MARK: events from the page

    private func event(_ ev: [String: Any]) {
        let type = ev["type"] as? String ?? ""
        switch type {
        case "phase":
            let p = ev["phase"] as? String ?? "?"
            setPhase(p)
            log("phase: \(p) — \((ev["text"] as? String ?? "").prefix(160))")
            if ["ended", "declined", "unsupported"].contains(p) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.exit(p == "ended" ? 0 : 2) }
            }
        case "track", "track-ended":
            stateLock.withLock { tracks = ev["count"] as? Int ?? tracks }
            log("\(type): \(ev["id"] ?? "") (remote audio tracks: \(tracks))")
            writeStatus()
        case "played":
            if let id = ev["id"] as? Int {
                stateLock.withLock { playWaiters[id] }?.signal()
            }
        case "error":
            stateLock.withLock { lastError = ev["text"] as? String }
            log("error: \(ev["text"] ?? "")")
            writeStatus()
        default:
            log("\(type): \(ev["text"] ?? ev)")
        }
    }

    private func setPhase(_ p: String) {
        stateLock.withLock { phase = p }
        writeStatus()
    }

    private func statusDict() -> [String: Any] {
        stateLock.withLock {
            var d: [String: Any] = [
                "pid": Int(getpid()), "phase": phase, "remoteAudioTracks": tracks, "speaking": speaking,
                "name": opts.name, "bargeIn": bargeIn, "agentWaiting": waiters, "agentWakeable": wakeWaiters, "language": opts.language, "voice": speaker?.commandLabel ?? (speaker?.command != nil ? "external" : speaker?.voice?.name ?? "default"),
                "since": ISO8601DateFormatter().string(from: started), "utterances": transcript.lastID,
                "hearing": listener?.stats ?? [:],
                "transcript": paths.transcriptText.path,
            ]
            if let lastError { d["lastError"] = lastError }
            return d
        }
    }

    private func writeStatus() {
        if let data = try? JSONSerialization.data(withJSONObject: statusDict(), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: paths.status, options: .atomic)
        }
    }

    // MARK: the tile (our "camera")

    private let screen = ScreenFeed()
    private var tileState = "connecting"
    private var tileGeneration = 0

    /// Shows `state` on the tile; unless something else happens first, it falls back to "listening" after `revert` seconds.
    private func setTile(_ state: String, caption: String? = nil, revert: Double? = nil) {
        let gen = stateLock.withLock { () -> Int in tileState = state; tileGeneration += 1; return tileGeneration }
        var p: [String: Any] = ["state": state]
        if let caption { p["caption"] = caption }
        DispatchQueue.main.async {
            self.call?.evaluate("return window.__ftk ? window.__ftk.tile(p) : null", arguments: ["p": p]) { _ in }
        }
        if let revert {
            DispatchQueue.main.asyncAfter(deadline: .now() + revert) {
                if self.stateLock.withLock({ self.tileGeneration == gen }) { self.setTile(self.idle) }
            }
        }
    }

    private lazy var bargeIn = opts.bargeIn
    private var talkGeneration = 0
    private var interrupted = false

    private func heard(talking: Bool) {
        let (busy, current, gen) = stateLock.withLock { () -> (Bool, String, Int) in
            talkGeneration += 1
            return (speaking, tileState, talkGeneration)
        }
        if busy {
            // Barge-in: after 0.7 s of sound over our speech, check it really is words (not our own echo or
            // line noise coming back from the other side) before stopping.
            guard talking, stateLock.withLock({ bargeIn }) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard self.stateLock.withLock({ self.talkGeneration == gen && self.speaking }),
                      let buf = self.listener.currentSegment() else { return }
                Task {
                    let text = (try? await self.stt.transcribe(buf)) ?? ""
                    let mine = self.stateLock.withLock { self.speakingText }
                    guard !text.isEmpty, !Self.isEcho(text, of: mine) else {
                        self.log("ignored sound over our speech: \(text.isEmpty ? "(no words)" : "echo «\(text)»")")
                        return
                    }
                    guard self.stateLock.withLock({ self.speaking }) else { return }
                    self.stateLock.withLock { self.interrupted = true }
                    self.log("interrupted by «\(text)» — stopping speech")
                    DispatchQueue.main.async { self.call?.evaluate("window.__ftk && window.__ftk.stop()") { _ in } }
                }
            }
            return
        }
        // Nobody is listening: don't pretend to hear; keep "Away" so the caller knows to call the agent in its chat.
        if lineState() == .away {
            if talking { setTile("away", caption: awayHint) }
            return
        }
        if talking { setTile("hearing") } else if current == "hearing" { setTile("hearing", revert: 2) }
    }

    /// True when most words heard also occur in what we are saying (our voice leaking back).
    static func isEcho(_ heard: String, of mine: String) -> Bool {
        let tokens = { (s: String) in s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let h = tokens(heard), m = Set(tokens(mine))
        guard !h.isEmpty else { return true }
        return Double(h.filter(m.contains).count) / Double(h.count) >= 0.6
    }

    // MARK: --respond: the agent is always on the line

    private let respondQueue = DispatchQueue(label: "ftk.respond")
    private var pendingHeard: [String] = []
    private var responderBusy = false

    private var agentRepliesInARow = 0
    private lazy var agentTurns = opts.agentTurns

    private func queueResponse(_ text: String, from speaker: String = "them") {
        guard opts.respond != nil else { return }
        let allowed = stateLock.withLock { () -> Bool in
            if speaker == "them" { agentRepliesInARow = 0; return true }
            agentRepliesInARow += 1
            return agentRepliesInARow <= agentTurns
        }
        guard allowed else { log("not answering \(speaker) again without a person in between"); return }
        let text = speaker == "them" ? text : "(\(speaker)): \(text)"
        let start = stateLock.withLock { () -> Bool in
            pendingHeard.append(text)
            if responderBusy { return false }
            responderBusy = true
            return true
        }
        if start { respondQueue.async { self.respondLoop() } }
    }

    private func respondLoop() {
        while true {
            // A short grace period lets a phrase that was cut by a pause join the next one.
            Thread.sleep(forTimeInterval: 0.3)
            let batch = stateLock.withLock { () -> [String] in
                let b = pendingHeard
                pendingHeard = []
                if b.isEmpty { responderBusy = false }
                return b
            }
            if batch.isEmpty { return }
            let heardText = batch.joined(separator: " ")
            setTile("thinking", caption: "«\(heardText)»", revert: 120)
            let reply = runResponder(heard: heardText)
            if let reply, !reply.isEmpty {
                _ = sayQueue.sync { speakNow(reply) }
            } else {
                setTile(idle)
            }
        }
    }

    private func runResponder(heard: String) -> String? {
        guard let command = opts.respond else { return nil }
        let history = transcript.recent(30).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = paths.dir
        var env = ProcessInfo.processInfo.environment
        env["FTK_TEXT"] = heard
        env["FTK_HISTORY"] = history
        env["FTK_NAME"] = opts.name
        env["FTK_DIR"] = paths.dir.path
        env["FTK_TRANSCRIPT"] = paths.transcriptText.path
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        let t0 = Date()
        do { try p.run() } catch { log("responder failed to start: \(error)"); return nil }
        stdin.fileHandleForWriting.write(Data(history.utf8))
        try? stdin.fileHandleForWriting.close()
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 180)
        timer.setEventHandler { if p.isRunning { self.log("responder timed out"); p.terminate() } }
        timer.resume()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        let reply = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        log(String(format: "responder exit %d in %.1fs: %@", p.terminationStatus, Date().timeIntervalSince(t0), String(reply.prefix(200))))
        if p.terminationStatus != 0 { log("responder stderr: \(String(decoding: err, as: UTF8.self).suffix(500))") }
        return p.terminationStatus == 0 ? reply : nil
    }

    static func bargeInReply(on: Bool, language: String) -> String {
        switch language.prefix(2) {
        case "de": on ? "Unterbrechen ist jetzt erlaubt." : "Unterbrechen ist jetzt nicht erlaubt."
        case "fr": on ? "Vous pouvez maintenant m’interrompre." : "Vous ne pouvez plus m’interrompre."
        case "da": on ? "Nu må I gerne afbryde mig." : "Nu må I ikke afbryde mig."
        case "ja": on ? "割り込みをオンにしました。" : "割り込みをオフにしました。"
        default: on ? "Barge-in is on." : "Barge-in is off."
        }
    }

    /// "Turn barge-in on / off" (or the same in German, French, Danish or Japanese) switches barge-in by voice.
    private func voiceCommand(_ text: String) -> Bool {
        let t = text.lowercased()
        guard ["barge", "interrupt", "unterbrech", "interromp", "afbryd", "割り込"].contains(where: t.contains) else { return false }
        let off = ["turn off", "disable", "stop interrupt", " aus", "désactiv", "slå fra", "オフ"].contains { t.contains($0) }
        let on = !off && ["turn on", "enable", " an", " ein", "activ", "slå til", "オン"].contains { t.contains($0) }
        guard on || off else { return false }
        stateLock.withLock { bargeIn = on }
        log("voice command: barge-in \(on ? "on" : "off")")
        sayQueue.async { _ = self.speakNow(Self.bargeInReply(on: on, language: self.opts.language)) }
        return true
    }

    // MARK: who is talking

    /// People's phrases routed to this agent, and other agents' phrases that name it.
    private var mineIDs = Set<Int>()
    func wakes(_ u: Utterance) -> Bool {
        if u.speaker == "them" { return stateLock.withLock { mineIDs.contains(u.id) } }
        return u.speaker != "me" && addressesMe(u.text)
    }

    /// How an agent's name tends to come out of the recognizer.
    static func aliases(of name: String) -> [String] {
        let n = name.lowercased()
        var list = [n]
        if n.contains("claude") { list += ["claude", "clawed", "cloud"] }
        if n.contains("gpt") { list += ["gpt", "chatgpt"] }
        return list
    }

    func addressesMe(_ text: String) -> Bool { Self.names(in: text, among: [opts.name]).contains(opts.name) }

    static func names(in text: String, among agents: [String]) -> [String] {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return agents.filter { a in
            let n = a.lowercased()
            return aliases(of: a).contains { alias in words.contains { $0 == alias || ($0.hasPrefix(alias) && $0.count <= alias.count + 2) } }
        }
    }

    /// The floor: one file shared by all agents on this Mac says who spoke last.
    private static let floorFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".fernsprecher-floor")

    private func takeFloor() {
        try? opts.name.write(to: Self.floorFile, atomically: true, encoding: .utf8)
    }

    /// Simple rule for a person's phrase: if it names agents, only they answer; otherwise whoever spoke last does.
    private func route(_ text: String) -> Bool {
        let agents = [opts.name] + otherAgents().map(\.name)
        guard agents.count > 1 else { return true }
        let named = Self.names(in: text, among: agents)
        if !named.isEmpty { return named.contains(opts.name) }
        let holder = (try? String(contentsOf: Self.floorFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let holder, agents.contains(holder) else { return opts.name == agents.sorted().first }
        return holder == opts.name
    }

    /// Other fernsprecher-ki-modus-an sessions on this Mac (~/.fernsprecher*) that are in a call: their name and recent own lines.
    private func otherAgents() -> [(name: String, lines: [Utterance], speaking: Bool)] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let dirs = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil, options: [])) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return dirs.filter { $0.lastPathComponent.hasPrefix(".fernsprecher") && $0.standardizedFileURL != paths.dir.standardizedFileURL }
            .compactMap { dir in
                let p = SessionPaths(dir: dir)
                guard let data = try? Data(contentsOf: p.status),
                      let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      st["phase"] as? String == "in-call", let name = st["name"] as? String,
                      let raw = try? String(contentsOf: p.transcriptJSONL, encoding: .utf8) else { return nil }
                let lines = raw.split(separator: "\n").suffix(40).compactMap { try? decoder.decode(Utterance.self, from: Data($0.utf8)) }
                    .filter { $0.speaker == "me" }
                return (name, lines, st["speaking"] as? Bool ?? false)
            }
    }

    private func identifySpeaker(_ text: String) -> String {
        for attempt in 0..<4 {
            let agents = otherAgents()
            let now = Date()
            for a in agents {
                for line in a.lines where now.timeIntervalSince(line.time) < 40 && Self.isEcho(text, of: line.text) {
                    return a.name
                }
            }
            // The other agent may still be finishing the line it is saying; give its transcript a moment.
            let busy = agents.contains { $0.speaking || ($0.lines.last.map { now.timeIntervalSince($0.time) < 8 } ?? false) }
            if !busy || attempt == 3 { break }
            Thread.sleep(forTimeInterval: 0.7)
        }
        return "them"
    }

    // MARK: is an agent on the line?

    private var waiters = 0, wakeWaiters = 0
    private var lastDetach = Date()

    enum Line { case listening, wakeable, away }

    /// listening: an agent is inside `listen --wait`/`ask` (or --respond answers); wakeable: only a background
    /// `wait` is left, so speech will wake it; away: nobody will hear it until the agent is called in its chat.
    private func lineState() -> Line {
        stateLock.withLock {
            if waiters > wakeWaiters || opts.respond != nil { return .listening }
            if wakeWaiters > 0 { return .wakeable }
            return Date().timeIntervalSince(lastDetach) < 8 ? .listening : .away
        }
    }

    private var idle: String {
        lineState() == .away ? "away" : "listening"
    }

    private func refreshIdleTile() {
        let (state, busy) = stateLock.withLock { (tileState, speaking) }
        guard !busy, state == "listening" || state == "away" else { return }
        let want = idle
        if want != state { setTile(want, caption: want == "away" ? awayHint : nil) }
    }

    private var awayHint: String {
        let n = opts.name
        switch opts.language.prefix(2) {
        case "de": return "\(n) macht gerade Pause und hört nicht mit – bitte im Chat ansprechen"
        case "fr": return "\(n) a fini de parler et n’écoute plus – relancez-le dans son chat"
        case "da": return "\(n) holder pause og lytter ikke med – skriv til den i chatten"
        case "ja": return "\(n)は今休憩中で、聞いていません。チャットで呼んでください"
        default: return "\(n) finished its turn and isn't listening — call it in its chat"
        }
    }

    private func gotUtterance(_ text: String, line: Line, from speaker: String = "them") {
        if voiceCommand(text) { return }
        if opts.chime {
            DispatchQueue.main.async { self.call?.evaluate("window.__ftk && window.__ftk.chime()") { _ in } }
        }
        // Someone finished a phrase: show it and what the agent does about it.
        if !stateLock.withLock({ speaking }) {
            switch line {
            case .listening: setTile("thinking", caption: "«\(text)»", revert: 25)
            case .wakeable: setTile("waking", caption: "«\(text)»", revert: 90)
            case .away: setTile("away", caption: "«\(text)» — \(awayHint)")
            }
        }
        queueResponse(text, from: speaker)
    }

    // MARK: control requests (called on socket threads)

    private func handle(_ req: [String: Any]) -> [String: Any] {
        switch req["cmd"] as? String {
        case "status":
            return ["ok": true, "status": statusDict()]
        case "say":
            let text = (req["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return ["ok": false, "error": "nothing to say"] }
            let inCall = stateLock.withLock { phase == "in-call" }
            if req["wait"] as? Bool ?? true {
                let r = sayQueue.sync { speakNow(text) }
                return r.merging(inCall ? [:] : ["warning": "not in the call yet (phase \(statusDict()["phase"]!))"]) { a, _ in a }
            }
            sayQueue.async { _ = self.speakNow(text) }
            return ["ok": true, "queued": true]
        case "stop":
            DispatchQueue.main.async { self.call.evaluate("window.__ftk && window.__ftk.stop()") { _ in } }
            return ["ok": true]
        case "listen":
            let since = req["since"] as? Int ?? 0
            let wait = req["wait"] as? Bool ?? false
            let wake = req["wake"] as? Bool ?? false
            let timeout = req["timeout"] as? Double ?? 60
            if wait {
                stateLock.withLock { waiters += 1; if wake { wakeWaiters += 1 } }
                DispatchQueue.main.async { self.refreshIdleTile() }
            }
            let items = transcript.read(since: since, waitFor: wait ? { [unowned self] in self.wakes($0) } : nil, timeout: wait ? timeout : 0)
            if wait {
                stateLock.withLock { waiters -= 1; if wake { wakeWaiters -= 1 }; lastDetach = Date() }
            }
            return ["ok": true, "last": transcript.lastID, "utterances": items.map(encode)]
        case "hangup":
            DispatchQueue.main.async { self.hangup(reason: "requested") }
            return ["ok": true]
        case "agent-turns":
            if let n = req["n"] as? Int { stateLock.withLock { agentTurns = n; agentRepliesInARow = 0 } }
            return ["ok": true, "n": stateLock.withLock { agentTurns }]
        case "barge-in":
            if let on = req["on"] as? Bool { stateLock.withLock { bargeIn = on } }
            return ["ok": true, "on": stateLock.withLock { bargeIn }]
        case "voice":
            // Switch the voice mid-call: a Piper voice, a system voice, or "system" for the default.
            let name = req["name"] as? String ?? ""
            do {
                if name.isEmpty || name == "system" {
                    speaker.command = nil; speaker.commandLabel = nil
                } else if req["system"] as? Bool == true {
                    speaker = try Speaker(language: opts.language, voice: name, rate: opts.rate)
                } else {
                    speaker.command = try Speaker.piperCommand(voice: name, language: opts.language, lengthScale: req["lengthScale"] as? Double)
                    speaker.commandLabel = "Piper \(name)"
                }
            } catch { return ["ok": false, "error": "\(error)"] }
            let label = speaker.commandLabel ?? speaker.voice?.name ?? "default"
            log("voice: \(label)")
            return ["ok": true, "voice": label]
        case "think":
            setTile("thinking", caption: req["text"] as? String, revert: req["seconds"] as? Double ?? 30)
            return ["ok": true]
        case "show":
            screen.stop()
            if req["screen"] as? Bool == true {
                let started = DispatchSemaphore(value: 0)
                var first: [String: Any] = ["ok": false, "error": "no frame within 10 s"]
                var signalled = false
                screen.start(display: req["display"] as? Int ?? 0, interval: req["interval"] as? Double ?? 1, maxWidth: 1280, frame: { url in
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        DispatchQueue.main.async {
                            self.call.evaluate("return await window.__ftk.showImage(u)", arguments: ["u": url]) { r in
                                if !signalled { signalled = true; first = ["ok": true, "result": "screen \(String(describing: r ?? ""))"]; started.signal() }
                                done.resume()
                            }
                        }
                    }
                }, failed: { msg in
                    self.log(msg)
                    if !signalled { signalled = true; first = ["ok": false, "error": msg]; started.signal() }
                })
                _ = started.wait(timeout: .now() + 10)
                return first
            }
            if req["clear"] as? Bool == true {
                return onMain { done in
                    self.call.evaluate("window.__ftk.tile({ note: '' }); return await window.__ftk.showImage(null)") { done(["ok": true, "result": String(describing: $0 ?? "")]) }
                }
            }
            if let path = req["image"] as? String {
                guard let data = FileManager.default.contents(atPath: path) else { return ["ok": false, "error": "cannot read \(path)"] }
                let ext = (path as NSString).pathExtension.lowercased()
                let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic"][ext] ?? "image/png"
                let url = "data:\(mime);base64,\(data.base64EncodedString())"
                return onMain { done in
                    self.call.evaluate("return await window.__ftk.showImage(u)", arguments: ["u": url]) { r in
                        let text = String(describing: r ?? "")
                        done(text.hasPrefix("error") ? ["ok": false, "error": text] : ["ok": true, "result": text])
                    }
                }
            }
            let note = req["text"] as? String ?? ""
            return onMain { done in self.call.evaluate("window.__ftk.tile({ note: n }); return 1", arguments: ["n": note]) { _ in done(["ok": true]) } }
        case "look":
            let dir = paths.dir.appendingPathComponent("look", isDirectory: true)
            let maxWidth = req["maxWidth"] as? Int ?? 1600
            return onMain { done in
                self.call.evaluate("return await window.__ftk.look(w, who)", arguments: ["w": maxWidth, "who": req["who"] as? String ?? ""]) { r in
                    guard let json = r as? String, let data = json.data(using: .utf8),
                          let frames = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        done(["ok": false, "error": "look failed: \(String(describing: r))"]); return
                    }
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let stamp = Int(Date().timeIntervalSince1970)
                    var out: [[String: Any]] = []
                    for (i, f) in frames.enumerated() {
                        guard let b64 = f["jpeg"] as? String, let jpg = Data(base64Encoded: b64) else { continue }
                        let file = dir.appendingPathComponent("frame-\(stamp)-\(i + 1).jpg")
                        try? jpg.write(to: file)
                        out.append(["path": file.path, "width": f["width"] ?? 0, "height": f["height"] ?? 0, "surface": f["surface"] ?? "", "who": f["who"] ?? ""])
                    }
                    done(["ok": true, "frames": out, "tracks": frames.count])
                }
            }
        case "participants":
            return onMain { done in
                self.call.evaluate("return window.__ftk.participants()") { r in
                    let list = (r as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [[String: Any]]
                    done(["ok": list != nil, "participants": list ?? [], "error": list == nil ? "cannot read the participant list" : ""])
                }
            }
        case "eval":
            return onMain { done in self.call.evaluate(req["js"] as? String ?? "return 1") { done(["ok": true, "result": String(describing: $0 ?? "nil")]) } }
        default:
            return ["ok": false, "error": "unknown command"]
        }
    }

    private func encode(_ u: Utterance) -> [String: Any] {
        ["id": u.id, "time": ISO8601DateFormatter().string(from: u.time), "speaker": u.speaker, "text": u.text]
    }

    private func onMain(timeout: Double = 20, _ body: @escaping (@escaping ([String: Any]) -> Void) -> Void) -> [String: Any] {
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any] = ["ok": false, "error": "timeout"]
        DispatchQueue.main.async { body { out = $0; sem.signal() } }
        _ = sem.wait(timeout: .now() + timeout)
        return out
    }

    /// Synthesizes `text`, plays it into the call and blocks until it has been heard.
    private func speakNow(_ text: String) -> [String: Any] {
        do {
            let render = DispatchSemaphore(value: 0)
            var pcm = Data()
            var failure: Error?
            Task { do { pcm = try await speaker.render(text) } catch { failure = error }; render.signal() }
            render.wait()
            if let failure { return ["ok": false, "error": "speech synthesis failed: \(failure)"] }

            let id = stateLock.withLock { () -> Int in playID += 1; speaking = true; interrupted = false; speakingText = text; return playID }
            setTile("speaking", caption: text)
            takeFloor()
            let played = DispatchSemaphore(value: 0)
            stateLock.withLock { playWaiters[id] = played }
            var duration: Double?
            let started = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                self.call.play(pcm: pcm, sampleRate: Speaker.rate, id: id) { duration = $0; started.signal() }
            }
            started.wait()
            defer {
                stateLock.withLock { playWaiters[id] = nil; speaking = false }
                setTile(idle, caption: "")
            }
            guard let duration else { return ["ok": false, "error": "the call page is not ready"] }
            let t0 = Date()
            _ = played.wait(timeout: .now() + duration + 5)
            let cut = stateLock.withLock { interrupted }
            let spoken = min(duration, Date().timeIntervalSince(t0))
            transcript.append(speaker: "me", text: cut ? text + " [interrupted after \(Int(spoken)) s]" : text)
            log("me: \(text)\(cut ? " (interrupted)" : "")")
            var r: [String: Any] = ["ok": true, "seconds": (spoken * 10).rounded() / 10]
            if cut { r["interrupted"] = true }
            return r
        }
    }

    private func hangup(reason: String) {
        log("hanging up (\(reason))")
        call.evaluate("return window.__ftk ? window.__ftk.hangup() : null") { r in
            self.log("leave button: \(r ?? "none")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.exit(0) }
        }
    }

    private func exit(_ code: Int32) {
        setPhase(phase == "ended" || phase == "declined" || phase == "unsupported" ? phase : "ended")
        unlink(paths.socket.path)
        Darwin.exit(code)
    }
}
