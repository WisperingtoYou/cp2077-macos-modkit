import AppKit
import LauncherCore
import SwiftUI

enum ModFilter: String, CaseIterable, Identifiable {
    case all = "All", on = "On", off = "Off", issues = "Notes"
    var id: String { rawValue }
}

/// The category bar. A mod shows under every category it touches; in Everything it is listed once, under its
/// primary category (the first one it has, in this order).
enum ModCategory: String, CaseIterable, Identifiable {
    case everything = "Everything", cet = "CET", redscript = "Redscript", tweak = "TweakXL", archive = "Archive",
         content = "Content", audio = "Audio", input = "Input", other = "Other"
    var id: String { rawValue }

    var kinds: Set<ModKind> {
        switch self {
        case .everything: return Set(ModKind.allCases)
        case .cet: return [.cet]
        case .redscript: return [.redscript]
        case .tweak: return [.tweak]
        case .archive: return [.archive, .archiveExtension]
        case .content: return [.contentArchive]
        case .audio: return [.audio]
        case .input: return [.input]
        case .other: return [.plugin, .other]
        }
    }
    var color: Color {
        switch self {
        case .everything: return Theme.text
        case .archive: return ModKind.archive.color
        case .other: return Theme.textDim
        default: return kinds.first!.color
        }
    }
    var subtitle: String {
        switch self {
        case .everything: return ""
        case .cet: return "Lua mods · bin/x64/plugins/cyber_engine_tweaks"
        case .redscript: return "Scripts · r6/scripts"
        case .tweak: return "Game data · r6/tweaks"
        case .archive: return "ArchiveXL · archive/pc/mod"
        case .content: return "Mac content · archive/Mac/content"
        case .audio: return "Audioware · r6/audioware"
        case .input: return "Key bindings · r6/input"
        case .other: return "Plugins and other files"
        }
    }
    func covers(_ mod: Mod) -> Bool { mod.kinds.contains(where: kinds.contains) }
    static let sections: [ModCategory] = allCases.filter { $0 != .everything }

    static func primary(of mod: Mod) -> ModCategory {
        sections.first { $0.covers(mod) } ?? .other
    }
}

