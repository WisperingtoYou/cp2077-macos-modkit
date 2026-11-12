import LauncherCore
import SwiftUI

struct InstallSheet: View {
    @EnvironmentObject var model: AppModel
    @LocalState var plan: Installer.Plan
    @LocalState private var scriptState: ScriptState = .idle
    @LocalState private var showFiles = false

    enum ScriptState { case idle, running, ok, failed([(file: String, message: String)]), unavailable }

    private var hasScripts: Bool { plan.installFiles.contains { $0.hasPrefix("r6/scripts/") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.red.opacity(0.35)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    verdictPanel
                    if let fomod = plan.fomod { fomodOptions(fomod) }
                    if hasScripts { scriptPanel }
                    if !plan.conflicts.isEmpty { conflictPanel }
                    filesPanel
                }
                .padding(20)
            }
            Rectangle().fill(Theme.red.opacity(0.35)).frame(height: 1)
            footer
        }
        .frame(minWidth: 520, idealWidth: 660, maxWidth: 820, minHeight: 440, idealHeight: 640, maxHeight: 900)
        .background(CPBackground())
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .task(id: plan.fomodSelection) { runScriptCheck() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Install mod // \(plan.archive.pathExtension.uppercased())").font(.cpMono(10)).foregroundStyle(Theme.red.opacity(0.8))
            TextField("Name", text: $plan.modName).textFieldStyle(.plain).font(.cp(24, .bold)).foregroundStyle(Theme.accent)
            HStack(spacing: 8) {
                Text(plan.archive.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if let id = plan.nexusId { Text("· Nexus \(id)") }
                if let v = plan.version { Text("· v\(v)") }
                if model.installQueue.count > 1 { Text("· \(model.installQueue.count - 1) more waiting") }
            }
            .font(.cpMono(10)).foregroundStyle(Theme.textDim)
        }
        .padding(20)
    }

    private var verdictPanel: some View {
        Panel(title: "Compatibility", tint: plan.verdict.level.color) {
            VStack(alignment: .leading, spacing: 8) {
                VerdictBadge(level: plan.verdict.level)
                if plan.verdict.notes.isEmpty {
                    Text(plan.verdict.level == .works ? "Everything in this mod has a macOS framework." : "")
                        .font(.cp(13, .regular)).foregroundStyle(Theme.textDim)
                }
                ForEach(plan.verdict.notes, id: \.self) { Text($0).font(.cp(13, .regular)).fixedSize(horizontal: false, vertical: true) }
                if !plan.verdict.requires.isEmpty {
                    Text("Uses: " + plan.verdict.requires.map(\.rawValue).joined(separator: ", "))
                        .font(.cp(12)).foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    private func fomodOptions(_ fomod: Fomod) -> some View {
        Panel(title: "Installer options", code: "FOMOD", tint: Theme.cyan) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(fomod.steps) { step in
                    ForEach(step.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.name).cpLabel(12, Theme.text)
                            ForEach(group.options) { option in
                                optionRow(option, in: group)
                            }
                        }
                    }
                }
            }
        }
    }

    private func optionRow(_ option: Fomod.Option, in group: Fomod.Group) -> some View {
        let single = group.type == "SelectExactlyOne" || group.type == "SelectAtMostOne"
        let selected = plan.fomodSelection.contains(option.id)
        return Button {
            var sel = plan.fomodSelection
            if single {
                group.options.forEach { sel.remove($0.id) }
                if !(selected && group.type == "SelectAtMostOne") { sel.insert(option.id) }
            } else if selected { sel.remove(option.id) } else { sel.insert(option.id) }
            if group.type == "SelectAll" || option.type == "Required" { sel.insert(option.id) }
            plan.fomodSelection = sel
            var p = plan
            Installer(game: model.game).replan(&p, mods: model.mods)
            plan = p
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: single ? (selected ? "largecircle.fill.circle" : "circle")
                                         : (selected ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(selected ? Theme.cyan : Theme.textDim)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(option.name).font(.cp(13, .medium))
                        if option.type == "Recommended" { Text("recommended").cpLabel(9, Theme.good) }
                    }
                    if !option.description.isEmpty {
                        Text(option.description).font(.cp(11, .regular)).foregroundStyle(Theme.textDim).lineLimit(3)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(option.type == "NotUsable")
    }

    private var scriptPanel: some View {
        Panel(title: "Script check", code: "SCC", tint: Theme.cyan) {
            HStack(alignment: .top, spacing: 8) {
                switch scriptState {
                case .idle, .running:
                    ProgressView().controlSize(.small)
                    Text("Checking that the scripts compile with your other mods…")
                case .ok:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.good)
                    Text("Scripts compile together with your installed mods.")
                case .unavailable:
                    Image(systemName: "questionmark.circle").foregroundStyle(Theme.textDim)
                    Text("The script check isn't available; the launcher checks again when you press Play.")
                case .failed(let errors):
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.bad)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("With this mod, the scripts don't compile (\(errors.count) error\(errors.count == 1 ? "" : "s")):")
                        ForEach(Array(errors.prefix(4).enumerated()), id: \.offset) { _, e in
                            Text("\(e.file)\n\(e.message)").font(.cpMono(10)).foregroundStyle(Theme.textDim)
                        }
                        Text("It often needs another mod or a newer version. You can still install it and turn it off later.")
                            .font(.cp(11)).foregroundStyle(Theme.textDim)
                    }
                }
            }
            .font(.cp(13, .regular))
        }
    }

    private var conflictPanel: some View {
        Panel(title: "Conflicts", code: "\(plan.conflicts.count)", tint: Theme.warn) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Replaces \(plan.conflicts.count) existing file\(plan.conflicts.count == 1 ? "" : "s")", systemImage: "arrow.triangle.2.circlepath")
                    .font(.cp(14, .semibold)).foregroundStyle(Theme.warn)
                let owners = Set(plan.conflicts.compactMap(\.owner))
                if !owners.isEmpty { Text("From: " + owners.sorted().joined(separator: ", ")).font(.cp(13, .regular)) }
                Text("The current files are backed up (_mod_launcher/replaced) before installing.")
                    .font(.cp(11)).foregroundStyle(Theme.textDim)
            }
        }
    }

    private var filesPanel: some View {
        Panel(title: "\(plan.installFiles.count) file\(plan.installFiles.count == 1 ? "" : "s") to install", code: showFiles ? "HIDE" : "SHOW", tint: Theme.cyan) {
            if showFiles {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(plan.installFiles.prefix(200), id: \.self) {
                        Text($0).font(.cpMono(10)).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showFiles.toggle() }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { model.cancelInstall(plan) }.keyboardShortcut(.cancelAction)
                .buttonStyle(CPButtonStyle(tint: Theme.red))
            Spacer()
            Button {
                model.install(plan)
            } label: {
                Text(plan.verdict.level == .incompatible ? "Install Anyway" : "Install")
            }
            .buttonStyle(CPPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(plan.installFiles.isEmpty || model.gameRunning)
        }
        .padding(16)
    }

    private func runScriptCheck() {
        guard hasScripts else { return }
        guard FileManager.default.isExecutableFile(atPath: AppModel.sccDir.appendingPathComponent("scc").path) else {
            scriptState = .unavailable; return
        }
        scriptState = .running
        model.checkScripts(plan) { result in
            guard let result else { scriptState = .unavailable; return }
            let mine = Set(plan.installFiles)
            // Errors in this mod's files, or new errors elsewhere caused by it.
            let errors = result.errors
            scriptState = result.ok ? .ok : .failed(errors.isEmpty ? [("", "see the launch output")] : errors.sorted { mine.contains($0.file) && !mine.contains($1.file) })
        }
    }
}
