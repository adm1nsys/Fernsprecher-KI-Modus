//
//  InstallView.swift
//  Fernsprecher
//

import SwiftUI

struct InstallView: View {
    @Environment(Installer.self) private var installer
    @Environment(Settings.self) private var settings

    var body: some View {
        Page {
            Hero(title: "Command-line tool", subtitle: "\(Home.commandName)", color: settings.profile.orbColor)

            GlassPanel(title: "Status") {
                HStack(alignment: .center) {
                    status
                    Spacer()
                    switch installer.state {
                    case .notInstalled:
                        Button("Install") { Task { await installer.install() } }.buttonStyle(.glassProminent)
                    case .outdated:
                        Button("Uninstall", role: .destructive) { Task { await installer.uninstall() } }.buttonStyle(.glass)
                        Button("Update") { Task { await installer.install() } }.buttonStyle(.glassProminent)
                    case .installed:
                        Button("Uninstall", role: .destructive) { Task { await installer.uninstall() } }.buttonStyle(.glass)
                    case .conflict, .unknown:
                        EmptyView()
                    }
                    Button { Task { await installer.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.glass).help(Text("Check again"))
                }
                if let e = installer.error {
                    Text(e).foregroundStyle(.red).textSelection(.enabled)
                }
                Text("The tool goes to your Library folder and gets a link in ~/.local/bin. Homebrew, /usr/local and system folders stay untouched, and a command of the same name that isn't ours is never replaced.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if installer.state == .installed || installer.state == .outdated, !installer.onPath {
                GlassPanel(title: "PATH") {
                    Text("~/.local/bin is not on your PATH yet, so the shell won't find the command. Add this line to ~/.zprofile:")
                    Text(Installer.pathLine).font(.body.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Add it for me") { Task { await installer.addToProfile() } }.buttonStyle(.glassProminent)
                        Button("Copy") { copy(Installer.pathLine) }.buttonStyle(.glass)
                    }
                    Text("Open a new Terminal window afterwards. Uninstall removes the line again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            GlassPanel(title: "Try it") {
                ForEach(AgentKind.allCases) { k in
                    HStack(spacing: 10) {
                        Circle().fill(settings.config[k].orbColor).frame(width: 8, height: 8)
                        Text(verbatim: "\(Home.commandName) --agent \(k.rawValue) join \"https://facetime.apple.com/join#…\"")
                            .font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                Text("Someone in the call has to let the agent in. Then it hears everyone as text and speaks with `say`.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Install")
        .task { await installer.refresh() }
    }

    @ViewBuilder private var status: some View {
        switch installer.state {
        case .unknown: ProgressView().controlSize(.small)
        case .notInstalled: Label("Not installed", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .installed: Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .outdated: Label("Update available", systemImage: "arrow.down.circle").foregroundStyle(.orange)
        case .conflict(let path):
            VStack(alignment: .leading) {
                Label("Name already taken", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(path).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
