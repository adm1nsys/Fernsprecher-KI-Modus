//
//  Voice.swift
//  fernsprecher-ki-modus-an
//
//  Hearing (energy VAD + on-device DictationTranscriber) and speaking (AVSpeechSynthesizer).
//

import AVFoundation
import Speech

// MARK: - Speech to text

protocol SpeechToText: Sendable {
    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String
}

extension Transcriber: SpeechToText {}

/// Apple's server recognition (what dictation on the Watch/iPhone uses): better with names
/// than the on-device model, and it honours contextual strings. Audio goes to Apple; needs Speech Recognition
/// permission once.
final class ServerTranscriber: SpeechToText, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let words: [String]

    init(language: String, words: [String]) async throws {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            throw CLIError("server speech recognition does not support \(language)")
        }
        recognizer = r
        self.words = words
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else {
            throw CLIError("Speech Recognition permission is \(status.rawValue == 1 ? "denied" : status.rawValue == 2 ? "restricted" : "not granted") — allow it in System Settings → Privacy & Security → Speech Recognition")
        }
        guard r.isAvailable else { throw CLIError("server speech recognition is not available right now (network?)") }
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = false
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = Array(words.filter { !$0.contains(":") }.prefix(100))
        req.append(buffer)
        req.endAudio()
        let text: String = try await withCheckedThrowingContinuation { cont in
            var done = false
            _ = recognizer.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true; cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    done = true
                    // "No speech detected" is an empty phrase, not a failure.
                    if (error as NSError).code == 1110 { cont.resume(returning: "") } else { cont.resume(throwing: error) }
                }
            }
        }
        return Vocabulary.correct(text, words: words)
    }

    func transcribe(file url: URL) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CLIError("cannot read \(url.path)")
        }
        try file.read(into: buf)
        return try await transcribe(buf)
    }
}

/// Whisper through MLX (<Home>/whisper: venv + worker.py + models/<name>). Better than Apple's models with
/// names and mixed languages; the names go into Whisper's prompt. One worker process keeps the
/// model loaded; phrases are sent to it one at a time as 16 kHz WAV files.
actor WhisperTranscriber: SpeechToText {
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private var buffered = Data()
    private let language: String
    private let prompt: String
    private let words: [String]

    init(language: String, words: [String], log: (String) -> Void) throws {
        let root = Home.engineRoot("whisper").path
        let python = root + "/venv/bin/python", worker = root + "/worker.py"
        guard FileManager.default.fileExists(atPath: python), FileManager.default.fileExists(atPath: worker) else {
            throw CLIError("Whisper is not installed in \(root) (see README)")
        }
        self.language = String(language.prefix(2))
        self.words = words
        let names = words.filter { !$0.contains(":") }
        prompt = names.isEmpty ? "" : (Self.promptIntro[self.language] ?? Self.promptIntro["en"]!) + names.joined(separator: ", ") + "."
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", worker]
        let model = root + "/models/" + Self.model
        if FileManager.default.fileExists(atPath: model) {
            process.environment = ProcessInfo.processInfo.environment.merging(["FTK_WHISPER_MODEL": model]) { $1 }
        }
        let inPipe = Pipe(), outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        log("whisper: loading the model…")
        guard let ready = Self.readLine(output, &buffered), ready.contains("ready") else { throw CLIError("the Whisper worker did not start") }
    }

    /// Model folder under whisper/models (set from --whisper-model or the app's config).
    nonisolated(unsafe) static var model = "whisper-large-v3-turbo"

    /// Whisper's prompt nudges it towards the names; it reads best in the call's own language.
    static let promptIntro = ["en": "A FaceTime call. Names: ", "de": "Ein FaceTime-Anruf. Namen: ", "fr": "Un appel FaceTime. Noms : ",
                              "da": "Et FaceTime-opkald. Navne: ", "ja": "FaceTime通話。名前："]

    deinit { process.terminate() }

    private static func readLine(_ h: FileHandle, _ buffered: inout Data) -> String? {
        while true {
            if let nl = buffered.firstIndex(of: 0x0A) {
                let line = buffered[buffered.startIndex..<nl]
                buffered.removeSubrange(buffered.startIndex...nl)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = h.availableData
            if chunk.isEmpty { return nil }
            buffered.append(chunk)
        }
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ftk-stt-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        var src = buffer
        if buffer.format.sampleRate != 16_000 || buffer.format.channelCount != 1 {
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            src = convert(buffer, to: mono) ?? buffer
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: src)
        }
        let req = try JSONSerialization.data(withJSONObject: ["path": url.path, "language": language, "prompt": prompt])
        input.write(req + Data([0x0A]))
        guard let line = Self.readLine(output, &buffered),
              let resp = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw CLIError("the Whisper worker stopped")
        }
        if let err = resp["error"] as? String { throw CLIError("whisper: \(err)") }
        let text = (resp["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // In silence Whisper sometimes just reads its own prompt back ("A FaceTime call.").
        if !text.isEmpty, prompt.hasPrefix(text.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))) { return "" }
        return Vocabulary.correct(text, words: words)
    }

    func transcribe(file url: URL) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CLIError("cannot read \(url.path)")
        }
        try file.read(into: buf)
        return try await transcribe(buf)
    }
}

