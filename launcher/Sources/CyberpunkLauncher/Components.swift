import LauncherCore
import SwiftUI

// MARK: - Design system (Cyberpunk 2077 UI: near-black, signal red labels, cyan interaction, yellow primary action)

enum Theme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.055)
    static let surface = Color(red: 0.07, green: 0.06, blue: 0.08)
    static let surfaceHi = Color(red: 0.10, green: 0.08, blue: 0.10)
    static let red = Color(red: 1.0, green: 0.36, blue: 0.33)          // labels, headers, frames
    static let redDim = Color(red: 1.0, green: 0.36, blue: 0.33).opacity(0.35)
    static let cyan = Color(red: 0.36, green: 0.95, blue: 0.95)        // interactive, active
    static let cyanDim = Color(red: 0.36, green: 0.95, blue: 0.95).opacity(0.18)
    static let accent = Color(red: 0.99, green: 0.93, blue: 0.04)      // primary action
    static let accentText = Color.black
    static let text = Color(red: 0.93, green: 0.90, blue: 0.86)
    static let textDim = Color(red: 0.93, green: 0.90, blue: 0.86).opacity(0.55)
    static let good = Color(red: 0.36, green: 0.95, blue: 0.62)
    static let warn = Color(red: 1.0, green: 0.70, blue: 0.22)
    static let bad = Color(red: 1.0, green: 0.30, blue: 0.30)
    // Kept for older call sites.
    static let panel = surface
    static let panelStroke = redDim
}

extension Font {
    /// Condensed UI type, like the game's menus.
    static func cp(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
    static func cpMono(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .monospaced) }
    /// Titles and uppercase headings: Chakra Petch, an angular OFL face (launcher/Resources, bundled by make-app.sh and
    /// registered at launch). Falls back to the system font if it is missing.
    static func cpHead(_ size: CGFloat, bold: Bool = true) -> Font { .custom(bold ? "ChakraPetch-Bold" : "ChakraPetch-SemiBold", size: size) }
    static func cpDisplay(_ size: CGFloat) -> Font { cpHead(size) }
    /// The fan-made logo font for page titles (personal use only; see launcher/Resources).
    static func cpLogo(_ size: CGFloat) -> Font { .custom("Cyberpunk-Regular", size: size) }
}

extension View {
    /// Uppercase label style: condensed, tracked.
    func cpLabel(_ size: CGFloat = 12, _ color: Color = Theme.red) -> some View {
        self.font(.cpHead(size)).kerning(1.6).textCase(.uppercase).foregroundStyle(color)
    }
}

/// A rectangle with chamfered corners (the game's panel and button shape).
struct Chamfer: InsettableShape {
    var cut: CGFloat = 10
    var corners: [Corner] = [.topLeft, .bottomRight]
    var inset: CGFloat = 0
    enum Corner { case topLeft, topRight, bottomRight, bottomLeft }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let c = min(cut, r.width / 3, r.height / 3)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + (corners.contains(.topLeft) ? c : 0), y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - (corners.contains(.topRight) ? c : 0), y: r.minY))
        if corners.contains(.topRight) { p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c)) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - (corners.contains(.bottomRight) ? c : 0)))
        if corners.contains(.bottomRight) { p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY)) }
        p.addLine(to: CGPoint(x: r.minX + (corners.contains(.bottomLeft) ? c : 0), y: r.maxY))
        if corners.contains(.bottomLeft) { p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c)) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + (corners.contains(.topLeft) ? c : 0)))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> Chamfer { var s = self; s.inset += amount; return s }
}

/// A framed panel with an optional title strip ("■ TITLE ──────── CODE"), corner brackets and a hatched corner.
struct Panel<Content: View>: View {
    var title: String? = nil
    var code: String? = nil
    var tint: Color = Theme.red
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || code != nil {
                HStack(spacing: 8) {
                    Rectangle().fill(tint).frame(width: 6, height: 6)
                    if let title { Text(title).cpLabel(12, tint).lineLimit(1).fixedSize() }
                    Rectangle().fill(LinearGradient(colors: [tint.opacity(0.4), tint.opacity(0.08)], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 1)
                    if let code { Text(code).font(.cpMono(9)).foregroundStyle(tint.opacity(0.65)).lineLimit(1).fixedSize() }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topTrailing) {
                Chamfer(cut: 12).fill(LinearGradient(colors: [Theme.surfaceHi.opacity(0.95), Theme.surface.opacity(0.92)],
                                                     startPoint: .top, endPoint: .bottom))
                HazardStripes(color: tint.opacity(0.07), spacing: 7, width: 1.5)
                    .frame(width: 70, height: 26).padding(.top, 8).padding(.trailing, 14)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
            }
        }
        .overlay(Chamfer(cut: 12).strokeBorder(tint.opacity(0.4), lineWidth: 1))
        .overlay(CornerTicks(length: 9).stroke(tint, lineWidth: 2).padding(-3))
        .overlay(alignment: .topLeading) { Rectangle().fill(tint).frame(width: 30, height: 3).offset(x: 14, y: -1) }
        .cpAppear()
    }
}