struct ModsView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var search = ""
    @LocalState private var filter: ModFilter = .all
    @LocalState private var category: ModCategory = .everything
    @LocalState private var selection = Set<String>()
    @LocalState private var anchor: String?
    @Namespace private var tabNS

    private func matches(_ m: Mod) -> Bool {
        let q = search.lowercased()
        guard q.isEmpty || m.name.lowercased().contains(q) || m.files.contains(where: { $0.lowercased().contains(q) }) else { return false }
        switch filter {
        case .all: return true
        case .on: return m.enabled
        case .off: return !m.enabled
        case .issues: return (m.verdict?.level ?? .works) > .works
        }
    }

    /// The visible mods, grouped: one group per primary category in Everything, a single group otherwise.
    private var groups: [(ModCategory, [Mod])] {
        let shown = model.mods.filter(matches)
        if category == .everything {
            let by = Dictionary(grouping: shown, by: ModCategory.primary)
            return ModCategory.sections.compactMap { c in by[c].map { (c, $0) } }
        }
        return [(category, shown.filter { category.covers($0) })]
    }
    private var visibleIds: [String] { groups.flatMap { $0.1.map(\.id) } }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 780
            let selected = model.mods.filter { selection.contains($0.id) }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    categoryBar
                    list
                }
                .frame(maxWidth: .infinity)
                if wide {
                    Rectangle().fill(Theme.red.opacity(0.25)).frame(width: 1)
                    inspector(selected)
                        .frame(width: min(380, max(300, geo.size.width * 0.34)))
                        .background(Theme.background.opacity(0.6))
                }
            }
            .overlay(alignment: .trailing) {
                if !wide && !selected.isEmpty {
                    inspector(selected)
                        .frame(width: min(360, geo.size.width - 40))
                        .frame(maxHeight: .infinity)
                        .background(Theme.surface)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.cyan.opacity(0.6)).frame(width: 1) }
                        .shadow(color: .black.opacity(0.7), radius: 18, x: -6)
                        .overlay(alignment: .topTrailing) {
                            Button { selection = [] } label: { Image(systemName: "xmark") }
                                .buttonStyle(CPButtonStyle(tint: Theme.cyan)).padding(12)
                                .keyboardShortcut(.cancelAction)
                        }
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.18), value: wide ? 0 : selection.count.signum())
        }
        .onChange(of: model.mods.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .onAppear {
            if let q = ProcessInfo.processInfo.environment["LAUNCHER_SNAPSHOT_SELECT"]?.lowercased() {
                selection = Set(model.mods.filter { $0.name.lowercased().contains(q) }.map(\.id))
            }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                LogoTitle(text: "Mods", size: 52, color: Theme.red, period: 5.1)
                Text("\(model.enabledCount)/\(model.mods.count) ON").font(.cpMono(11)).foregroundStyle(Theme.cyan.opacity(0.8))
                    .contentTransition(.numericText())
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    CPSearchField(text: $search, prompt: "Search mods and files").frame(minWidth: 180, maxWidth: 300)
                    Spacer(minLength: 0)
                    CPSegmented(options: ModFilter.allCases.map { ($0, $0.rawValue) }, selection: $filter)
                }
                VStack(alignment: .leading, spacing: 8) {
                    CPSearchField(text: $search, prompt: "Search mods and files")
                    CPSegmented(options: ModFilter.allCases.map { ($0, $0.rawValue) }, selection: $filter)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 10)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(ModCategory.allCases) { c in
                    let count = c == .everything ? model.mods.count : model.mods.filter { c.covers($0) }.count
                    if c == .everything || count > 0 { tab(c, count: count) }
                }
            }
            .padding(.horizontal, 12).padding(.trailing, 24)
        }
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28).allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.red.opacity(0.3)).frame(height: 1) }
    }

    private func tab(_ c: ModCategory, count: Int) -> some View {
        let selected = category == c
        return Button { withAnimation(Motion.snappy) { category = c } } label: {
            HStack(spacing: 5) {
                Text(c.rawValue).font(.cpHead(13)).kerning(1.3).textCase(.uppercase)
                Text("\(count)").font(.cpMono(10)).opacity(0.7)
            }
            .foregroundStyle(selected ? c.color : Theme.textDim)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(alignment: .bottom) {
                if selected {
                    LinearGradient(colors: [c.color.opacity(0), c.color.opacity(0.14)], startPoint: .top, endPoint: .bottom)
                        .overlay(alignment: .bottom) { Rectangle().fill(c.color).frame(height: 2).shadow(color: c.color, radius: 4) }
                        .matchedGeometryEffect(id: "tab", in: tabNS)
                }
            }
            .contentShape(Rectangle())
            .hoverWash(c.color)
        }
        .buttonStyle(.plain)
    }

    // MARK: list

    private var list: some View {
        let groups = self.groups
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.0) { cat, mods in
                    SwiftUI.Section {
                        ForEach(mods) { mod in
                            ModRow(mod: mod, selected: selection.contains(mod.id))
                                .onTapGesture { click(mod.id) }
                                .contextMenu { contextMenu(mod) }
                        }
                    } header: {
                        sectionHeader(cat, mods: mods)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .overlay {
            if model.mods.isEmpty && model.refreshing { ProgressView("Reading the game folder…") }
            else if groups.allSatisfy({ $0.1.isEmpty }) { Text("No mods match").cpLabel(14, Theme.textDim) }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            let mods = model.mods.filter { selection.contains($0.id) }
            guard !mods.isEmpty else { return .ignored }
            model.setEnabled(mods.map(\.id), !mods.allSatisfy(\.enabled))
            return .handled
        }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.escape) { guard !selection.isEmpty else { return .ignored }; selection = []; return .handled }
    }

    private func sectionHeader(_ cat: ModCategory, mods: [Mod]) -> some View {
        let on = mods.filter(\.enabled).count
        return HStack(spacing: 10) {
            Rectangle().fill(cat.color).frame(width: 3, height: 14)
            Text(cat.rawValue).cpLabel(13, cat.color)
            Text(cat.subtitle).font(.cpMono(9)).foregroundStyle(Theme.textDim).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(on)/\(mods.count)").font(.cpMono(10)).foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 20).padding(.vertical, 7)
        .background(Theme.background.opacity(0.96))
        .overlay(alignment: .bottom) { Rectangle().fill(cat.color.opacity(0.18)).frame(height: 1) }
    }

    /// Click selects one; ⌘-click adds or removes; ⇧-click selects the range from the last click.
    private func click(_ id: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let a = anchor, let i = visibleIds.firstIndex(of: a), let j = visibleIds.firstIndex(of: id) {
            selection = Set(visibleIds[min(i, j)...max(i, j)])
        } else {
            selection = selection == [id] ? [] : [id]
            anchor = id
        }
    }

    private func step(_ by: Int) -> KeyPress.Result {
        let ids = visibleIds
        guard !ids.isEmpty else { return .ignored }
        let current = anchor.flatMap { ids.firstIndex(of: $0) } ?? (by > 0 ? -1 : ids.count)
        let next = ids[max(0, min(ids.count - 1, current + by))]
        selection = [next]; anchor = next
        return .handled
    }

    @ViewBuilder private func contextMenu(_ mod: Mod) -> some View {
        Button(mod.enabled ? "Turn Off" : "Turn On") { model.setEnabled(mod, !mod.enabled) }
        Button("Show in Finder") { model.reveal(mod) }
        if let id = mod.nexusId { Button("Open on Nexus") { model.openNexus(id) } }
        Divider()
        Button("Remove…", role: .destructive) { model.remove(mod) }
    }

    // MARK: inspector

    @ViewBuilder private func inspector(_ selected: [Mod]) -> some View {
        if selected.count == 1 {
            ModDetail(mod: selected[0])
        } else if selected.count > 1 {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(selected.count) selected").cpLabel(16, Theme.cyan)
                Text("\(selected.filter(\.enabled).count) on, \(selected.filter { !$0.enabled }.count) off")
                    .font(.cp(13)).foregroundStyle(Theme.textDim)
                HStack {
                    Button("Turn All On") { model.setEnabled(Array(selection), true) }.buttonStyle(CPButtonStyle(tint: Theme.cyan))
                    Button("Turn All Off") { model.setEnabled(Array(selection), false) }.buttonStyle(CPButtonStyle(tint: Theme.red))
                }
                .disabled(model.gameRunning)
                Text("Space toggles the selection · ⌘-click adds · ⇧-click selects a range").font(.cp(11)).foregroundStyle(Theme.textDim)
                Spacer()
            }
            .padding(20).padding(.top, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.cyan.opacity(0.6))
                Text("Select a mod").cpLabel(13, Theme.textDim)
                Text("or drop mod archives anywhere to install them").font(.cp(12)).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ModRow: View {
    @EnvironmentObject var model: AppModel
    let mod: Mod
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            CPToggle(isOn: Binding(get: { mod.enabled }, set: { model.setEnabled(mod, $0) }))
                .disabled(model.busyMods.contains(mod.id) || model.gameRunning)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mod.name).font(.cp(14, .semibold)).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(mod.enabled ? Theme.text : Theme.textDim)
                    if let v = mod.verdict, v.level > .works { VerdictBadge(level: v.level, compact: true) }
                }
                HStack(spacing: 4) { ForEach(mod.kinds, id: \.self) { KindBadge(kind: $0) } }
            }
            Spacer(minLength: 4)
            if model.busyMods.contains(mod.id) { ProgressView().controlSize(.mini) }
            if let v = mod.version { Text("v\(v)").font(.cpMono(9)).foregroundStyle(Theme.textDim).lineLimit(1) }
        }
        .padding(.horizontal, 20).padding(.vertical, 5)
        .background(selected ? LinearGradient(colors: [Theme.cyan.opacity(0.16), Theme.cyan.opacity(0.03)], startPoint: .leading, endPoint: .trailing) : nil)
        .hoverWash()
        .overlay(alignment: .leading) { Rectangle().fill(selected ? Theme.cyan : .clear).frame(width: 3).shadow(color: Theme.cyan, radius: selected ? 4 : 0) }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.red.opacity(0.06)).frame(height: 1).padding(.leading, 72) }
        .contentShape(Rectangle())
        .animation(Motion.quick, value: selected)
    }
}

