import Foundation

/// Static checks of a mod's files (installed, or staged before an install).
public struct Compatibility: Sendable {
    let game: GamePaths

    public init(game: GamePaths) { self.game = game }

    /// Windows RED4ext plugin folders that have a macOS port, and the macOS folder that provides it.
    public static let portedPlugins: [String: String] = [
        "tweakxl": "TweakXL", "archivexl": "ArchiveXL", "codeware": "Codeware", "mod_settings": "mod_settings",
        "modsettings": "mod_settings", "input_loader": "InputLoader", "inputloader": "InputLoader",
        "audioware": "Audioware", "cyberenginetweaks": "CyberEngineTweaks", "red4ext": "RED4ext",
    ]

    struct KnownIssue: Codable { let match: String; let level: Verdict.Level; let note: String }

    static let knownIssues: [KnownIssue] = {
        (try? JSONDecoder().decode([KnownIssue].self, from: Data(KnownIssues.json.utf8))) ?? []
    }()

    /// A file the package contains, and where it would go in the game folder (nil: not installed).
    public struct Entry: Sendable { public var source: URL; public var target: String? }

    /// Analyses `entries`. `contents` reads a file's text (for .reds/.lua scans).
    public func analyse(_ entries: [Entry]) -> Verdict {
        var v = Verdict()
        var needs = Set<Framework>()
        var installable = 0

        for e in entries {
            guard let target = e.target else { continue }
            installable += 1
            let lower = target.lowercased()
            switch ModKind.of(target) {
            case .archiveExtension: needs.insert(.archiveXL)
            case .archive: needs.insert(.archiveXL) // the Mac game reads archive/pc/mod only through ArchiveXL
            case .tweak: needs.insert(.tweakXL)
            case .cet: needs.insert(.cet)
            case .input: needs.insert(.inputLoader)
            case .audio: needs.insert(.audioware)
            case .redscript:
                needs.insert(.redscript)
                if lower.hasSuffix(".reds"), let text = try? String(contentsOf: e.source, encoding: .utf8) {
                    needs.formUnion(Self.redscriptNeeds(text))
                }
            default: break
            }
            if lower.hasSuffix(".lua"), let text = try? String(contentsOf: e.source, encoding: .utf8),
               text.contains("Codeware") { needs.insert(.codeware) }
        }

        // Skipped Windows parts (target == nil, set by the installer) and why.
        for e in entries where e.target == nil {
            let rel = e.source.path
            let lower = rel.lowercased()
            if lower.hasSuffix(".dll") || lower.hasSuffix(".asi") || lower.hasSuffix(".exe") {
                v.skippedFiles.append(e.source.lastPathComponent)
            }
        }

        // Windows-only native plugins without a port.
        let unported = Set(entries.compactMap { e -> String? in
            guard e.target == nil else { return nil }
            let parts = e.source.pathComponents.map { $0.lowercased() }
            guard let i = parts.firstIndex(of: "plugins"), i > 0, parts[i - 1] == "red4ext", i + 1 < parts.count else { return nil }
            let folder = e.source.pathComponents[i + 1]
            return Self.portedPlugins[folder.lowercased()] == nil ? folder : nil
        })
        let knownFiles = Set(Self.knownIssues.map { $0.match.lowercased() })
        for plugin in unported.sorted() where !knownFiles.contains("\(plugin.lowercased()).dll") {
            v.notes.append("Contains the Windows-only plugin \"\(plugin)\", which has no macOS version; it is not installed.")
        }
        if entries.contains(where: { $0.target == nil && $0.source.lastPathComponent.lowercased() == "info.json"
                                     && $0.source.pathComponents.map({ $0.lowercased() }).contains("mods") }) {
            v.notes.append("This is a REDmod package. REDmod deployment is a Windows tool, so it can't be installed on macOS.")
            v.level = .incompatible
        }
        if entries.contains(where: { $0.target == nil && $0.source.pathExtension.lowercased() == "asi" }) {
            v.notes.append("Contains an .asi injector (Windows-only).")
        }

        // Known issues by file name.
        for issue in Self.knownIssues {
            if entries.contains(where: { $0.source.lastPathComponent.lowercased() == issue.match.lowercased()
                                         || ($0.target?.lowercased().contains(issue.match.lowercased()) ?? false) }) {
                v.notes.append(issue.note)
                if issue.level > v.level { v.level = issue.level }
            }
        }

        if installable == 0 && v.level != .incompatible {
            v.level = .incompatible
            if v.notes.isEmpty { v.notes.append("Nothing in this package can be used on macOS.") }
        } else if !unported.isEmpty && v.level < .partial {
            v.level = .partial
        }

        // Frameworks that are installed but turned off.
        let present = Set(((try? FileManager.default.contentsOfDirectory(atPath: game.plugins.path)) ?? []).map { $0.lowercased() })
        let off = needs.filter { f in f.pluginFolder.map { !present.contains($0.lowercased()) } ?? false }
        if !off.isEmpty {
            v.notes.insert("Needs \(off.map(\.rawValue).sorted().joined(separator: ", ")), which is turned off.", at: 0)
            if v.level < .needsFramework { v.level = .needsFramework }
        }
        v.requires = Framework.allCases.filter { needs.contains($0) }
        return v
    }

    /// Frameworks a redscript file needs, from its imports and annotations.
    static func redscriptNeeds(_ text: String) -> Set<Framework> {
        var out = Set<Framework>()
        if text.contains("import Codeware") || text.contains("Codeware.") || text.contains("GetCallbackSystem") {
            out.insert(.codeware)
        }
        if text.contains("@runtimeProperty(\"ModSettings") || text.contains("ModSettings.") { out.insert(.modSettings) }
        if text.contains("TweakXL") { out.insert(.tweakXL) }
        if text.contains("ArchiveXL") { out.insert(.archiveXL) }
        if text.contains("Audioware") { out.insert(.audioware) }
        return out
    }

    /// The verdict of an installed mod, from its files where they are now.
    public func analyse(installed mod: Mod, library: ModLibrary) -> Verdict {
        analyse(mod.files.map { Entry(source: library.location(of: $0, in: mod), target: $0) })
    }
}
