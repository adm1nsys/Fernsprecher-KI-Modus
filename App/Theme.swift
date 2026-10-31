//
//  Theme.swift
//  Fernsprecher
//
//  The look: a dark backdrop with drifting light in the selected agent's colours, Liquid Glass cards,
//  and the same orb the agent shows on its call tile.
//

import AppKit
import SwiftUI

extension AgentKind {
    var title: LocalizedStringKey {
        switch self {
        case .claude: "Claude"
        case .gpt: "GPT · Codex"
        case .custom: "Custom agent"
        }
    }
}

extension Profile {
    var orbColor: Color { Color(hex: colors[safe: 2] ?? "#8b7cf6") }
    var backgroundColors: [Color] { [Color(hex: colors[safe: 0] ?? "#0b0b14"), Color(hex: colors[safe: 1] ?? "#17172a")] }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x8b7cf6
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    var hex: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// Dark backdrop with slow, blurred light in the agent's colours and a touch of film grain.
struct Backdrop: View {
    var colors: [Color]
    var glow: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                ZStack {
                    LinearGradient(colors: colors.map { $0.opacity(0.9) } + [.black], startPoint: .top, endPoint: .bottom)
                    Circle().fill(glow.opacity(0.35))
                        .frame(width: g.size.width * 0.7)
                        .offset(x: cos(s / 9) * g.size.width * 0.25, y: sin(s / 11) * g.size.height * 0.2 - g.size.height * 0.2)
                        .blur(radius: 90)
                    Circle().fill(glow.opacity(0.18))
                        .frame(width: g.size.width * 0.5)
                        .offset(x: sin(s / 13) * g.size.width * 0.3, y: cos(s / 7) * g.size.height * 0.25 + g.size.height * 0.3)
                        .blur(radius: 110)
                    Grain().opacity(0.06).blendMode(.overlay)
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: glow)
    }
}

/// Static noise, drawn once.
private struct Grain: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<Int(size.width * size.height / 40) {
                let x = Double.random(in: 0..<size.width, using: &rng), y = Double.random(in: 0..<size.height, using: &rng)
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(.random(in: 0.2...1, using: &rng))))
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// The agent's orb, as on its call tile. `energy` 0…1 makes it breathe harder (listening, speaking).
struct Orb: View {
    var color: Color
    var size: CGFloat = 64
    var energy: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            let pulse = 1 + (0.03 + energy * 0.12) * sin(s * (2 + energy * 6))
            ZStack {
                Circle().fill(color.opacity(0.45)).blur(radius: size * 0.35).scaleEffect(1.25 * pulse)
                Circle()
                    .fill(RadialGradient(colors: [.white, color.mix(with: .white, by: 0.25), color, color.mix(with: .black, by: 0.5)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.62))
                    .scaleEffect(pulse)
            }
            .frame(width: size, height: size)
        }
    }
}

/// Glass capsules to pick the agent; with `includeAll`, a fourth one for "all agents" (nil).
struct AgentSwitcher: View {
    @Binding var selection: AgentKind?
    var includeAll = false
    @Environment(Settings.self) private var settings
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(AgentKind.allCases) { k in chip(k) }
                if includeAll { chip(nil) }
            }
        }
    }

    private func chip(_ k: AgentKind?) -> some View {
        let on = selection == k
        let color = k.map { settings.config[$0].orbColor } ?? .white
        return Button {
            withAnimation(.smooth) { selection = k }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8).shadow(color: color, radius: on ? 5 : 0)
                if let k {
                    if settings.config[k].name.isEmpty { Text(k.title) } else { Text(verbatim: settings.config[k].name) }
                } else {
                    Text("All agents")
                }
            }
            .font(.callout.weight(on ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(color.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
        .glassEffectID(k?.rawValue ?? "all", in: glass)
    }
}

/// Page header: orb, title, subtitle.
struct Hero: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey
    var color: Color
    var energy: Double = 0

    var body: some View {
        HStack(spacing: 18) {
            Orb(color: color, size: 54, energy: energy)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// A Liquid Glass panel for page content.
struct GlassPanel<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.caption.weight(.semibold)).textCase(.uppercase).tracking(1.2).foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

/// Scrolling page layout shared by all screens.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}
