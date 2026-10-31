//
//  ModelsView.swift
//  Fernsprecher
//
//  A profile per agent (name, language, speech in, voice out, colours) plus the store of models and voices.
//

import AVFoundation
import SwiftUI

struct ModelsView: View {
    @Environment(Store.self) private var store
    @Environment(Settings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Page {
            Hero(title: "Models", subtitle: "Each agent gets its own name, language, ears and voice.", color: settings.profile.orbColor)
            AgentSwitcher(selection: Binding($settings.agent))

            GlassPanel(title: "Profile") {
                ProfileFields()
                Text("Saved for the command line straight away. Flags such as --lang or --piper still win.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            GlassPanel(title: "Speech in") {
                HStack {
                    Text("Apple, on-device").bold()
                    Spacer()
                    Button("Download Apple's model for \(Catalog.languageName(settings.profile.language))") {
                        Task { await store.installAppleSpeech(settings.profile.language) }
                    }
                    .buttonStyle(.glass).disabled(store.busy != nil)
                }
                Divider().opacity(0.4)
                engineRow(title: "Whisper engine (MLX)", ready: store.whisperReady, busyID: "whisper") { await store.installWhisperEngine() }
                ForEach(Catalog.whisper) { m in
                    modelRow(title: m.id, detail: Text(m.summary), sizeMB: m.sizeMB, installed: store.installed(m),
                             busy: store.busy == m.id, enabled: store.whisperReady && store.busy == nil,
                             get: { await store.download(m) }, remove: { store.remove(m) })
                }
                Text("Apple's model is built into macOS. Whisper needs Apple silicon and runs on this Mac too, just with a bigger appetite.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            GlassPanel(title: "Voice out") {
                engineRow(title: "Piper engine", ready: store.piperReady, busyID: "piper") { await store.installPiperEngine() }
                ForEach(Catalog.piper) { v in
                    modelRow(title: v.id, detail: Text(v.languageName), sizeMB: v.sizeMB, installed: store.installed(v),
                             busy: store.busy == v.id, enabled: store.piperReady && store.busy == nil,
                             get: { await store.download(v) }, remove: { store.remove(v) })
                }
                Text("More Apple voices (including Japanese): System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if !store.log.isEmpty {
                GlassPanel(title: "Log") {
                    ScrollView {
                        Text(store.log.suffix(60).joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .defaultScrollAnchor(.bottom)
                }
            }
        }
        .navigationTitle("Models")
    }

    private func engineRow(title: LocalizedStringKey, ready: Bool, busyID: String, install: @escaping () async -> Void) -> some View {
        HStack {
            Text(title).bold()
            Spacer()
            if store.busy == busyID {
                ProgressView().controlSize(.small)
            } else if ready {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Set up") { Task { await install() } }.buttonStyle(.glassProminent).disabled(store.busy != nil)
            }
        }
    }

    private func modelRow(title: String, detail: Text, sizeMB: Int, installed: Bool, busy: Bool, enabled: Bool,
                          get: @escaping () async -> Void, remove: @escaping () -> Void) -> some View {
        HStack {
            Circle().fill(installed ? settings.profile.orbColor : .secondary.opacity(0.3)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.monospaced())
                detail.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(sizeMB) * 1_000_000, countStyle: .file))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if busy {
                ProgressView().controlSize(.small)
            } else if installed {
                Button("Remove", role: .destructive, action: remove).buttonStyle(.glass).disabled(store.busy != nil)
            } else {
                Button("Get") { Task { await get() } }.buttonStyle(.glass).disabled(!enabled)
            }
        }
    }
}

/// One labelled control in a glass panel.
struct FieldRow<Control: View>: View {
    var label: LocalizedStringKey
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            control.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The current agent's profile: shared by the Models and Test pages.
struct ProfileFields: View {
    @Environment(Store.self) private var store
    @Environment(Settings.self) private var settings
    var showIdentity = true

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 10) {
            if showIdentity {
                FieldRow(label: "Agent name") { TextField("Agent name", text: $settings.profile.name).textFieldStyle(.roundedBorder).labelsHidden() }
            }
            FieldRow(label: "Call language") {
                Picker("Call language", selection: $settings.profile.language) {
                    ForEach(Catalog.callLanguages, id: \.self) { Text(Catalog.languageName($0)).tag($0) }
                }.labelsHidden()
            }
            FieldRow(label: "Speech in") {
                Picker("Speech in", selection: $settings.speechIn) {
                    Text("Apple, on-device").tag("local")
                    ForEach(Catalog.whisper.filter(store.installed)) { Text("Whisper · \($0.id)").tag("whisper:\($0.id)") }
                }.labelsHidden()
            }
            FieldRow(label: "Voice out") {
                Picker("Voice out", selection: $settings.voiceOut) {
                    Text("Apple, best for the language").tag("system:")
                    ForEach(Store.appleVoices(for: settings.profile.language), id: \.identifier) { v in
                        Text("Apple · \(v.name)\(v.quality == .default ? "" : " ★")").tag("system:\(v.identifier)")
                    }
                    ForEach(Catalog.piper.filter(store.installed)) { Text("Piper · \($0.id)").tag("piper:\($0.id)") }
                }.labelsHidden()
            }
            if showIdentity {
                FieldRow(label: "Tile language") {
                    Picker("Tile language", selection: $settings.profile.tileLanguage) {
                        Text("Like the app").tag("")
                        ForEach(AppLanguage.available, id: \.self) { Text(verbatim: AppLanguage.name($0)).tag($0) }
                    }.labelsHidden()
                }
            }
            if showIdentity, settings.agent == .custom {
                FieldRow(label: "Tile colours") {
                    HStack(spacing: 14) {
                        colorWell("Top", index: 0)
                        colorWell("Bottom", index: 1)
                        colorWell("Orb", index: 2)
                        Spacer()
                        Button("Reset") { settings.profile.colors = Profile.defaults(.custom).colors }.buttonStyle(.glass)
                    }
                }
            }
        }
    }

    private func colorWell(_ label: LocalizedStringKey, index: Int) -> some View {
        ColorPicker(label, selection: Binding {
            Color(hex: settings.profile.colors[safe: index] ?? "#000000")
        } set: { c in
            var colors = settings.profile.colors
            while colors.count < 3 { colors.append("#000000") }
            colors[index] = c.hex
            settings.profile.colors = colors
        }, supportsOpacity: false)
    }
}
