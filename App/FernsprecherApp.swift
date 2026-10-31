//
//  FernsprecherApp.swift
//  Fernsprecher
//
//  Installs the fernsprecher-ki-modus-an CLI, manages its models, keeps a profile per agent
//  (Claude, GPT, a custom one), keeps the conference book and writes the agents' instructions.
//

import SwiftUI

@main
struct FernsprecherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var language = AppLanguage()
    @State private var installer = Installer()
    @State private var store = Store()
    @State private var book = Book()
    @State private var settings = Settings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(installer)
                .environment(store)
                .environment(book)
                .environment(settings)
                .environment(language)
                .environment(\.locale, language.locale)
                .id(language.code)   // re-reads strings that aren't SwiftUI Text
                // The CLI words the call tile in the app's language unless a profile says otherwise.
                .task(id: language.code) { settings.config.appLanguage = language.resolved }
                .preferredColorScheme(.dark)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1040, height: 720)
        .windowStyle(.hiddenTitleBar)
    }
}

/// The agent profiles the CLI reads (config.json), saved as soon as they change.
@Observable
final class Settings {
    var config = Config.load() {
        didSet { if config != oldValue { try? config.save() } }
    }

    /// The agent being edited or tested (remembered between launches).
    var agent = AgentKind(rawValue: UserDefaults.standard.string(forKey: "agent") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(agent.rawValue, forKey: "agent") }
    }

    var profile: Profile {
        get { config[agent] }
        set { config[agent] = newValue }
    }

    /// "local" or "whisper:<model>", for pickers.
    var speechIn: String {
        get { profile.stt == "whisper" ? "whisper:\(profile.whisperModel)" : "local" }
        set {
            if newValue.hasPrefix("whisper:") {
                profile.stt = "whisper"
                profile.whisperModel = String(newValue.dropFirst("whisper:".count))
            } else {
                profile.stt = "local"
            }
        }
    }

    /// "system:<voice id>" or "piper:<voice>", for pickers.
    var voiceOut: String {
        get { "\(profile.tts):\(profile.voice)" }
        set {
            let parts = newValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            profile.tts = String(parts[0])
            profile.voice = parts.count > 1 ? String(parts[1]) : ""
        }
    }

    /// CLI flags for the current agent; the test page passes them so it never depends on what's saved.
    var cliFlags: [String] {
        let p = profile
        var f = ["--agent", agent.rawValue, "--lang", p.language]
        f += p.stt == "whisper" ? ["--stt", "whisper", "--whisper-model", p.whisperModel] : ["--stt", "local"]
        if !p.voice.isEmpty { f += p.tts == "piper" ? ["--piper", p.voice] : ["--voice", p.voice] }
        return f
    }
}

/// The conference book (conferences.json).
@Observable
final class Book {
    var items = Conference.loadAll() {
        didSet { try? Conference.saveAll(items) }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case install, models, test, conferences, agent
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .install: "Install"
        case .models: "Models"
        case .test: "Test"
        case .conferences: "Conferences"
        case .agent: "Agent instructions"
        }
    }

    var icon: String {
        switch self {
        case .install: "terminal"
        case .models: "waveform"
        case .test: "mic.and.signal.meter"
        case .conferences: "phone.bubble"
        case .agent: "doc.text"
        }
    }
}

struct ContentView: View {
    @Environment(Settings.self) private var settings
    @AppStorage("screen") private var lastScreen = Screen.install.rawValue

    private var screen: Binding<Screen?> {
        Binding { Screen(rawValue: lastScreen) ?? .install } set: { lastScreen = ($0 ?? .install).rawValue }
    }

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: screen) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Orb(color: settings.profile.orbColor, size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Fernsprecher").font(.caption.weight(.semibold))
                        Text("KI-Modus an").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    LanguageMenu()
                }
                .padding(14)
            }
        } detail: {
            ZStack {
                Backdrop(colors: settings.profile.backgroundColors, glow: settings.profile.orbColor)
                switch screen.wrappedValue ?? .install {
                case .install: InstallView()
                case .models: ModelsView()
                case .test: TestView()
                case .conferences: ConferencesView()
                case .agent: AgentView()
                }
            }
        }
    }
}
