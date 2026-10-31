//
//  AppChrome.swift
//  Fernsprecher
//
//  The app's own language setting, and a menu bar trimmed down to the app menu.
//

import AppKit
import SwiftUI

/// The language the app speaks, independent of the Mac's. Empty = follow the system.
@Observable
final class AppLanguage {
    static let available = ["en", "de", "fr", "da", "ja"]

    var code = UserDefaults.standard.string(forKey: "appLanguage") ?? "" {
        didSet {
            UserDefaults.standard.set(code, forKey: "appLanguage")
            // The menu bar and system panels read AppleLanguages at launch; SwiftUI switches right away.
            if code.isEmpty {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([code], forKey: "AppleLanguages")
            }
            AppLanguage.current = code
        }
    }

    init() { AppLanguage.current = code }

    var locale: Locale { code.isEmpty ? .autoupdatingCurrent : Locale(identifier: code) }

    /// The language actually in use: the chosen one, or the first system language the app has.
    var resolved: String {
        if !code.isEmpty { return code }
        let system = Locale.preferredLanguages.map { String($0.prefix(2)) }
        return system.first(where: AppLanguage.available.contains) ?? "en"
    }

    /// A language's own name for itself: Deutsch, Français, 日本語.
    static func name(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized(with: Locale(identifier: code)) ?? code
    }

    /// For strings built outside SwiftUI views (String(localized:) would follow the system language).
    nonisolated(unsafe) static var current = ""

    /// For names of languages and regions shown in the app.
    static var displayLocale: Locale { current.isEmpty ? .current : Locale(identifier: current) }

    static var bundle: Bundle {
        guard !current.isEmpty, let path = Bundle.main.path(forResource: current, ofType: "lproj"),
              let b = Bundle(path: path) else { return .main }
        return b
    }
}

/// Like String(localized:), but in the app's chosen language.
func loc(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppLanguage.bundle)
}

/// Globe menu at the bottom of the sidebar.
struct LanguageMenu: View {
    @Environment(AppLanguage.self) private var language

    var body: some View {
        Menu {
            Picker("Language", selection: Binding { language.code } set: { language.code = $0 }) {
                Text("System").tag("")
                ForEach(AppLanguage.available, id: \.self) { Text(verbatim: AppLanguage.name($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Language"))
    }
}

/// Keeps only the app menu (About, Settings, Hide, Quit) in the menu bar. Copy, paste and friends
/// lived in the Edit menu, so their shortcuts are handled here instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keys: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        trimMenu()
        // SwiftUI rebuilds the menu when windows come and go.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.trimMenu() }
        }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command || flags == [.command, .shift] else { return event }
            let action: Selector? = switch (event.charactersIgnoringModifiers?.lowercased(), flags.contains(.shift)) {
            case ("x", false): #selector(NSText.cut(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("v", false): #selector(NSText.paste(_:))
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            case ("w", false): #selector(NSWindow.performClose(_:))
            case ("m", false): #selector(NSWindow.performMiniaturize(_:))
            default: nil
            }
            guard let action, NSApp.sendAction(action, to: nil, from: nil) else { return event }
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func trimMenu() {
        guard let menu = NSApp.mainMenu else { return }
        while menu.items.count > 1 { menu.removeItem(at: menu.items.count - 1) }
    }
}
