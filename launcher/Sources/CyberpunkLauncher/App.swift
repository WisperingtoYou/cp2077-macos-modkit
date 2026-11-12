import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct CyberpunkLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() {
        // The title fonts make-app.sh bundles (titles fall back to the system font without them, e.g. in `swift run`).
        for (name, ext) in [("ChakraPetch", "ttc"), ("Cyberpunk-Regular", "ttf")] {
            if let font = Bundle.main.url(forResource: name, withExtension: ext) {
                CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Cyberpunk 2077") {
            RootView()
                .environmentObject(model)
                .onAppear { Snapshots.runIfRequested(model) }
                .frame(minWidth: 720, minHeight: 500)
                .preferredColorScheme(.dark)
                .tint(Theme.cyan)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Mods…") { model.pickMods() }.keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                ForEach(Array(Section.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.rawValue) { model.section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Button("Refresh") { model.refresh(); model.checkHealth() }.keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Debug: LAUNCHER_SNAPSHOT=<folder> renders the window for each section to PNG files and quits.
/// LAUNCHER_SNAPSHOT_SIZES="1180x760,820x560" repeats it per window size; LAUNCHER_SNAPSHOT_ADD=<archive>[:…] shows
/// the install sheet for archives instead (cancelled afterwards: nothing is installed); LAUNCHER_SNAPSHOT_SELECT=<text>
/// selects the mods whose name contains it on the Mods page. LAUNCHER_SNAPSHOT_PLAY=1 presses Play (the saved mode) and
/// shoots the launch states every 2 s until the game is running, then once more after the game exits.
@MainActor
enum Snapshots {
    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["LAUNCHER_SNAPSHOT"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            func shoot(_ name: String) {
                for (i, window) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
                    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(i == 0 ? "" : "-\(i)").png"))
                }
            }
            if env["LAUNCHER_SNAPSHOT_PLAY"] == "1" {
                model.section = .play
                model.play()
                for n in 0..<60 {
                    try? await Task.sleep(for: .seconds(2))
                    shoot("Launch-\(n)")
                    if case .failed = model.phase { break }
                    if model.phase == .running { break }
                }
                while model.phase == .running || model.phase == .compiling { try? await Task.sleep(for: .seconds(2)) }
                try? await Task.sleep(for: .seconds(1))
                shoot("Launch-after")
            } else if let add = env["LAUNCHER_SNAPSHOT_ADD"] {
                model.addMods(add.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
                for n in 0..<8 {
                    try? await Task.sleep(for: .seconds(3))
                    guard let plan = model.installQueue.first else { if model.preparing == 0 { break } else { continue } }
                    shoot("Install-\(n)")
                    model.cancelInstall(plan)
                }
            } else {
                let sizes = (env["LAUNCHER_SNAPSHOT_SIZES"] ?? "").split(separator: ",").compactMap { s -> CGSize? in
                    let p = s.split(separator: "x").compactMap { Double($0) }
                    return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
                }
                for size in sizes.isEmpty ? [nil] : sizes.map(Optional.some) {
                    if let size, let w = NSApp.windows.first(where: { $0.isVisible }) {
                        w.setContentSize(size)
                        try? await Task.sleep(for: .seconds(0.8))
                    }
                    let tag = size.map { "-\(Int($0.width))x\(Int($0.height))" } ?? ""
                    for section in Section.allCases {
                        model.section = section
                        try? await Task.sleep(for: .seconds(1.0))
                        shoot(section.rawValue + tag)
                    }
                }
            }
            NSApp.terminate(nil)
        }
    }
}

extension AppModel {
    func pickMods() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .archive, UTType(filenameExtension: "7z") ?? .archive,
                                     UTType(filenameExtension: "rar") ?? .archive, .folder]
        panel.prompt = "Add"
        if panel.runModal() == .OK { addMods(panel.urls) }
    }
}

