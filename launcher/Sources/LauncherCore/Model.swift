import Foundation

/// The kinds of content a mod can contain, derived from where its files live.
public enum ModKind: String, Codable, CaseIterable, Comparable, Sendable {
    case archive = "Archive"            // archive/pc/mod/*.archive (ArchiveXL loads it)
    case archiveExtension = "ArchiveXL" // *.xl
    case contentArchive = "Content"     // archive/Mac/content (the Mac game loads it itself)
    case redscript = "Redscript"        // r6/scripts
    case tweak = "TweakXL"              // r6/tweaks
    case cet = "CET"                    // bin/x64/plugins/cyber_engine_tweaks/mods
    case input = "Input"                // r6/input
    case audio = "Audioware"            // r6/audioware
    case plugin = "Plugin"              // red4ext/plugins
    case other = "Other"

    public static func < (a: ModKind, b: ModKind) -> Bool { a.order < b.order }
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// The kind of a file, from its path relative to the game root.
    public static func of(_ path: String) -> ModKind {
        let p = path.lowercased()
        if p.hasPrefix("archive/pc/mod/") { return p.hasSuffix(".xl") ? .archiveExtension : .archive }
        if p.hasPrefix("archive/mac/content/") { return .contentArchive }
        if p.hasPrefix("r6/scripts/") { return .redscript }
        if p.hasPrefix("r6/tweaks/") { return .tweak }
        if p.hasPrefix("r6/input/") { return .input }
        if p.hasPrefix("r6/audioware/") { return .audio }
        if p.hasPrefix("bin/x64/plugins/cyber_engine_tweaks/mods/") { return .cet }
        if p.hasPrefix("red4ext/plugins/") { return .plugin }
        return .other
    }
}

/// The ported frameworks a mod can depend on.
public enum Framework: String, Codable, CaseIterable, Sendable {
    case red4ext = "RED4ext"
    case redscript = "redscript"
    case cet = "Cyber Engine Tweaks"
    case codeware = "Codeware"
    case tweakXL = "TweakXL"
    case archiveXL = "ArchiveXL"
    case inputLoader = "Input Loader"
    case modSettings = "Mod Settings"
    case audioware = "Audioware"

    /// The red4ext/plugins folder that provides it (nil: part of the game or RED4ext itself).
    public var pluginFolder: String? {
        switch self {
        case .codeware: return "Codeware"
        case .tweakXL: return "TweakXL"
        case .archiveXL: return "ArchiveXL"
        case .inputLoader: return "InputLoader"
        case .modSettings: return "mod_settings"
        case .audioware: return "Audioware"
        case .cet: return "CyberEngineTweaks"
        case .red4ext, .redscript: return nil
        }
    }
}

public struct Verdict: Codable, Hashable, Sendable {
    public enum Level: String, Codable, Comparable, Sendable {
        case works, partial, needsFramework, incompatible
        var rank: Int { [.works: 0, .needsFramework: 1, .partial: 2, .incompatible: 3][self]! }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }
    public var level: Level
    public var requires: [Framework]
    /// Human-readable findings, most important first.
    public var notes: [String]
    /// Files of the package that can't run on macOS and are not installed.
    public var skippedFiles: [String]

    public init(level: Level = .works, requires: [Framework] = [], notes: [String] = [], skippedFiles: [String] = []) {
        self.level = level; self.requires = requires; self.notes = notes; self.skippedFiles = skippedFiles
    }
}

public struct Mod: Codable, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable { case installed, imported, discovered }

    public var id: String
    public var name: String
    public var nexusId: Int?
    public var version: String?
    /// The archive it was installed from, if known.
    public var source: String?
    /// Paths relative to the game root (where the files are when the mod is enabled).
    public var files: [String]
    public var enabled: Bool
    public var origin: Origin
    public var verdict: Verdict?
    public var installedAt: Date?
    public var userNotes: String?
    /// Renamed or merged by the user: refresh keeps its grouping as is.
    public var userEdited: Bool?

    public var kinds: [ModKind] { Array(Set(files.map(ModKind.of))).sorted() }

    public init(id: String, name: String, files: [String], enabled: Bool = true, origin: Origin) {
        self.id = id; self.name = name; self.files = files; self.enabled = enabled; self.origin = origin
    }
}

public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var enabledModIds: [String]
    public var created: Date
}

public struct RegistryData: Codable, Sendable {
    public var version = 1
    public var mods: [Mod] = []
    public var profiles: [Profile] = []
    /// Folders of red4ext/plugins the user turned off (moved to the disabled store).
    public var disabledFrameworks: [String] = []
}
