//
//  Store.swift
//  Fernsprecher
//
//  The model store: speech-in models (Apple on-device, Whisper via MLX) and voices (Apple, Piper).
//  Everything lands in ~/Library/Application Support/Fernsprecher-KI-Modus; nothing is installed system-wide.
//

import AVFoundation
import Foundation
import Observation

struct WhisperModel: Identifiable {
    let id: String          // folder under whisper/models
    let repo: String        // Hugging Face repo
    let sizeMB: Int
    let summary: LocalizedStringResource
}

struct PiperVoice: Identifiable, Hashable {
    let id: String          // de_DE-thorsten-medium
    let sizeMB: Int

    var locale: String { String(id.prefix { $0 != "-" }) }
    var speaker: String { id.split(separator: "-").dropFirst().first.map(String.init) ?? id }
    var quality: String { id.split(separator: "-").last.map(String.init) ?? "" }
    var languageName: String {
        AppLanguage.displayLocale.localizedString(forIdentifier: locale.replacingOccurrences(of: "_", with: "-")) ?? locale
    }
    var url: URL {
        let lang = String(locale.prefix { $0 != "_" })
        return URL(string: "https://huggingface.co/rhasspy/piper-voices/resolve/main/\(lang)/\(locale)/\(speaker)/\(quality)/\(id).onnx")!
    }
}

enum Catalog {
    static let whisper: [WhisperModel] = [
        WhisperModel(id: "whisper-large-v3-turbo", repo: "mlx-community/whisper-large-v3-turbo", sizeMB: 1600,
                     summary: "Best all-rounder. About a second per phrase on Apple silicon."),
        WhisperModel(id: "whisper-medium-mlx", repo: "mlx-community/whisper-medium-mlx", sizeMB: 1500,
                     summary: "Older and slower than turbo; only if turbo trips over your accent."),
        WhisperModel(id: "whisper-small-mlx", repo: "mlx-community/whisper-small-mlx", sizeMB: 480,
                     summary: "Light and quick. Fine for clear speech in a quiet room."),
        WhisperModel(id: "distil-whisper-large-v3", repo: "mlx-community/distil-whisper-large-v3", sizeMB: 1500,
                     summary: "English only, very fast."),
    ]

    /// Piper voices for English and European languages (Japanese uses Apple's voices).
    static let piper: [PiperVoice] = [
        "en_US-lessac-medium", "en_US-amy-medium", "en_GB-alan-medium", "en_GB-jenny_dioco-medium",
        "de_DE-thorsten-medium", "de_DE-thorsten_emotional-medium", "de_DE-kerstin-low", "de_DE-ramona-low",
        "fr_FR-siwis-medium", "fr_FR-tom-medium", "fr_FR-upmc-medium",
        "da_DK-talesyntese-medium",
        "es_ES-davefx-medium", "it_IT-paola-medium", "nl_NL-mls-medium", "nl_BE-nathalie-medium",
        "pl_PL-gosia-medium", "sv_SE-nst-medium", "fi_FI-harri-medium", "cs_CZ-jirka-medium",
    ].map { PiperVoice(id: $0, sizeMB: $0.hasSuffix("-low") ? 28 : 63) }

    /// Languages a call can be held in.
    static let callLanguages = ["en-US", "en-GB", "de-DE", "fr-FR", "da-DK", "es-ES", "it-IT", "nl-NL",
                                "pl-PL", "sv-SE", "fi-FI", "cs-CZ", "ja-JP"]

    static func languageName(_ id: String) -> String {
        AppLanguage.displayLocale.localizedString(forIdentifier: id) ?? id
    }
}

@Observable
final class Store {
    var log: [String] = []
    /// Id of whatever is being installed right now.
    var busy: String?
    private(set) var revision = 0      // bumps after installs so views re-read the disk

    // MARK: engines

    var whisperRoot: URL { Home.engineRoot("whisper") }
    var piperRoot: URL { Home.engineRoot("piper") }
    var whisperReady: Bool { _ = revision; return FileManager.default.fileExists(atPath: whisperRoot.appendingPathComponent("venv/bin/python").path) }
    var piperReady: Bool { _ = revision; return FileManager.default.fileExists(atPath: piperRoot.appendingPathComponent("venv/bin/python").path) }

    func installed(_ m: WhisperModel) -> Bool {
        _ = revision
        return FileManager.default.fileExists(atPath: whisperRoot.appendingPathComponent("models/\(m.id)/config.json").path)
    }

    func installed(_ v: PiperVoice) -> Bool {
        _ = revision
        return FileManager.default.fileExists(atPath: piperRoot.appendingPathComponent("voices/\(v.id).onnx").path)
    }

