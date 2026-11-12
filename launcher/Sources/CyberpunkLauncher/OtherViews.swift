import LauncherCore
import SwiftUI

// MARK: Frameworks

struct FrameworksView: View {
    @EnvironmentObject var model: AppModel

    private static let info: [String: (Framework?, String)] = [
        "ArchiveXL": (.archiveXL, "Loads archive/pc/mod and .xl extensions: new items, appearances, world edits."),
        "TweakXL": (.tweakXL, "Applies r6/tweaks: new records and game-data changes."),
        "Codeware": (.codeware, "Script library many redscript mods need (UI, callbacks, reflection)."),
        "CyberEngineTweaks": (.cet, "Lua mods and the in-game overlay (key left of Z)."),
        "InputLoader": (.inputLoader, "Merges r6/input key bindings from mods."),
        "mod_settings": (.modSettings, "The Mod Settings menu for redscript mods."),
        "Audioware": (.audioware, "Custom audio for mods (r6/audioware)."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Frameworks", code: "RED4EXT // PLUGINS",
                           subtitle: "The macOS ports that let Windows mods run. They load only in Modded play.")
                ForEach(model.frameworks) { fw in row(fw) }
                Text("RED4ext itself loads the frameworks and can't be turned off here; Vanilla play skips it entirely.")
                    .font(.cp(12)).foregroundStyle(Theme.textDim).padding(.top, 6)
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ fw: ModLibrary.FrameworkState) -> some View {
        let meta = Self.info[fw.folder]
        let dependents = meta?.0.map { model.dependents(of: $0) } ?? []
        let refused = model.health?.refusedPlugins.contains(fw.folder) ?? false
        let tint = !fw.hasMacBinary ? Theme.bad : refused ? Theme.warn : fw.enabled ? Theme.cyan : Theme.red
        return Panel(title: meta?.0?.rawValue ?? fw.folder, code: fw.hasMacBinary ? (fw.enabled ? "ONLINE" : "OFFLINE") : "WIN64", tint: tint) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    if !fw.hasMacBinary {
                        Label("Windows-only, can't load on macOS", systemImage: "xmark.octagon.fill").cpLabel(11, Theme.bad)
                    } else if refused {
                        Label("Refused by the address check", systemImage: "exclamationmark.triangle.fill").cpLabel(11, Theme.warn)
                    }
                    Text(meta?.1 ?? (fw.hasMacBinary ? "A RED4ext plugin." : "Shipped by a mod for Windows; ignored on macOS."))
                        .font(.cp(13, .regular)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    if !dependents.isEmpty {
                        Text("Used by \(dependents.count) mod\(dependents.count == 1 ? "" : "s") that are on")
                            .font(.cpMono(10)).foregroundStyle(Theme.textDim)
                    }
                }
                Spacer(minLength: 8)
                CPToggle(isOn: Binding(get: { fw.enabled }, set: { model.setFramework(fw.folder, $0) }))
                    .disabled(model.gameRunning)
            }
        }
    }
}

// MARK: Looks