actor Transcriber {
    let locale: Locale
    /// Names and slang the recognizer should expect ("Nikita", "Claude"); passed as contextual strings.
    private(set) var words: [String] = []

    func setWords(_ list: [String]) {
        var seen = Set<String>()
        words = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    init(language: String) async throws {
        guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            let all = await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted()
            throw CLIError("speech recognition does not support \(language); supported: \(all.joined(separator: ", "))")
        }
        locale = loc
    }

    private func makeModule() -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                             reportingOptions: [], attributeOptions: [])
    }

    /// Downloads the on-device model for the language if it is missing.
    func prepare(log: (String) -> Void) async throws {
        let module = makeModule()
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            log("downloading on-device speech model for \(locale.identifier)…")
            try await req.downloadAndInstall()
        }
        let status = await AssetInventory.status(forModules: [module])
        guard status == .installed else { throw CLIError("speech model for \(locale.identifier) is \(status)") }
    }

    func transcribe(_ buffer: AVAudioPCMBuffer) async throws -> String {
        let module = makeModule()
        let analyzer = SpeechAnalyzer(modules: [module])
        if !words.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = words
            try await analyzer.setContext(context)
        }
        var input = buffer
        if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: buffer.format),
           best != buffer.format, let converted = convert(buffer, to: best) {
            input = converted
        }
        let collect = Task { () -> String in
            var text = ""
            for try await r in module.results where r.isFinal { text += String(r.text.characters) }
            return text
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        cont.yield(AnalyzerInput(buffer: input))
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return Vocabulary.correct(try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines), words: words)
    }

    func transcribe(file url: URL) async throws -> String {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CLIError("cannot read \(url.path)")
        }
        try file.read(into: buf)
        return try await transcribe(buf)
    }
}

