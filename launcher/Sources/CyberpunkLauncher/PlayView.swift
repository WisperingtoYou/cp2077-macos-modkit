import LauncherCore
import SwiftUI

struct PlayView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var showOutput = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { preflight; summary }
                    VStack(alignment: .leading, spacing: 16) { preflight; summary }
                }
                if !model.compileProblems.isEmpty { problems }
                if !model.launchOutput.isEmpty { output }
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 28)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                CityscapeArt()
                ScanSweep(period: 4.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SYS.LAUNCH // 1091500 // BUILD 2.3.1").font(.cpMono(10)).foregroundStyle(Theme.cyan.opacity(0.85))
                    GameLogo(height: 120)
                    Text(model.playMode == .modded
                         ? "\(model.enabledCount) mods on, with RED4ext, CET, Codeware, TweakXL, ArchiveXL and friends"
                         : "Vanilla scripts and the Mac content archives only, started by Steam")
                        .font(.cp(14, .medium)).foregroundStyle(Theme.text.opacity(0.75))
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 26).padding(.bottom, 22)
            }
            .frame(height: 260)
            .clipShape(Chamfer(cut: 22))
            .overlay(Chamfer(cut: 22).strokeBorder(Theme.red.opacity(0.5), lineWidth: 1))
            .overlay(CornerTicks(length: 14).stroke(Theme.accent, lineWidth: 2).padding(-4))
            .overlay(alignment: .topLeading) {
                Text(model.gameRunning ? "● LIVE" : "STANDBY").font(.cpMono(9)).kerning(1)
                    .foregroundStyle(model.gameRunning ? Theme.background : Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Chamfer(cut: 4, corners: [.bottomRight]).fill(model.gameRunning ? Theme.good : Theme.background.opacity(0.7)))
                    .padding(.leading, 26).padding(.top, 14)
            }
            .cpAppear()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { controls }
                VStack(alignment: .leading, spacing: 12) { controls }
            }
            .cpAppear(0.05)
            LaunchTrack(phase: model.phase, modded: model.playMode == .modded)
                .cpAppear(0.1)
            phaseLine
        }
        .animation(Motion.snappy, value: model.phase)
        .animation(Motion.quick, value: model.playMode)
    }

    @ViewBuilder private var controls: some View {
        ModeSwitch(mode: $model.playMode)
            .disabled(model.gameRunning)
        HStack(spacing: 14) {
            Button(action: model.play) {
                HStack(spacing: 10) {
                    Image(systemName: playIcon)
                    Text(playTitle)
                }
            }
            .buttonStyle(CPPrimaryButtonStyle())
            .disabled(!canPlay)
            .keyboardShortcut(.return, modifiers: .command)
            .contentTransition(.opacity)

            if case .running = model.phase, model.playMode == .modded {
                Button("Quit Game") { model.stopGame() }.buttonStyle(CPButtonStyle(tint: Theme.bad))
            }
        }
    }

    private var canPlay: Bool {
        guard let h = model.health, model.phase != .compiling, model.phase != .starting else { return false }
        return model.playMode == .modded ? h.canPlayModded : h.canPlayVanilla
    }
    private var playTitle: String {
        switch model.phase {
        case .compiling: return "Compiling…"
        case .starting: return "Starting…"
        case .running: return "Running"
        default: return "Play"
        }
    }
    private var playIcon: String { model.phase == .running ? "gamecontroller.fill" : "play.fill" }

    @ViewBuilder private var phaseLine: some View {
        switch model.phase {
        case .failed(let why):
            Label(why, systemImage: "xmark.octagon.fill").font(.cp(13, .semibold)).foregroundStyle(Theme.bad)
                .transition(.opacity.combined(with: .offset(y: -6)))
        case .exited(let code):
            let clean = code == 0 || code == 143
            Label(clean ? "The game closed." : "The game closed with exit code \(code). The logs are one click away (sidebar).",
                  systemImage: clean ? "checkmark.diamond" : "exclamationmark.triangle")
                .font(.cp(13, .semibold)).foregroundStyle(clean ? Theme.textDim : Theme.warn)
                .transition(.opacity.combined(with: .offset(y: -6)))
        default: EmptyView()
        }
    }

    // MARK: pre-flight

    private var preflight: some View {
        Panel(title: "Ready to play", code: "CHK-01") {
            VStack(alignment: .leading, spacing: 10) {
                if let h = model.health {
                    check(h.steam == .online, "Steam", h.steam == .online ? "signed in and online"
                          : h.steam == .offline ? "open but offline: use Steam > Go Online, or restart Steam" : "not running: start Steam first")
                    check(h.gameSupported, "Game build", h.gameSupported ? "supported by the installed frameworks"
                          : "updated by Steam; modded play waits for updated frameworks (vanilla still works)")
                    if model.playMode == .modded {
                        check(h.refusedPlugins.isEmpty, "Frameworks",
                              h.refusedPlugins.isEmpty ? "all plugins pass the address check" : "refused: \(h.refusedPlugins.joined(separator: ", "))")
                    }
                    if h.gameRunning { check(false, "Game", "already running") }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(minWidth: 280)
    }

    private func check(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(ok: ok).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).cpLabel(12, ok ? Theme.text : Theme.warn)
                Text(detail).font(.cp(12, .regular)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: summary

    private var summary: some View {
        Panel(title: "Setup", code: "CFG-02", tint: Theme.cyan) {
            VStack(alignment: .leading, spacing: 4) {
                row("square.stack.3d.up", "\(model.enabledCount) of \(model.mods.count) mods on") { model.section = .mods }
                if model.issueCount > 0 {
                    row("exclamationmark.triangle", "\(model.issueCount) with compatibility notes") { model.section = .mods }
                }
                row("camera.filters", "LUT: \(model.activeLUT.map { $0 == "off" ? "off" : LooksView.pretty($0) } ?? "custom")") { model.section = .looks }
                row("cpu", "\(model.frameworks.filter { $0.enabled && $0.hasMacBinary }.count) frameworks on") { model.section = .frameworks }
            }
        }
        .frame(minWidth: 280)
    }

    private func row(_ icon: String, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.cyan)
                Text(text).font(.cp(14, .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.cyan.opacity(0.7))
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .hoverWash()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
    }

    // MARK: problems

    private var problems: some View {
        Panel(title: "Script compile failed", code: "ERR-REDS", tint: Theme.bad) {
            VStack(alignment: .leading, spacing: 12) {
                Text("These mods stopped the scripts from compiling").font(.cp(14, .semibold)).foregroundStyle(Theme.bad)
                let byMod = Dictionary(grouping: model.compileProblems, by: { $0.modId ?? $0.modName })
                ForEach(byMod.keys.sorted(), id: \.self) { key in
                    let items = byMod[key]!
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(items[0].modName).font(.cp(14, .bold))
                            ForEach(items.prefix(3)) { p in
                                Text("\(p.file)\n\(p.message)").font(.cpMono(10)).foregroundStyle(Theme.textDim)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        if let id = items[0].modId, let mod = model.mods.first(where: { $0.id == id }) {
                            Button("Turn Off") { model.setEnabled(mod, false) }.buttonStyle(CPButtonStyle(tint: Theme.bad))
                        }
                    }
                }
                Text("Turn the mod off and press Play again, or update it.").font(.cp(12)).foregroundStyle(Theme.textDim)
            }
        }
    }

    // MARK: output

    private var output: some View {
        Panel(title: "Launch output", code: "\(model.launchOutput.count) LINES · \(showOutput ? "HIDE" : "SHOW")", tint: Theme.cyan) {
            if showOutput {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.launchOutput.suffix(200).joined(separator: "\n"))
                            .font(.cpMono(10)).foregroundStyle(Theme.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("bottom")
                    }
                    .frame(height: 220)
                    .onChange(of: model.launchOutput.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showOutput.toggle() }
    }
}

/// Modded / Vanilla switch: black on the signal yellow when selected; the yellow block slides between them.
struct ModeSwitch: View {
    @Binding var mode: PlayMode
    @Environment(\.isEnabled) private var enabled
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PlayMode.allCases) { m in
                let selected = m == mode
                Button { withAnimation(Motion.snappy) { mode = m } } label: {
                    Text(m.rawValue)
                        .font(.cpHead(14)).kerning(1.6).textCase(.uppercase)
                        .frame(width: 100, height: 38)
                        .foregroundStyle(selected ? Theme.accentText : Theme.accent.opacity(0.75))
                        .background {
                            Chamfer(cut: 7).fill(Theme.accent.opacity(0.05))
                            if selected { Chamfer(cut: 7).fill(Theme.accent).matchedGeometryEffect(id: "mode", in: ns) }
                        }
                        .overlay(Chamfer(cut: 7).strokeBorder(Theme.accent.opacity(selected ? 1 : 0.35), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverWash(Theme.accent)
            }
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

/// The launch pipeline: each stage lights up as the launch moves through it (crawling stripes while active).
struct LaunchTrack: View {
    let phase: LaunchPhase
    let modded: Bool

    private enum StageState { case waiting, active, done, failed }

    private var stages: [(code: String, title: String, detail: String)] {
        modded
            ? [("01", "Compile", "redscript + plugin scripts"), ("02", "Inject", "RED4ext and frameworks"), ("03", "Live", "in Night City")]
            : [("01", "Hand off", "Steam starts the game"), ("02", "Live", "in Night City")]
    }

    /// Index of the stage the launch is at, and whether it is still working on it.
    private func state(_ i: Int) -> StageState {
        let last = stages.count - 1
        switch phase {
        case .idle, .exited: return .waiting
        case .compiling, .starting: return i == 0 ? .active : .waiting
        case .running: return i < last ? .done : .active
        case .failed: return i == 0 ? .failed : .waiting
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, stage in
                if i > 0 {
                    Rectangle().fill(state(i) == .waiting ? Theme.red.opacity(0.25) : Theme.cyan.opacity(0.8))
                        .frame(width: 18, height: 1)
                }
                cell(stage, state(i))
            }
        }
    }

    private func cell(_ stage: (code: String, title: String, detail: String), _ st: StageState) -> some View {
        let tint: Color = switch st {
        case .waiting: Theme.textDim
        case .active: Theme.accent
        case .done: Theme.cyan
        case .failed: Theme.bad
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(stage.code).font(.cpMono(9)).foregroundStyle(tint.opacity(0.8))
                Text(stage.title).cpLabel(12, st == .waiting ? Theme.text.opacity(0.5) : tint)
                Spacer(minLength: 0)
                Image(systemName: st == .done ? "checkmark" : st == .failed ? "xmark" : st == .active ? "dot.radiowaves.right" : "circle.dotted")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(stage.detail).font(.cp(11)).foregroundStyle(Theme.textDim).lineLimit(1)
            ZStack {
                Rectangle().fill(tint.opacity(st == .waiting ? 0.12 : 0.25))
                if st == .active { MovingStripes(color: Theme.accent.opacity(0.9)).transition(.opacity) }
                if st == .done || st == .failed { Rectangle().fill(tint).transition(.scale(scale: 0, anchor: .leading)) }
            }
            .frame(height: 4).clipped()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minWidth: 150, maxWidth: 230)
        .background(Chamfer(cut: 7).fill(st == .active ? Theme.accent.opacity(0.07) : Theme.surface.opacity(0.7)))
        .overlay(Chamfer(cut: 7).strokeBorder(tint.opacity(st == .waiting ? 0.2 : 0.7), lineWidth: 1))
        .shadow(color: st == .active ? Theme.accent.opacity(0.25) : .clear, radius: 10)
    }
}