// MARK: - Shell

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var dropTargeted = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 900
            HStack(spacing: 0) {
                Sidebar(compact: compact)
                    .frame(width: compact ? 64 : 220)
                LinearGradient(colors: [Theme.red.opacity(0.1), Theme.red.opacity(0.5), Theme.red.opacity(0.1)], startPoint: .top, endPoint: .bottom)
                    .frame(width: 1)
                ZStack {
                    Group {
                        switch model.section {
                        case .play: PlayView()
                        case .mods: ModsView()
                        case .frameworks: FrameworksView()
                        case .looks: LooksView()
                        case .profiles: ProfilesView()
                        }
                    }
                    .id(model.section)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
                    GlitchFlash(trigger: model.section)
                }
                .animation(Motion.page, value: model.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(CPBackground())
        .environment(\.liveMotion, !model.gameRunning && activeState != .inactive && !reduceMotion)
        .foregroundStyle(Theme.text)
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Toast(text: t).padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(2.5)); withAnimation { model.toast = nil } }
            }
        }
        .overlay {
            if dropTargeted {
                Chamfer(cut: 18)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                    .background(Chamfer(cut: 18).fill(Theme.accent.opacity(0.06)))
                    .overlay(Text("Drop to install").cpLabel(20, Theme.accent))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let item = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                await MainActor.run { model.addMods(urls) }
            }
            return true
        }
        .sheet(item: Binding(get: { model.installQueue.first }, set: { _ in })) { plan in
            InstallSheet(plan: plan).environmentObject(model).id(plan.id)
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .animation(.easeOut(duration: 0.2), value: model.toast)
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    let compact: Bool
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, compact ? 0 : 18)
                .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
                .padding(.top, 40).padding(.bottom, 24)

            VStack(spacing: 2) {
                ForEach(Array(Section.allCases.enumerated()), id: \.element) { i, s in
                    SidebarItem(section: s, index: i, compact: compact, ns: ns)
                }
            }
            .animation(Motion.snappy, value: model.section)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 10) {
                if model.preparing > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        if !compact { Text("Reading \(model.preparing) archive(s)").font(.cp(11)).foregroundStyle(Theme.textDim) }
                    }
                }
                if !compact { status }
                if compact {
                    VStack(spacing: 12) {
                        Button { model.pickMods() } label: { Image(systemName: "plus.square") }.help("Add Mods (⌘O)")
                        Button { model.openLogs() } label: { Image(systemName: "doc.text.magnifyingglass") }.help("Logs")
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.cyan).frame(maxWidth: .infinity)
                } else {
                    Button { model.pickMods() } label: { Label("Add Mods", systemImage: "plus") }
                        .buttonStyle(CPButtonStyle(tint: Theme.accent))
                    HStack(spacing: 8) {
                        Button("Logs") { model.openLogs() }.buttonStyle(CPButtonStyle(tint: Theme.cyan))
                        Button("Game Folder") { model.openGameFolder() }.buttonStyle(CPButtonStyle(tint: Theme.cyan))
                    }
                }
            }
            .padding(compact ? 8 : 16)
        }
        .background {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Theme.background.opacity(0.95), Theme.surface.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                HazardStripes(color: Theme.accent.opacity(0.05), spacing: 9, width: 2).frame(height: 60)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
            }
        }
    }

    @ViewBuilder private var brand: some View {
        if compact {
            LogoTitle(text: "CP", size: 24, period: 6.3)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                GameLogo(height: 46)
                Text("MOD LAUNCHER // MAC").font(.cpMono(9)).foregroundStyle(Theme.red.opacity(0.85))
                HazardStripes(color: Theme.accent.opacity(0.7), spacing: 6, width: 2).frame(width: 64, height: 5).padding(.top, 4)
            }
        }
    }

    private var status: some View {
        let h = model.health
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("System").cpLabel(10, Theme.red.opacity(0.8))
                Rectangle().fill(Theme.red.opacity(0.25)).frame(height: 1)
            }
            HStack(spacing: 8) {
                StatusDot(ok: h.map { $0.steam == .online })
                Text(steamText(h?.steam)).font(.cp(12, .medium)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
            HStack(spacing: 8) {
                StatusDot(ok: h?.gameSupported)
                Text(h == nil ? "Checking the game" : h!.gameSupported ? "Game 2.3.1 supported" : "Game updated: modded off")
                    .font(.cp(12, .medium)).foregroundStyle(Theme.textDim).lineLimit(1)
            }
        }
        .padding(10)
        .background(Chamfer(cut: 8, corners: [.topRight]).fill(Theme.background.opacity(0.6)))
        .overlay(Chamfer(cut: 8, corners: [.topRight]).strokeBorder(Theme.red.opacity(0.2), lineWidth: 1))
    }

    private func steamText(_ s: Health.SteamState?) -> String {
        switch s {
        case .online: return "Steam online"
        case .offline: return "Steam offline"
        case .notRunning: return "Steam not running"
        case nil: return "Checking Steam"
        }
    }
}

struct SidebarItem: View {
    @EnvironmentObject var model: AppModel
    let section: Section
    let index: Int
    let compact: Bool
    let ns: Namespace.ID
    @LocalState private var hover = false

    var body: some View {
        let selected = model.section == section
        Button { model.section = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon).font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                if !compact {
                    Text(section.rawValue).font(.cpHead(15)).kerning(1.6).textCase(.uppercase)
                    Spacer()
                    if section == .mods {
                        Text("\(model.enabledCount)").font(.cpMono(10)).foregroundStyle(selected ? Theme.accent.opacity(0.8) : Theme.textDim)
                    } else {
                        Text(String(format: "0%d", index + 1)).font(.cpMono(9)).foregroundStyle(Theme.red.opacity(selected ? 0.9 : 0.5))
                    }
                }
            }
            .foregroundStyle(selected ? Theme.accent : hover ? Theme.text : Theme.text.opacity(0.7))
            .offset(x: hover && !selected && !compact ? 4 : 0)
            .padding(.vertical, 8).padding(.leading, compact ? 0 : 16).padding(.trailing, compact ? 0 : 14)
            .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
            .background {
                if selected {
                    ZStack(alignment: .leading) {
                        LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0.02)], startPoint: .leading, endPoint: .trailing)
                        Rectangle().fill(Theme.accent).frame(width: 3)
                            .shadow(color: Theme.accent.opacity(0.8), radius: 6)
                    }
                    .matchedGeometryEffect(id: "selection", in: ns)
                } else if hover {
                    LinearGradient(colors: [Theme.cyan.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.rawValue)
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }
}