struct LooksView: View {
    @EnvironmentObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Looks", code: "OPTICS // LUT",
                           subtitle: "Colour grading (LUT). One is active at a time; it applies the next time the game starts, in both Modded and Vanilla play.")
                LazyVGrid(columns: columns, spacing: 14) {
                    card("off", title: "Off", subtitle: "Vanilla colours")
                    ForEach(model.luts) { lut in
                        card(lut.name, title: Self.pretty(lut.name), subtitle: lut.sizeBytes.fileSize)
                    }
                }
                if model.activeLUT == nil {
                    Text("The active LUT doesn't match any option (a custom file). Choosing one keeps a copy of it in _LUT_options.")
                        .font(.cp(12)).foregroundStyle(Theme.warn)
                }
                Text("Add more by putting .archive LUTs into _LUT_options in the game folder.")
                    .font(.cp(12)).foregroundStyle(Theme.textDim)
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 28)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func card(_ name: String, title: String, subtitle: String) -> some View {
        let active = model.activeLUT == name
        return Button { model.activateLUT(name) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: name == "off" ? "circle.slash" : "camera.filters").font(.system(size: 20, weight: .light))
                        .foregroundStyle(active ? Theme.accent : Theme.cyan)
                    Spacer()
                    if active { Text("ACTIVE").font(.cpMono(9)).foregroundStyle(Theme.accent) }
                }
                Text(title).font(.cpHead(16)).kerning(1).textCase(.uppercase).lineLimit(1)
                    .foregroundStyle(active ? Theme.accent : Theme.text)
                Text(subtitle).font(.cpMono(10)).foregroundStyle(Theme.textDim)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Chamfer(cut: 12).fill(active ? Theme.accent.opacity(0.10) : Theme.surface.opacity(0.92)))
            .overlay(alignment: .bottomTrailing) {
                if active { HazardStripes(color: Theme.accent.opacity(0.5), spacing: 6, width: 2).frame(width: 46, height: 6).padding(12) }
            }
            .overlay(Chamfer(cut: 12).strokeBorder(active ? Theme.accent : Theme.cyan.opacity(0.3), lineWidth: active ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(LiftStyle(tint: active ? Theme.accent : Theme.cyan))
        .disabled(model.gameRunning)
        .animation(Motion.snappy, value: active)
    }

    static func pretty(_ s: String) -> String {
        s.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: Profiles

struct ProfilesView: View {
    @EnvironmentObject var model: AppModel
    @LocalState private var newName = ""

    private var nameField: some View {
        TextField("", text: $newName, prompt: Text("Profile name, e.g. \"Full\" or \"Light\"").foregroundStyle(Theme.textDim))
            .textFieldStyle(.plain).font(.cp(14, .medium))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Chamfer(cut: 6).fill(Theme.background))
            .overlay(Chamfer(cut: 6).strokeBorder(Theme.cyan.opacity(0.35), lineWidth: 1))
    }
    private var saveButton: some View {
        Button("Save Current Setup") { model.saveProfile(newName); newName = "" }
            .buttonStyle(CPButtonStyle(tint: Theme.accent))
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(title: "Profiles", code: "LOADOUTS",
                           subtitle: "A profile remembers which mods are on. Applying one turns exactly those mods on (mods installed after it was saved are left alone).")
                Panel(title: "New profile", tint: Theme.cyan) {
                    ViewThatFits(in: .horizontal) {
                        HStack { nameField; saveButton }
                        VStack(alignment: .leading) { nameField; saveButton }
                    }
                }
                ForEach(model.profiles) { p in
                    Panel {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.cpHead(17)).kerning(1).textCase(.uppercase)
                                Text("\(p.enabledModIds.count) mods · saved \(p.created.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.cpMono(10)).foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                            Button("Apply") { model.applyProfile(p.name) }.buttonStyle(CPButtonStyle(tint: Theme.accent)).disabled(model.gameRunning)
                            Button { model.deleteProfile(p.name) } label: { Image(systemName: "trash") }
                                .buttonStyle(CPButtonStyle(tint: Theme.bad)).help("Forget this profile (mods are not touched)")
                        }
                    }
                }
                if model.profiles.isEmpty {
                    Text("No profiles yet").cpLabel(12, Theme.textDim)
                }
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Page title block: small red code line, big condensed title, dim subtitle.
struct PageHeader: View {
    let title: String
    var code: String = ""
    var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !code.isEmpty {
                HStack(spacing: 6) {
                    Rectangle().fill(Theme.accent).frame(width: 14, height: 3)
                    Text(code).font(.cpMono(10)).foregroundStyle(Theme.cyan.opacity(0.8))
                }
            }
            LogoTitle(text: title, size: 52, color: Theme.red, period: 5.1)
            if !subtitle.isEmpty {
                Text(subtitle).font(.cp(14, .medium)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
        .cpAppear()
    }
}

/// Cards that lift and glow under the pointer and sink when pressed.
struct LiftStyle: ButtonStyle {
    var tint: Color = Theme.cyan
    func makeBody(configuration: Configuration) -> some View { LiftBody(configuration: configuration, tint: tint) }

    private struct LiftBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var enabled
        @LocalState private var hover = false
        var body: some View {
            let hot = hover && enabled
            configuration.label
                .overlay(CornerTicks(length: 10).stroke(tint, lineWidth: 2).padding(-3).opacity(hot ? 1 : 0))
                .shadow(color: tint.opacity(hot ? 0.3 : 0), radius: 12)
                .offset(y: hot && !configuration.isPressed ? -3 : 0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(Motion.quick, value: configuration.isPressed)
                .onHover { h in withAnimation(Motion.snappy) { hover = h } }
        }
    }
}
