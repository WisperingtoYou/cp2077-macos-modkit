import Foundation

/// The game's own files, read from the Steam depot manifests of the installed depots (file names are stored as plain
/// strings in the manifest's protobuf payload). Used to tell mods in `archive/Mac/content` from vanilla archives.
public struct VanillaIndex: Sendable {
    public let contentArchives: Set<String> // lowercased file names in archive/Mac/content

    public static func load(game: GamePaths) -> VanillaIndex {
        let steam = game.root.deletingLastPathComponent().deletingLastPathComponent() // steamapps
        let acf = steam.appendingPathComponent("appmanifest_1091500.acf")
        let depotcache = steam.deletingLastPathComponent().appendingPathComponent("depotcache")
        var manifests: [URL] = []
        if let text = try? String(contentsOf: acf, encoding: .utf8) {
            // "InstalledDepots" { "<depot>" { "manifest" "<id>" ...
            let regex = try! NSRegularExpression(pattern: #""(\d+)"\s*\{\s*"manifest"\s*"(\d+)""#)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let depot = String(text[Range(m.range(at: 1), in: text)!])
                let id = String(text[Range(m.range(at: 2), in: text)!])
                manifests.append(depotcache.appendingPathComponent("\(depot)_\(id).manifest"))
            }
        }
        var names = Set<String>()
        let marker = Array("archive\\Mac\\content\\".utf8)
        for url in manifests {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let bytes = [UInt8](data)
            var i = 0
            while i + marker.count < bytes.count {
                if bytes[i] == marker[0], Array(bytes[i..<i + marker.count]) == marker {
                    var j = i + marker.count
                    while j < bytes.count, bytes[j] >= 0x20, bytes[j] < 0x7F { j += 1 }
                    if let s = String(bytes: bytes[(i + marker.count)..<j], encoding: .utf8), !s.isEmpty {
                        names.insert(s.lowercased())
                    }
                    i = j
                } else {
                    i += 1
                }
            }
        }
        return VanillaIndex(contentArchives: names)
    }

    public func isVanillaContent(_ fileName: String) -> Bool {
        if contentArchives.isEmpty { // no manifest: fall back to the naming rule mods follow on the Mac
            let n = fileName.lowercased()
            return !(n.hasPrefix("basegame_99") || n.hasPrefix("basegame_002") || n.hasPrefix("basegame_zz"))
        }
        return contentArchives.contains(fileName.lowercased())
    }
}

/// Finds mod files on disk and groups them into mods.
public struct ModScanner: Sendable {
    let game: GamePaths
    let vanilla: VanillaIndex

    public init(game: GamePaths, vanilla: VanillaIndex) { self.game = game; self.vanilla = vanilla }

    /// A unit of mod files that belong together on disk (one CET folder, one script folder, an archive + its .xl).
    public struct Unit: Hashable, Sendable {
        public var key: String        // normalised name used to group units across locations
        public var displayName: String
        public var files: [String]
    }

    /// Every mod file in the game folder, as units. Frameworks (red4ext/plugins) are not included.
    public func units() -> [Unit] {
        var out: [Unit] = []
        let fm = FileManager.default

        // archive/pc/mod: an archive and the .xl files that share its stem.
        let pcMod = game.url("archive/pc/mod")
        var byStem: [String: [String]] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: pcMod.path)) ?? [] where !name.hasPrefix(".") {
            let path = "archive/pc/mod/\(name)"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: pcMod.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue {
                byStem[Self.stem(name), default: []] += FileOps.files(under: pcMod.appendingPathComponent(name), relativeTo: game)
            } else {
                byStem[Self.stem(name), default: []].append(path)
            }
        }
        for (stem, files) in byStem {
            out.append(Unit(key: Self.normalise(stem), displayName: Self.pretty(stem), files: files.sorted()))
        }

        // archive/Mac/content: anything Steam didn't install. The active LUT belongs to Looks, not to the mod list.
        let content = game.url("archive/Mac/content")
        for name in (try? fm.contentsOfDirectory(atPath: content.path)) ?? []
        where !name.hasPrefix(".") && !vanilla.isVanillaContent(name) && name != game.lutActive.lastPathComponent {
            var stem = Self.stem(name)
            for prefix in ["basegame_99_", "basegame_002_", "basegame_zz_"] where stem.lowercased().hasPrefix(prefix) {
                stem = String(stem.dropFirst(prefix.count))
            }
            out.append(Unit(key: Self.normalise(stem), displayName: Self.pretty(stem), files: ["archive/Mac/content/\(name)"]))
        }

        // One unit per top-level entry of these folders.
        let folders: [(String, Set<String>)] = [
            ("r6/scripts", ["zz_red4ext_plugins"]), // launcher staging, not a mod
            ("r6/tweaks", []), ("r6/input", []), ("r6/audioware", []),
            ("bin/x64/plugins/cyber_engine_tweaks/mods", []),
        ]
        for (folder, skip) in folders {
            let dir = game.url(folder)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") && !skip.contains(name) {
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                let files = isDir.boolValue ? FileOps.files(under: url, relativeTo: game) : ["\(folder)/\(name)"]
                guard !files.isEmpty else { continue }
                let stem = isDir.boolValue ? name : Self.stem(name)
                out.append(Unit(key: Self.normalise(stem), displayName: Self.pretty(stem), files: files))
            }
        }
        return out
    }

    /// The red4ext/plugins folders (frameworks), with their enabled state.
    public func frameworkFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: game.plugins.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: names

    /// "BlackChrome.archive.xl" -> "BlackChrome"; "#AnywhereLogic.archive" -> "#AnywhereLogic".
    static func stem(_ name: String) -> String {
        var s = name
        for ext in [".archive.xl", ".xl", ".archive", ".reds", ".yaml", ".yml", ".tweak", ".xml", ".lua"]
        where s.lowercased().hasSuffix(ext) {
            s = String(s.dropLast(ext.count)); break
        }
        return s
    }

    /// Grouping key: lowercase letters and digits only, without ordering prefixes, version tails and common suffixes.
    public static func normalise(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"^([#!~]+|zz?_|\d{1,3}_)+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[_\- ]?v?\d+(\.\d+)+$"#, with: "", options: .regularExpression)
        t = t.filter { $0.isLetter || $0.isNumber }
        for suffix in ["localization", "languages", "archive"] where t.hasSuffix(suffix) && t.count > suffix.count + 3 {
            t = String(t.dropLast(suffix.count))
        }
        return t
    }

    /// "basegame_99_enc_anim_fx" style names -> "Enc Anim Fx"; CamelCase names are kept.
    static func pretty(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"^[#!~]+"#, with: "", options: .regularExpression)
        if t.contains("_") && t == t.lowercased() {
            t = t.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        } else {
            t = t.replacingOccurrences(of: "_", with: " ")
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