// MARK: - Controls

/// The big yellow action. Hover splits it into red/cyan ghosts and lifts it; pressing punches it in.
struct CPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PrimaryBody(configuration: configuration) }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @LocalState private var hover = false

        var body: some View {
            let shape = Chamfer(cut: 12)
            let hot = enabled && hover
            configuration.label
                .font(.cpDisplay(21)).kerning(3).textCase(.uppercase)
                .foregroundStyle(enabled ? Theme.accentText : Theme.textDim)
                .padding(.horizontal, 34).padding(.vertical, 12)
                .background {
                    ZStack {
                        shape.fill(Theme.cyan).offset(x: hot ? -4 : 0, y: hot ? 2 : 0).opacity(hot ? 0.9 : 0)
                        shape.fill(Theme.red).offset(x: hot ? 4 : 0, y: hot ? -2 : 0).opacity(hot ? 0.9 : 0)
                        shape.fill(enabled ? Theme.accent : Theme.surfaceHi)
                        if enabled {
                            HazardStripes(color: .black.opacity(0.13), spacing: 9, width: 3)
                                .frame(width: 34).frame(maxWidth: .infinity, alignment: .trailing)
                                .clipShape(shape)
                        }
                    }
                }
                .overlay(shape.strokeBorder(enabled ? Theme.accent : Theme.redDim, lineWidth: 1))
                .shadow(color: Theme.accent.opacity(hot ? 0.45 : 0), radius: 16)
                .scaleEffect(configuration.isPressed && enabled ? 0.95 : hot ? 1.03 : 1)
                .brightness(configuration.isPressed && enabled ? -0.12 : 0)
                .animation(Motion.quick, value: configuration.isPressed)
                .onHover { h in withAnimation(Motion.snappy) { hover = h } }
        }
    }
}

/// The outlined secondary button: hover sweeps a tinted fill in from the left.
struct CPButtonStyle: ButtonStyle {
    var tint: Color = Theme.cyan
    func makeBody(configuration: Configuration) -> some View { OutlineBody(configuration: configuration, tint: tint) }

    private struct OutlineBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        @LocalState private var hover = false

        var body: some View {
            let shape = Chamfer(cut: 6)
            let hot = enabled && hover
            configuration.label
                .font(.cpHead(12)).kerning(1.2).textCase(.uppercase)
                .lineLimit(1)
                .foregroundStyle(enabled ? (hot ? Theme.background : tint) : Theme.textDim)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background {
                    ZStack {
                        shape.fill(tint.opacity(0.08))
                        shape.fill(tint).scaleEffect(x: hot ? 1 : 0.001, anchor: .leading)
                    }
                }
                .overlay(shape.strokeBorder(enabled ? tint.opacity(hot ? 1 : 0.7) : Theme.redDim, lineWidth: 1))
                .shadow(color: tint.opacity(hot ? 0.35 : 0), radius: 8)
                .scaleEffect(configuration.isPressed && enabled ? 0.96 : 1)
                .contentShape(Rectangle())
                .animation(Motion.quick, value: configuration.isPressed)
                .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hover = h } }
        }
    }
}

/// An angular on/off switch: a glowing cyan block on the right when on, dim red when off.
struct CPToggle: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var enabled
    @LocalState private var hover = false
    var body: some View {
        Button { withAnimation(Motion.snappy) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Chamfer(cut: 4).fill(isOn ? Theme.cyanDim : Theme.surfaceHi)
                if isOn { HazardStripes(color: Theme.cyan.opacity(0.18), spacing: 5, width: 1).clipShape(Chamfer(cut: 4)) }
                Chamfer(cut: 4).strokeBorder(isOn ? Theme.cyan : Theme.red.opacity(hover ? 0.7 : 0.35), lineWidth: 1)
                Chamfer(cut: 3).fill(isOn ? Theme.cyan : Theme.red.opacity(0.55))
                    .frame(width: 16, height: 12).padding(3)
                    .shadow(color: Theme.cyan.opacity(isOn ? 0.8 : 0), radius: 5)
            }
            .frame(width: 40, height: 18)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(hover && enabled ? 1.06 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
        .accessibilityLabel(isOn ? "On" : "Off")
    }
}

