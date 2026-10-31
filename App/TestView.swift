//
//  TestView.swift
//  Fernsprecher
//
//  Try the chosen models before a call: speak into the Mac's microphone and read what was understood,
//  type a sentence and hear the agent's voice. Both run through the bundled CLI, the same code a call uses.
//

import AVFoundation
import SwiftUI

struct TestView: View {
    @Environment(Settings.self) private var settings
    @State private var recorder: AVAudioRecorder?
    @State private var player: AVAudioPlayer?
    @State private var recording = false
    @State private var heard = ""
    @State private var hearing = false
    @State private var sentence = ""
    @State private var speaking = false
    @State private var note = ""

    private let seconds = 5.0
    private var scratch: URL { FileManager.default.temporaryDirectory.appendingPathComponent("fernsprecher-test", isDirectory: true) }

    var body: some View {
        @Bindable var settings = settings
        Page {
            Hero(title: "Test", subtitle: "Try the ears and the voice before the call, not during it.",
                 color: settings.profile.orbColor, energy: recording || speaking ? 1 : (hearing ? 0.5 : 0))
            AgentSwitcher(selection: Binding($settings.agent))

            GlassPanel(title: "Models") {
                ProfileFields(showIdentity: false)
            }

            GlassPanel(title: "Speech in") {
                HStack {
                    Button {
                        Task { await record() }
                    } label: {
                        Label(recording ? "Listening…" : "Record \(Int(seconds)) seconds", systemImage: recording ? "waveform" : "mic.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(recording || hearing)
                    if hearing { ProgressView().controlSize(.small) }
                }
                if !heard.isEmpty {
                    Text(heard).font(.title3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Uses the Mac's microphone for this test only. In a call the agent hears the call, not your room.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            GlassPanel(title: "Voice out") {
                TextField("Sentence", text: $sentence, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                HStack {
                    Button {
                        Task { await speak() }
                    } label: {
                        Label("Speak", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(speaking || sentence.isEmpty)
                    if speaking { ProgressView().controlSize(.small) }
                }
            }

            if !note.isEmpty {
                Text(note).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .navigationTitle("Test")
        .onAppear { if sentence.isEmpty { sentence = Self.sample(settings.profile.language) } }
        .onChange(of: settings.profile.language) { _, l in sentence = Self.sample(l) }
    }

    private func record() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            note = loc("Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone.")
            return
        }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("mic.wav")
        let format: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                                     AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        do {
            let r = try AVAudioRecorder(url: file, settings: format)
            recorder = r
            heard = ""
            recording = true
            r.record(forDuration: seconds)
            try await Task.sleep(for: .seconds(seconds + 0.3))
            r.stop()
            recording = false
        } catch {
            recording = false
            note = "\(error)"
            return
        }
        hearing = true
        defer { hearing = false }
        let t0 = Date()
        let r = await runCLI(["stt", file.path])
        let text = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status == 0 {
            heard = text.split(separator: "\n").last.map(String.init) ?? ""
            if heard.isEmpty { heard = loc("(nothing recognised – try a little closer to the mic)") }
            note = String(format: "%.1f s", Date().timeIntervalSince(t0))
        } else {
            note = text
        }
    }

    private func speak() async {
        speaking = true
        defer { speaking = false }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("voice.wav")
        let r = await runCLI(["tts", sentence, "-o", file.path])
        note = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, let p = try? AVAudioPlayer(contentsOf: file) else { return }
        player = p
        p.play()
        try? await Task.sleep(for: .seconds(p.duration))
    }

    private func runCLI(_ args: [String]) async -> (status: Int32, output: String) {
        guard let cli = Shell.bundledCLI else { return (-1, "the CLI is missing from the app bundle") }
        return await Shell.run(cli, args + settings.cliFlags)
    }

    static func sample(_ language: String) -> String {
        switch language.prefix(2) {
        case "de": "Guten Tag, hier ist dein KI-Fernsprecher. Ich höre zu und halte mich kurz."
        case "fr": "Bonjour, ici votre assistant au téléphone. J'écoute, et je promets d'être bref."
        case "da": "Goddag, det er din AI i røret. Jeg lytter og skal nok fatte mig i korthed."
        case "es": "Hola, soy tu asistente al teléfono. Escucho y prometo ser breve."
        case "it": "Buongiorno, sono il tuo assistente al telefono. Ascolto e prometto di essere breve."
        case "nl": "Goedendag, hier spreekt je AI aan de lijn. Ik luister en houd het kort."
        case "pl": "Dzień dobry, tu twój asystent przy telefonie. Słucham i obiecuję mówić krótko."
        case "sv": "Hej, det är din AI i luren. Jag lyssnar och fattar mig kort."
        case "fi": "Hei, täällä tekoälysi puhelimessa. Kuuntelen ja puhun lyhyesti."
        case "cs": "Dobrý den, tady váš asistent na telefonu. Poslouchám a budu stručný."
        case "ja": "こんにちは、電話対応AIです。しっかり聞いて、手短にお話しします。"
        default: "Hello, this is your AI on the line. I'm listening, and I promise to keep it short."
        }
    }
}
