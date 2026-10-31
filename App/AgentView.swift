//
//  AgentView.swift
//  Fernsprecher
//
//  Writes AGENTUR.md (how an AI agent lives with the phone) and TELEFONBUCH.md (the conference book)
//  into a folder the agent reads, for Claude, GPT, the custom agent or all of them,
//  in English, German, French, Danish or Japanese.
//

import AppKit
import SwiftUI

enum Instructions {
    static let languages = ["en", "de", "fr", "da", "ja"]
    static let agentFile = "AGENTUR.md"
    static let bookFile = "TELEFONBUCH.md"

    /// `agent` nil = one file shared by all three agents.
    static func agentur(language: String, agent: AgentKind?, config: Config) -> String {
        fill(template("AGENTUR", language), language: language, agent: agent, config: config)
    }

    /// The conference book. The block between {{#ENTRY}} and {{/ENTRY}} repeats for every conference;
    /// the line {{EMPTY:…}} shows only when there are none.
    static func telefonbuch(language: String, agent: AgentKind?, config: Config, conferences: [Conference]) -> String {
        var t = template("TELEFONBUCH", language)
        if let a = t.range(of: "{{#ENTRY}}\n"), let b = t.range(of: "{{/ENTRY}}\n"), a.upperBound <= b.lowerBound {
            let entry = String(t[a.upperBound..<b.lowerBound])
            let rows = conferences.map { c in
                var join = "\(command(agent)) join \"\(c.link)\""
                if !c.language.isEmpty { join += " --lang \(c.language)" }
                return entry
                    .replacingOccurrences(of: "{{TITLE}}", with: c.name)
                    .replacingOccurrences(of: "{{LINK}}", with: c.link)
                    .replacingOccurrences(of: "{{CALL_LANG}}", with: c.language.isEmpty ? config[agent ?? .claude].language : c.language)
                    .replacingOccurrences(of: "{{JOIN}}", with: join)
                    .replacingOccurrences(of: "{{DETAILS}}", with: c.details.isEmpty ? "–" : c.details)
            }.joined(separator: "\n")
            t.replaceSubrange(a.lowerBound..<b.upperBound, with: rows)
        }
        t = t.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("{{EMPTY:"), line.hasSuffix("}}") else { return line }
            return conferences.isEmpty ? String(line.dropFirst("{{EMPTY:".count).dropLast(2)) : nil
        }.joined(separator: "\n")
        return fill(t, language: language, agent: agent, config: config)
    }

    /// The command with the agent's flag; for a shared file, a placeholder the agent fills in itself.
    static func command(_ agent: AgentKind?) -> String {
        "\(Home.commandName) --agent \(agent?.rawValue ?? "<agent>")"
    }

    private static func template(_ name: String, _ language: String) -> String {
        let url = Bundle.main.url(forResource: "\(name).\(language)", withExtension: "md")
            ?? Bundle.main.url(forResource: "\(name).en", withExtension: "md")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    /// Who this file is for: one profile line, or the list of all three.
    private static func agents(language: String, agent: AgentKind?, config: Config) -> String {
        func line(_ k: AgentKind) -> String {
            "**\(config[k].name)** — `--agent \(k.rawValue)`, `\((k.sessionDir as NSString).abbreviatingWithTildeInPath)`"
        }
        let (single, shared): (String, String) = switch language {
        case "de": ("Dein Profil: %@.", "Diese Datei gilt für mehrere Agenten. Jeder nimmt sein eigenes `--agent`:")
        case "fr": ("Votre profil : %@.", "Ce fichier sert à plusieurs agents. Chacun utilise son propre `--agent` :")
        case "da": ("Din profil: %@.", "Denne fil gælder for flere agenter. Hver bruger sit eget `--agent`:")
        case "ja": ("あなたのプロフィール：%@。", "このファイルは複数のエージェント共通です。それぞれ自分の `--agent` を使ってください：")
        default: ("Your profile: %@.", "This file is shared by several agents. Each one uses its own `--agent`:")
        }
        if let agent { return String(format: single, line(agent)) }
        return shared + "\n\n" + AgentKind.allCases.map { "- " + line($0) }.joined(separator: "\n")
    }

    private static func fill(_ s: String, language: String, agent: AgentKind?, config: Config) -> String {
        let name = agent.map { config[$0].name } ?? AgentKind.allCases.map { config[$0].name }.joined(separator: " · ")
        let dir = agent.map { ($0.sessionDir as NSString).abbreviatingWithTildeInPath } ?? "~/.fernsprecher…"
        return s.replacingOccurrences(of: "{{AGENTS}}", with: agents(language: language, agent: agent, config: config))
            .replacingOccurrences(of: "{{NAME}}", with: name)
            .replacingOccurrences(of: "{{CMD}}", with: command(agent))
            .replacingOccurrences(of: "{{DIR}}", with: dir)
            .replacingOccurrences(of: "{{LANG}}", with: config[agent ?? .claude].language)
            .replacingOccurrences(of: "{{BOOK}}", with: bookFile)
            .replacingOccurrences(of: "{{AGENTUR}}", with: agentFile)
    }
}