/// A row of angular segments; the filled highlight slides to the selected one.
struct CPSegmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var tint: Color = Theme.cyan
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, label in
                let selected = value == selection
                Button { withAnimation(Motion.snappy) { selection = value } } label: {
                    Text(label).font(.cpHead(12)).kerning(1.2).textCase(.uppercase).lineLimit(1).fixedSize()
                        .foregroundStyle(selected ? Theme.background : tint.opacity(0.8))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background {
                            Chamfer(cut: 5).fill(tint.opacity(0.06))
                            if selected { Chamfer(cut: 5).fill(tint).matchedGeometryEffect(id: "sel", in: ns) }
                        }
                        .overlay(Chamfer(cut: 5).strokeBorder(tint.opacity(selected ? 1 : 0.35), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverWash(tint)
            }
        }
    }
}

struct CPSearchField: View {
    @Binding var text: String
    var prompt: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.cyan.opacity(focused ? 1 : 0.7))
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textDim))
                .textFieldStyle(.plain).font(.cp(13, .medium)).foregroundStyle(Theme.text)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Chamfer(cut: 6).fill(Theme.surface))
        .overlay(Chamfer(cut: 6).strokeBorder(Theme.cyan.opacity(focused ? 0.9 : 0.35), lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            Rectangle().fill(Theme.cyan).frame(height: 2).scaleEffect(x: focused ? 1 : 0, anchor: .leading).padding(.horizontal, 6)
        }
        .shadow(color: Theme.cyan.opacity(focused ? 0.25 : 0), radius: 8)
        .animation(Motion.quick, value: focused)
    }
}

// MARK: - Small pieces

extension Verdict.Level {
    var label: String {
        switch self {
        case .works: return "Works"
        case .partial: return "Partial"
        case .needsFramework: return "Needs a framework"
        case .incompatible: return "Won't work"
        }
    }
    var color: Color {
        switch self {
        case .works: return Theme.good
        case .partial, .needsFramework: return Theme.warn
        case .incompatible: return Theme.bad
        }
    }
    var symbol: String {
        switch self {
        case .works: return "checkmark.diamond.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .needsFramework: return "puzzlepiece.extension.fill"
        case .incompatible: return "xmark.octagon.fill"
        }
    }
}

struct VerdictBadge: View {
    let level: Verdict.Level
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.symbol).font(.system(size: compact ? 10 : 12))
            if !compact { Text(level.label).cpLabel(11, level.color) }
        }
        .foregroundStyle(level.color)
        .help(level.label)
    }
}

struct KindBadge: View {
    let kind: ModKind
    var body: some View {
        Text(kind.short)
            .font(.cpHead(10)).kerning(1).textCase(.uppercase)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(kind.color.opacity(0.9))
            .overlay(Chamfer(cut: 3).strokeBorder(kind.color.opacity(0.45), lineWidth: 1))
            .fixedSize()
    }
}

extension ModKind {
    var short: String {
        switch self {
        case .archive: return "Archive"
        case .archiveExtension: return "XL"
        case .contentArchive: return "Content"
        case .redscript: return "Reds"
        case .tweak: return "Tweak"
        case .cet: return "CET"
        case .input: return "Input"
        case .audio: return "Audio"
        case .plugin: return "Plugin"
        case .other: return "Other"
        }
    }
    var color: Color {
        switch self {
        case .cet: return Theme.accent
        case .redscript: return Theme.red
        case .tweak: return Color(red: 0.75, green: 0.55, blue: 1.0)
        case .archive, .archiveExtension: return Theme.cyan
        case .contentArchive: return Color(red: 0.55, green: 0.80, blue: 1.0)
        case .audio: return Theme.good
        case .input: return Theme.warn
        default: return Theme.textDim
        }
    }
}

struct StatusDot: View {
    let ok: Bool?
    var body: some View {
        let color = ok == nil ? Theme.textDim : ok! ? Theme.good : Theme.bad
        Rectangle().fill(color)
            .frame(width: 7, height: 7).rotationEffect(.degrees(45))
            .shadow(color: color.opacity(ok == nil ? 0 : 0.8), radius: 4)
            .animation(Motion.quick, value: ok)
    }
}

struct Toast: View {
    let text: String
    var body: some View {
        Text(text).font(.cp(13, .semibold)).foregroundStyle(Theme.text)
            .padding(.leading, 22).padding(.trailing, 16).padding(.vertical, 9)
            .background(Chamfer(cut: 8).fill(Theme.surfaceHi))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.cyan).frame(width: 4).padding(.vertical, 6).padding(.leading, 8) }
            .overlay(Chamfer(cut: 8).strokeBorder(Theme.cyan.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
    }
}

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// View-local state without the `@State` macro: the macOS 26 SDK implements `@State` as a macro whose plugin ships
/// with Xcode only, and this package builds with the Command Line Tools.
final class StateBox<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

@propertyWrapper
struct LocalState<T>: DynamicProperty {
    @StateObject private var box: StateBox<T>
    init(wrappedValue: T) { _box = StateObject(wrappedValue: StateBox(wrappedValue)) }
    var wrappedValue: T {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    var projectedValue: Binding<T> { Binding(get: { box.value }, set: { box.value = $0 }) }
}