struct ModDetail: View {
    @EnvironmentObject var model: AppModel
    let mod: Mod
    @LocalState private var name = ""
    @LocalState private var confirmRemove = false
    @LocalState private var showFiles = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ModCategory.primary(of: mod).rawValue).cpLabel(10, ModCategory.primary(of: mod).color)
                    TextField("Name", text: $name, onCommit: { if name != mod.name, !name.isEmpty { model.rename(mod, name) } })
                        .textFieldStyle(.plain).font(.cp(22, .bold)).foregroundStyle(Theme.text)
                    HStack(spacing: 8) {
                        if let v = mod.version { Text("v\(v)") }
                        if let id = mod.nexusId {
                            Button("NEXUS \(id)") { model.openNexus(id) }.buttonStyle(.plain).foregroundStyle(Theme.cyan)
                        }
                        Text(originText).lineLimit(2)
                    }
                    .font(.cpMono(10)).foregroundStyle(Theme.textDim)
                }
                .padding(.trailing, 36)

                HStack(spacing: 10) {
                    CPToggle(isOn: Binding(get: { mod.enabled }, set: { model.setEnabled(mod, $0) }))
                        .disabled(model.busyMods.contains(mod.id) || model.gameRunning)
                    Text(mod.enabled ? "Enabled" : "Disabled").cpLabel(13, mod.enabled ? Theme.cyan : Theme.textDim)
                }

                if let v = mod.verdict {
                    Panel(title: "Compatibility", tint: v.level.color) {
                        VStack(alignment: .leading, spacing: 8) {
                            VerdictBadge(level: v.level)
                            ForEach(v.notes, id: \.self) { Text($0).font(.cp(13, .regular)).fixedSize(horizontal: false, vertical: true) }
                            if !v.requires.isEmpty {
                                Text("Uses: " + v.requires.map(\.rawValue).joined(separator: ", "))
                                    .font(.cp(12)).foregroundStyle(Theme.textDim)
                            }
                            if !v.skippedFiles.isEmpty {
                                Text("Not installed (Windows-only): " + v.skippedFiles.joined(separator: ", "))
                                    .font(.cp(12)).foregroundStyle(Theme.textDim)
                            }
                        }
                    }
                }

                Panel(title: "\(mod.files.count) file\(mod.files.count == 1 ? "" : "s")", code: showFiles ? "HIDE" : "SHOW", tint: Theme.cyan) {
                    if showFiles {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(mod.files.prefix(300), id: \.self) { f in
                                Text(f).font(.cpMono(10)).foregroundStyle(Theme.textDim)
                                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            }
                            if mod.files.count > 300 { Text("…and \(mod.files.count - 300) more").font(.cp(11)) }
                        }
                    } else {
                        HStack(spacing: 4) { ForEach(mod.kinds, id: \.self) { KindBadge(kind: $0) } }
                    }
                }
                .onTapGesture { showFiles.toggle() }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
                .disabled(model.gameRunning)
            }
            .padding(20)
        }
        .onAppear { name = mod.name }
        .onChange(of: mod.id) { name = mod.name }
        .confirmationDialog("Remove \(mod.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove(mod) }
        } message: {
            Text("Its files move to the launcher's removed folder in the game folder (_mod_launcher/removed). Nothing is deleted.")
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Show in Finder") { model.reveal(mod) }.buttonStyle(CPButtonStyle(tint: Theme.cyan))
        Menu("Merge Into…") {
            ForEach(model.mods.filter { $0.id != mod.id && $0.enabled == mod.enabled }) { other in
                Button(other.name) { model.merge(mod, into: other) }
            }
        }
        .menuStyle(.button).buttonStyle(CPButtonStyle(tint: Theme.cyan)).fixedSize()
        .help("Combine this entry with another mod (for files the launcher grouped separately)")
        Button("Remove…") { confirmRemove = true }.buttonStyle(CPButtonStyle(tint: Theme.bad))
    }

    private var originText: String {
        switch mod.origin {
        case .installed: return mod.source.map { "installed from \($0)" } ?? "installed by the launcher"
        case .imported: return "from an earlier install"
        case .discovered: return "found in the game folder"
        }
    }
}