/// Some on-device models ignore contextual strings and custom language models can't be built for it,
/// so vocabulary words are restored after recognition: a word 1–2 letters away from one of them
/// (also with a short inflection, "Nikitas" → "Nikita") is replaced by it.
enum Vocabulary {
    static func correct(_ text: String, words: [String]) -> String {
        // "GPT: chat petit, gee pity" lines are explicit replacements for what the recognizer hears instead.
        var text = text
        for line in words where line.contains(":") {
            let parts = line.split(separator: ":", maxSplits: 1)
            let target = parts[0].trimmingCharacters(in: .whitespaces)
            for heard in parts[1].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !heard.isEmpty {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
                if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: target))
                }
            }
        }
        let vocab = words.filter { $0.count >= 4 && !$0.contains(" ") && !$0.contains(":") }
        guard !vocab.isEmpty else { return text }
        var out = ""
        var token = ""
        func flush() {
            if !token.isEmpty { out += replace(token, vocab); token = "" }
        }
        for ch in text {
            if ch.isLetter || ch == "-" { token.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }

    // Voiced/voiceless pairs sound alike at word ends and in noisy calls ("Claude" ~ "clout").
    private static let fold: [Character: Character] = ["d": "t", "b": "p", "g": "k", "z": "s", "v": "f"]

    private static func norm(_ s: String) -> [Character] {
        s.lowercased().map { fold[$0] ?? $0 }
    }

    private static func replace(_ word: String, _ vocab: [String]) -> String {
        let w = norm(word)
        guard w.count >= 3 else { return word }
        for v in vocab {
            let n = norm(v)
            if w == n { return word }
            let allowed = n.count <= 4 ? 0 : (n.count <= 6 ? 1 : 2)
            // First letter must agree in sound class roughly: require at least one of the first two letters to match.
            guard w.first == n.first || (w.count > 1 && n.count > 1 && w[1] == n[1]) else { continue }
            if abs(w.count - n.count) <= allowed, distance(w, n) <= allowed { return cased(v, like: word) }
            if w.count > n.count, w.count - n.count <= 3, distance(Array(w.prefix(n.count)), n) <= allowed {
                return cased(v + String(word.suffix(w.count - n.count)), like: word)
            }
        }
        return word
    }

    private static func cased(_ v: String, like word: String) -> String {
        word.first?.isUppercase == true || v.first?.isUppercase == true ? v.prefix(1).uppercased() + v.dropFirst().lowercased() : v.lowercased()
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }
}

func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard let conv = AVAudioConverter(from: buffer.format, to: format) else { return nil }
    let ratio = format.sampleRate / buffer.format.sampleRate
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024) else { return nil }
    var fed = false
    var err: NSError?
    conv.convert(to: out, error: &err) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return buffer
    }
    return err == nil ? out : nil
}

/// Splits the incoming 16 kHz stream into utterances at pauses and transcribes each one.
final class Listener {
    static let rate = 16_000.0
    private let frame = 320                     // 20 ms
    private let pauseFrames: Int
    private let maxFrames = 50 * 20             // 20 s per utterance
    private let prerollFrames = 15              // 300 ms kept before speech onset