    /// A Python 3.9–3.13 to build the private venvs from. Only read, never modified.
    private func findPython() async -> String? {
        for p in ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.11",
                  "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: p) {
            let r = await Shell.run(p, ["-c", "import sys; print(sys.version_info[1] if sys.version_info[0] == 3 else 0)"])
            if let minor = Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)), (9...13).contains(minor) { return p }
        }
        return nil
    }

    private func say(_ s: String) { log.append(s); if log.count > 400 { log.removeFirst(log.count - 400) } }

    /// Creates `<root>/venv` and pip-installs `packages` into it.
    private func makeVenv(_ root: URL, packages: [String]) async -> Bool {
        guard let python = await findPython() else {
            say("Python 3.9–3.13 not found. Install one (python.org or `xcode-select --install`) and try again.")
            return false
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let venv = root.appendingPathComponent("venv").path
        say("$ \(python) -m venv \(venv)")
        guard await Shell.run(python, ["-m", "venv", venv], line: { [weak self] in self?.say($0) }).status == 0 else { return false }
        say("$ pip install \(packages.joined(separator: " "))")
        let pip = await Shell.run(venv + "/bin/python", ["-m", "pip", "install", "--disable-pip-version-check", "--upgrade"] + packages,
                                  line: { [weak self] in self?.say($0) })
        return pip.status == 0
    }

    func installWhisperEngine() async {
        busy = "whisper"; defer { busy = nil; revision += 1 }
        let root = Home.root.appendingPathComponent("whisper")
        guard await makeVenv(root, packages: ["mlx-whisper", "huggingface_hub"]) else { say("✗ Whisper engine"); return }
        copyWorker(to: root)
        say("✓ Whisper engine")
    }

    /// Ships the worker with the app so updates reach existing installs.
    func copyWorker(to root: URL? = nil) {
        guard let src = Bundle.main.url(forResource: "whisper-worker", withExtension: "py") else { return }
        let dst = (root ?? whisperRoot).appendingPathComponent("worker.py")
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    func download(_ m: WhisperModel) async {
        busy = m.id; defer { busy = nil; revision += 1 }
        copyWorker()
        let dest = whisperRoot.appendingPathComponent("models/\(m.id)").path
        say("↓ \(m.repo)")
        let script = "import sys; from huggingface_hub import snapshot_download; snapshot_download(sys.argv[1], local_dir=sys.argv[2])"
        let r = await Shell.run(whisperRoot.appendingPathComponent("venv/bin/python").path, ["-I", "-c", script, m.repo, dest],
                                line: { [weak self] in self?.say($0) })
        say(r.status == 0 ? "✓ \(m.id)" : "✗ \(m.id)")
    }

    func remove(_ m: WhisperModel) {
        try? FileManager.default.removeItem(at: whisperRoot.appendingPathComponent("models/\(m.id)"))
        revision += 1
    }

    func installPiperEngine() async {
        busy = "piper"; defer { busy = nil; revision += 1 }
        let ok = await makeVenv(Home.root.appendingPathComponent("piper"), packages: ["piper-tts"])
        say(ok ? "✓ Piper engine" : "✗ Piper engine")
    }

    func download(_ v: PiperVoice) async {
        busy = v.id; defer { busy = nil; revision += 1 }
        let dir = piperRoot.appendingPathComponent("voices")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        say("↓ \(v.url.absoluteString)")
        do {
            for (src, name) in [(v.url.appendingPathExtension("json"), "\(v.id).onnx.json"), (v.url, "\(v.id).onnx")] {
                let (tmp, resp) = try await URLSession.shared.download(from: src)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw CLIError("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0) for \(src.lastPathComponent)") }
                let dst = dir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tmp, to: dst)
            }
            say("✓ \(v.id)")
        } catch {
            say("✗ \(v.id): \(error)")
        }
    }

    func remove(_ v: PiperVoice) {
        let dir = piperRoot.appendingPathComponent("voices")
        for ext in ["onnx", "onnx.json"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(v.id).\(ext)")) }
        revision += 1
    }

    /// Downloads Apple's on-device speech model for a language (through the CLI's `setup`).
    func installAppleSpeech(_ language: String) async {
        guard let cli = Shell.bundledCLI else { return }
        busy = "apple-\(language)"; defer { busy = nil; revision += 1 }
        let r = await Shell.run(cli, ["setup", "--lang", language], line: { [weak self] in self?.say($0) })
        say(r.status == 0 ? "✓ Apple \(language)" : "✗ Apple \(language)")
    }

    // MARK: Apple voices

    static func appleVoices(for language: String) -> [AVSpeechSynthesisVoice] {
        let base = language.prefix(2).lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(base) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }
}