struct AgentView: View {
    @Environment(Settings.self) private var settings
    @Environment(Book.self) private var book
    @AppStorage("instructionsLanguage") private var language = Instructions.languages.first { Locale.current.language.languageCode?.identifier == $0 } ?? "en"
    @AppStorage("instructionsFolder") private var folder = ""
    @AppStorage("instructionsAgent") private var target = AgentKind.claude.rawValue
    @State private var showing = 0
    @State private var message = ""

    /// nil = all agents.
    private var agent: AgentKind? { AgentKind(rawValue: target) }

    var body: some View {
        Page {
            Hero(title: "Agent instructions", subtitle: "AGENTUR.md and TELEFONBUCH.md, for one agent or for all of them.",
                 color: agent.map { settings.config[$0].orbColor } ?? .white)
            AgentSwitcher(selection: Binding { agent } set: { target = $0?.rawValue ?? "all" }, includeAll: true)

            GlassPanel(title: "Export") {
                FieldRow(label: "Language of the instructions") {
                    Picker("Language of the instructions", selection: $language) {
                        ForEach(Instructions.languages, id: \.self) { l in
                            Text(Locale(identifier: l).localizedString(forLanguageCode: l)?.capitalized(with: Locale(identifier: l)) ?? l).tag(l)
                        }
                    }.labelsHidden()
                }
                FieldRow(label: "Folder") {
                    HStack {
                        Text(folder.isEmpty ? loc("Not chosen") : (folder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(folder.isEmpty ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: choose).buttonStyle(.glass)
                    }
                }
                HStack {
                    Button("Export \(Instructions.agentFile) and \(Instructions.bookFile)", action: export)
                        .buttonStyle(.glassProminent).disabled(folder.isEmpty)
                    Button("Copy \(Instructions.agentFile)") { copy(agentur) }.buttonStyle(.glass)
                    Spacer()
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            }

            GlassPanel {
                Picker("", selection: $showing) {
                    Text(Instructions.agentFile).tag(0)
                    Text(Instructions.bookFile).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(showing == 0 ? agentur : telefonbuch)
                    .font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Agent instructions")
    }

    private var agentur: String { Instructions.agentur(language: language, agent: agent, config: settings.config) }
    private var telefonbuch: String {
        Instructions.telefonbuch(language: language, agent: agent, config: settings.config, conferences: book.items)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = loc("Choose")
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func export() {
        let dir = URL(fileURLWithPath: folder)
        do {
            try agentur.write(to: dir.appendingPathComponent(Instructions.agentFile), atomically: true, encoding: .utf8)
            try telefonbuch.write(to: dir.appendingPathComponent(Instructions.bookFile), atomically: true, encoding: .utf8)
            message = loc("Saved.")
            NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(Instructions.agentFile)])
        } catch {
            message = error.localizedDescription
        }
    }
}
