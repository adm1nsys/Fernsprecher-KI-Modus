//
//  ConferencesView.swift
//  Fernsprecher
//
//  The conference book: calls the agent may be sent to, each with a name and a description.
//

import SwiftUI

struct ConferencesView: View {
    @Environment(Book.self) private var book
    @State private var selection: Conference.ID?

    var body: some View {
        @Bindable var book = book
        HSplitView {
            List(selection: $selection) {
                ForEach(book.items) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name.isEmpty ? loc("Untitled") : c.name).bold()
                        if !c.details.isEmpty { Text(c.details).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .tag(c.id)
                    .contextMenu { Button("Delete", role: .destructive) { delete(c.id) } }
                }
                .onDelete { book.items.remove(atOffsets: $0) }
            }
            .scrollContentBackground(.hidden)
            .frame(minWidth: 220, idealWidth: 260)
            .overlay {
                if book.items.isEmpty {
                    ContentUnavailableView("No conferences yet", systemImage: "phone.bubble",
                                           description: Text("Add the FaceTime links your agent may join."))
                }
            }

            Group {
                if let i = book.items.firstIndex(where: { $0.id == selection }) {
                    ConferenceEditor(conference: $book.items[i])
                } else {
                    Text("Select a conference").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity)
        }
        .navigationTitle("Conferences")
        .toolbar {
            Button {
                let c = Conference(name: loc("New conference"), link: "")
                book.items.append(c)
                selection = c.id
            } label: { Label("Add", systemImage: "plus") }
            Button { if let s = selection { delete(s) } } label: { Label("Delete", systemImage: "minus") }
                .disabled(selection == nil)
        }
    }

    private func delete(_ id: Conference.ID) {
        book.items.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }
}

private struct ConferenceEditor: View {
    @Binding var conference: Conference

    private var linkOK: Bool {
        guard let u = URL(string: conference.link) else { return false }
        return u.scheme == "https" && u.host?.hasSuffix("facetime.apple.com") == true && u.path.hasPrefix("/join")
    }

    private var joinCommand: String {
        var cmd = "\(Home.commandName) --agent <agent> join \"\(conference.link)\""
        if !conference.language.isEmpty { cmd += " --lang \(conference.language)" }
        return cmd
    }

    var body: some View {
        Form {
            TextField("Name", text: $conference.name)
            TextField("FaceTime link", text: $conference.link)
            if !conference.link.isEmpty, !linkOK {
                Text("That doesn't look like a FaceTime link (https://facetime.apple.com/join#…).").font(.caption).foregroundStyle(.orange)
            }
            Picker("Language", selection: $conference.language) {
                Text("Default").tag("")
                ForEach(Catalog.callLanguages, id: \.self) { Text(Catalog.languageName($0)).tag($0) }
            }
            TextField("What it's for", text: $conference.details, axis: .vertical).lineLimit(3...8)
            Section("Command") {
                Text(joinCommand).font(.caption.monospaced()).textSelection(.enabled)
                Button("Copy") { copy(joinCommand) }.disabled(!linkOK)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