    private let onText: (String) -> Void
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "ftk.listener")
    private let segments: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let recording: FileHandle?

    private var pending: [Int16] = []
    private var preroll: [[Int16]] = []
    private var segment: [Int16] = []
    private var noise: Float = 0.002
    private var voiced = 0, silent = 0, frames = 0
    private var inSpeech = false
    private var peakWindow: Float = 0, peakWindowFrames = 0

    /// Called on the listener queue when someone starts (true) or stops (false) talking.
    var onActivity: ((Bool) -> Void)?

    private let statsLock = NSLock()
    private var _stats: [String: Any] = [:]
    var stats: [String: Any] { statsLock.withLock { _stats } }

    init(transcriber: any SpeechToText, pause: Double, record: URL?, onText: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.pauseFrames = max(10, Int(pause / 0.02))
        self.onText = onText
        self.log = log
        if let record {
            FileManager.default.createFile(atPath: record.path, contents: nil)
            recording = try? FileHandle(forWritingTo: record)
        } else {
            recording = nil
        }
        let (stream, cont) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        segments = cont
        // One consumer keeps transcripts in speaking order without ever blocking the VAD.
        Task.detached { [onText, log] in
            for await buf in stream {
                let seconds = Double(buf.frameLength) / Listener.rate
                let t0 = Date()
                do {
                    let text = try await transcriber.transcribe(buf)
                    log(String(format: "transcribed %.1fs in %.2fs: %@", seconds, Date().timeIntervalSince(t0), text.isEmpty ? "(no words)" : text))
                    if !text.isEmpty { onText(text) }
                } catch {
                    log("transcription failed: \(error)")
                }
            }
        }
    }

    /// The phrase being spoken right now, so far (empty when nobody is talking).
    func currentSegment() -> AVAudioPCMBuffer? {
        let samples = queue.sync { inSpeech ? segment : [] }
        return samples.isEmpty ? nil : Listener.buffer(samples)
    }

    static func buffer(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Listener.rate, channels: 1, interleaved: false)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        let ch = buf.floatChannelData![0]
        for (i, s) in samples.enumerated() { ch[i] = Float(s) / 32768 }
        return buf
    }

    func feed(_ samples: [Int16]) {
        queue.async { [self] in
            if let recording { samples.withUnsafeBytes { recording.write(Data($0)) } }
            pending.append(contentsOf: samples)
            var i = 0
            while pending.count - i >= frame {
                process(pending[i..<(i + frame)])
                i += frame
            }
            pending.removeFirst(i)
        }
    }

    private func process(_ f: ArraySlice<Int16>) {
        var sum: Float = 0
        for s in f { let v = Float(s) / 32768; sum += v * v }
        let rms = (sum / Float(f.count)).squareRoot()
        let threshold = max(noise * 3, 0.006)
        let isVoice = rms > threshold
        // The noise floor follows quiet frames quickly and loud ones very slowly, so steady background noise can't stick.
        noise += (rms - noise) * (isVoice ? 0.0005 : 0.02)

        peakWindow = max(peakWindow, rms)
        peakWindowFrames += 1
        if peakWindowFrames >= 50 {
            statsLock.withLock {
                _stats = ["level": Double(peakWindow), "noise": Double(noise), "threshold": Double(threshold), "inSpeech": inSpeech]
            }
            peakWindow = 0
            peakWindowFrames = 0
        }

        if !inSpeech {
            preroll.append(Array(f))
            if preroll.count > prerollFrames { preroll.removeFirst() }
            voiced = isVoice ? voiced + 1 : max(0, voiced - 1)
            if voiced >= 4 {
                inSpeech = true
                onActivity?(true)
                segment = preroll.flatMap { $0 }
                preroll.removeAll()
                silent = 0
                frames = 0
            }
            return
        }
        segment.append(contentsOf: f)
        frames += 1
        silent = isVoice ? 0 : silent + 1
        if silent >= pauseFrames || frames >= maxFrames {
            let samples = segment
            segment = []
            inSpeech = false
            onActivity?(false)
            voiced = 0
            // Drop blips: under 0.3 s of actual sound is a click, not a word.
            if frames - silent >= 15 { finish(samples) }
        }
    }

    private func finish(_ samples: [Int16]) {
        if let buf = Listener.buffer(samples) { segments.yield(buf) }
    }
}

// MARK: - Text to speech

final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let rate = 24_000.0
    private let synth = AVSpeechSynthesizer()
    // write(_:toBufferCallback:) delivers empty buffers between sentences too, so the end of an
    // utterance is taken from the delegate, not from the first empty buffer.
    private var finished: [ObjectIdentifier: () -> Void] = [:]
    let voice: AVSpeechSynthesisVoice?
    let speechRate: Float

    init(language: String, voice name: String?, rate: Float?) throws {
        if let name {
            let all = AVSpeechSynthesisVoice.speechVoices()
            guard let v = AVSpeechSynthesisVoice(identifier: name)
                    ?? all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw CLIError("voice \(name) not found; see `fernsprecher-ki-modus-an voices`")
            }
            voice = v
        } else {
            voice = Speaker.bestVoice(for: language)
        }
        speechRate = rate ?? AVSpeechUtteranceDefaultSpeechRate
        super.init()
        synth.delegate = self
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished.removeValue(forKey: ObjectIdentifier(utterance))?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished.removeValue(forKey: ObjectIdentifier(utterance))?()
    }

    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let lang = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let base = String(lang.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            let l = $0.language.lowercased()
            return l == lang || l.hasPrefix(base)
        }
        return candidates.max { a, b in
            (a.quality.rawValue, a.language.lowercased() == lang ? 1 : 0) < (b.quality.rawValue, b.language.lowercased() == lang ? 1 : 0)
        } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// External synthesizer (e.g. Piper): a shell command that gets the text in FTK_TEXT and on stdin and writes a
    /// WAV file to FTK_OUT. When set, it replaces AVSpeechSynthesizer.
    var command: String?
    var commandLabel: String?

    /// Renders `text` to 24 kHz mono Int16 PCM.
    func render(_ text: String) async throws -> Data {
        if let command { return try renderExternal(text, command: command) }
        return try await renderSystem(text)
    }

    private func renderExternal(_ text: String, command: String) throws -> Data {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ftk-tts-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        var env = ProcessInfo.processInfo.environment
        env["FTK_TEXT"] = text
        env["FTK_OUT"] = out.path
        p.environment = env
        let stdin = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardError = stderr
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(Data(text.utf8))
        try? stdin.fileHandleForWriting.close()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw CLIError("tts command failed (\(p.terminationStatus)): \(String(decoding: err, as: UTF8.self).suffix(400))")
        }
        let file = try AVAudioFile(forReading: out)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CLIError("tts command wrote an unreadable file")
        }
        try file.read(into: buf)
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Speaker.rate, channels: 1, interleaved: true)!
        var src = buf
        if buf.format.channelCount != 1 || buf.format.commonFormat != .pcmFormatFloat32 {
            let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buf.format.sampleRate, channels: 1, interleaved: false)!
            src = convert(buf, to: mono) ?? buf
        }
        guard let pcm = convert(src, to: target), let p16 = pcm.int16ChannelData else { throw CLIError("cannot convert tts audio") }
        return Data(buffer: UnsafeBufferPointer(start: p16[0], count: Int(pcm.frameLength)))
    }

    /// Builds the command for a Piper voice installed under <Home>/piper (venv + voices/).
    /// `voice` is a full Piper name (de_DE-thorsten-medium) or a short one completed with the call language (thorsten).
    static func piperCommand(voice: String, language: String, lengthScale: Double?) throws -> String {
        let root = Home.engineRoot("piper").path
        let python = root + "/venv/bin/python"
        let lang = language.replacingOccurrences(of: "-", with: "_")
        let name = voice.contains("-") ? voice : "\(lang)-\(voice)-medium"
        let model = root + "/voices/\(name).onnx"
        guard FileManager.default.fileExists(atPath: python) else { throw CLIError("Piper is not installed in \(root) (see README)") }
        guard FileManager.default.fileExists(atPath: model) else {
            let have = (try? FileManager.default.contentsOfDirectory(atPath: root + "/voices"))?.filter { $0.hasSuffix(".onnx") }.map { String($0.dropLast(5)) } ?? []
            throw CLIError("no Piper voice \(name); installed: \(have.joined(separator: ", "))")
        }
        let length = lengthScale.map { " --length-scale \($0)" } ?? ""
        return "'\(python)' -I -m piper -m '\(model)'\(length) -f \"$FTK_OUT\" -i /dev/stdin"
    }

    private func renderSystem(_ text: String) async throws -> Data {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = speechRate
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Speaker.rate, channels: 1, interleaved: true)!
        return try await withCheckedThrowingContinuation { cont in
            var pcm = Data()
            DispatchQueue.main.async { [self] in
                finished[ObjectIdentifier(utterance)] = {
                    // Buffers may still be in flight on the main queue; finish after them.
                    DispatchQueue.main.async { cont.resume(returning: pcm) }
                }
                synth.write(utterance) { buffer in
                    guard let b = buffer as? AVAudioPCMBuffer, b.frameLength > 0 else { return }
                    guard let out = b.format == target ? b : convert(b, to: target), let p = out.int16ChannelData else { return }
                    pcm.append(UnsafeBufferPointer(start: p[0], count: Int(out.frameLength)))
                }
            }
        }
    }

    /// Writes rendered speech to a WAV file (for testing the voice without a call).
    func render(_ text: String, to url: URL) async throws {
        let pcm = try await render(text)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Speaker.rate, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = pcm.count / 2
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            buf.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: frames)
        }
        try file.write(from: buf)
    }
}
