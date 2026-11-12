import Foundation

/// Installs a mod archive the way a Windows mod manager would: extract, map files to the game layout, report
/// compatibility and conflicts, then copy into the game folder. Replaced files are backed up first.
public struct Installer: Sendable {
    let game: GamePaths

    public init(game: GamePaths) { self.game = game }

    public struct Plan: Sendable, Identifiable {
        public var id: String { stagingDir.path }
        public let archive: URL
        public let stagingDir: URL
        public var modName: String
        public var nexusId: Int?
        public var version: String?
        /// Root of the extracted content (wrapper folders stripped).
        public let contentRoot: URL
        public let fomod: Fomod?
        public var fomodSelection: Set<String>
        public var entries: [Compatibility.Entry] = []
        public var verdict = Verdict()
        /// Target paths that already exist in the game folder, and the mod that owns each (nil: unknown).
        public var conflicts: [(path: String, owner: String?)] = []

        public var installFiles: [String] { entries.compactMap(\.target) }
    }

    public enum InstallError: LocalizedError {
        case extract(String), nothing
        public var errorDescription: String? {
            switch self {
            case .extract(let m): return "Couldn't extract the archive: \(m)"
            case .nothing: return "Nothing in this package can be installed on macOS."
            }
        }
    }

    // MARK: prepare

    /// Extracts `archive` into staging and builds the plan (with default FOMOD choices).
    public func prepare(_ archive: URL, library: ModLibrary) throws -> Plan {
        let fm = FileManager.default
        let staging = game.staging.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        if archive.hasDirectoryPath {
            try fm.copyItem(at: archive, to: staging.appendingPathComponent(archive.lastPathComponent))
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            p.arguments = ["-xf", archive.path, "-C", staging.path]
            let err = Pipe(); p.standardError = err
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw InstallError.extract(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        try Self.rejectUnsafe(staging)

        let root = Self.contentRoot(staging)
        let fomod = Fomod.load(root: root)
        var meta = Self.nexusMeta(archive.lastPathComponent)
        // "<modId>-<fileId>" (a renamed download): take the name from an installed mod with that Nexus id.
        if meta.nexusId == nil, let m = try? NSRegularExpression(pattern: #"^(\d{2,6})-\d+$"#)
            .firstMatch(in: meta.name, range: NSRange(meta.name.startIndex..., in: meta.name)),
           let id = Int(meta.name[Range(m.range(at: 1), in: meta.name)!]),
           let known = library.mods.first(where: { $0.nexusId == id }) {
            meta = (known.name, id, nil)
        }
        var plan = Plan(archive: archive, stagingDir: staging, modName: meta.name, nexusId: meta.nexusId, version: meta.version,
                        contentRoot: root, fomod: fomod, fomodSelection: fomod?.defaultSelection() ?? [])
        // FOMOD names are sometimes copied from another mod; use one only when the archive name says nothing
        // (e.g. a renamed download like "12345-67890.zip").
        if let fomod, fomod.name != "FOMOD", meta.nexusId == nil,
           meta.name.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "_" }) { plan.modName = fomod.name }
        replan(&plan, mods: library.mods)
        return plan
    }

    /// Recomputes entries, verdict and conflicts (after FOMOD choices change).
    public func replan(_ plan: inout Plan, mods: [Mod]) {
        var sources: [(URL, String)] = [] // (file, its path in the package layout)
        let fm = FileManager.default
        if let fomod = plan.fomod {
            for map in fomod.files(for: plan.fomodSelection) {
                let src = Self.resolve(plan.contentRoot, map.source)
                if map.isFolder {
                    for f in Self.files(src) { sources.append((f, Self.join(map.destination, Self.rel(f, src)))) }
                } else if fm.fileExists(atPath: src.path) {
                    sources.append((src, map.destination.isEmpty ? src.lastPathComponent : map.destination))
                }
            }
        } else {
            for f in Self.files(plan.contentRoot) { sources.append((f, Self.rel(f, plan.contentRoot))) }
        }
        var seen: [String: Int] = [:] // later FOMOD entries replace earlier ones
        var entries: [Compatibility.Entry] = []
        for (src, layoutPath) in sources {
            let target = map(layoutPath, modName: plan.modName)
            let entry = Compatibility.Entry(source: src, target: target)
            if let target, let i = seen[target.lowercased()] { entries[i] = entry } else {
                if let target { seen[target.lowercased()] = entries.count }
                entries.append(entry)
            }
        }
        plan.entries = entries
        plan.verdict = Compatibility(game: game).analyse(entries)
        var owners: [String: String] = [:]
        for m in mods { for f in m.files { owners[f.lowercased()] = m.name } }
        // Only files whose content would change count as conflicts (reinstalling the same version replaces nothing).
        plan.conflicts = plan.entries.compactMap { e in
            guard let t = e.target else { return nil }
            let dest = game.url(t)
            guard fm.fileExists(atPath: dest.path) else { return nil }
            if FileOps.size(of: dest) == FileOps.size(of: e.source), fm.contentsEqual(atPath: dest.path, andPath: e.source.path) { return nil }
            return (t, owners[t.lowercased()])
        }
    }

    /// Where a file of the package goes, or nil if it isn't installed on macOS.
    func map(_ layoutPath: String, modName: String) -> String? {
        let p = layoutPath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lower = p.lowercased()
        let name = (p as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if name.hasPrefix(".") || lower.hasPrefix("__macosx/") || lower.hasPrefix("fomod/") { return nil }
        if ["dll", "exe", "asi", "pdb", "lib"].contains(ext) { return nil }

        // Game layout.
        if lower.hasPrefix("red4ext/plugins/") {
            // Windows plugins can't load; a bundled copy of a ported framework is replaced by the macOS port. A macOS
            // build of a plugin (a .dylib) is installed as is.
            return ext == "dylib" ? p : nil
        }
        if lower.hasPrefix("red4ext/") || lower.hasPrefix("bin/x64/") && !lower.hasPrefix("bin/x64/plugins/cyber_engine_tweaks/") { return nil }
        if lower.hasPrefix("bin/x64/plugins/cyber_engine_tweaks/") {
            return lower.hasPrefix("bin/x64/plugins/cyber_engine_tweaks/mods/") ? p : nil // CET's own files come with the port
        }
        if lower.hasPrefix("engine/config/platform/pc/") { // Windows platform inis: the Mac game reads platform/mac
            return "engine/config/platform/mac/" + p.dropFirst("engine/config/platform/pc/".count)
        }
        if lower.hasPrefix("mods/") { return nil } // REDmod
        for root in ["archive/", "r6/", "engine/", "bin/"] where lower.hasPrefix(root) { return p }

        // Loose files.
        let folder = Self.safeFolderName(modName)
        switch ext {
        case "archive", "xl": return "archive/pc/mod/\(name)"
        case "reds": return "r6/scripts/\(folder)/\(p)"
        case "yaml", "yml", "tweak": return "r6/tweaks/\(folder)/\(p)"
        case "txt", "md", "png", "jpg", "jpeg", "pdf", "url", "html": return nil // readme and pictures
        default: break
        }
        if lower.contains("init.lua") || ext == "lua" || ext == "json" && p.contains("/") {
            // A CET mod folder at the package root: "<Mod>/init.lua".
            return "bin/x64/plugins/cyber_engine_tweaks/mods/\(p)"
        }
        return nil
    }

    // MARK: commit

    /// Copies the planned files into the game folder and records the mod. Existing files are moved to
    /// `_mod_launcher/replaced/<date>/` first.
    @discardableResult
    public func commit(_ plan: Plan, library: ModLibrary) throws -> Mod {
        let files = plan.installFiles
        guard !files.isEmpty else { throw InstallError.nothing }
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = game.installBackups.appendingPathComponent(stamp)
        var replaced: [(URL, URL)] = []
        var copied: [URL] = []
        do {
            for e in plan.entries {
                guard let t = e.target else { continue }
                let dest = game.url(t)
                if fm.fileExists(atPath: dest.path) {
                    let b = backup.appendingPathComponent(t)
                    try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: dest, to: b)
                    replaced.append((b, dest))
                }
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: e.source, to: dest)
                copied.append(dest)
            }
        } catch {
            for c in copied { try? fm.removeItem(at: c) } // only files this install just created
            for (b, dest) in replaced.reversed() { try? fm.moveItem(at: b, to: dest) }
            throw error
        }

        // Reinstalling the same Nexus mod updates its entry; its other files stay with it.
        var id = plan.nexusId.map { "nexus-\($0)" } ?? "i-" + ModScanner.normalise(plan.modName)
        // One Nexus page can hold separate files (a core and its optional services): only the same file updates the entry.
        if let existing = library.mods.first(where: { $0.id == id }),
           ModScanner.normalise(existing.name) != ModScanner.normalise(plan.modName) {
            id += "-" + ModScanner.normalise(plan.modName)
        }
        let previous = library.mods.first { $0.id == id }?.files ?? []
        library.release(files, except: id)
        var mod = Mod(id: id, name: plan.modName, files: Array(Set(files + previous.filter { fm.fileExists(atPath: game.url($0).path) })).sorted(),
                      origin: .installed)
        mod.nexusId = plan.nexusId
        mod.version = plan.version
        mod.source = plan.archive.lastPathComponent
        mod.verdict = plan.verdict
        mod.installedAt = Date()
        try library.register(mod)
        library.log.write("install \(id) from \(plan.archive.lastPathComponent): \(files.count) files, \(replaced.count) replaced"
                          + (replaced.isEmpty ? "" : " (backed up in \(game.relative(backup)))"))
        discard(plan)
        return mod
    }

    /// Removes a plan's staging folder (launcher-owned temporary files).
    public func discard(_ plan: Plan) {
        try? FileManager.default.removeItem(at: plan.stagingDir)
    }

    // MARK: helpers

    static func files(_ dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    static func rel(_ file: URL, _ base: URL) -> String {
        let b = base.standardizedFileURL.path, f = file.standardizedFileURL.path
        return f.hasPrefix(b + "/") ? String(f.dropFirst(b.count + 1)) : file.lastPathComponent
    }

    static func join(_ a: String, _ b: String) -> String { a.isEmpty ? b : a.hasSuffix("/") ? a + b : a + "/" + b }

    /// Case-insensitive path lookup inside the package (FOMOD paths are written on Windows).
    static func resolve(_ root: URL, _ path: String) -> URL {
        var url = root
        for part in path.split(separator: "/").map(String.init) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            url.appendPathComponent(names.first { $0.lowercased() == part.lowercased() } ?? part)
        }
        return url
    }

    /// Strips wrapper folders: descends while there is exactly one folder and no game-layout or mod files.
    static func contentRoot(_ staging: URL) -> URL {
        var dir = staging
        let markers: Set<String> = ["archive", "r6", "bin", "red4ext", "engine", "mods", "fomod"]
        while true {
            let items = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
            if items.contains(where: { markers.contains($0.lowercased()) }) { return dir }
            let folders = items.filter { (try? dir.appendingPathComponent($0).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            let looseFiles = items.count - folders.count
            if folders.count == 1, looseFiles == 0 { dir.appendPathComponent(folders[0]); continue }
            return dir
        }
    }

    /// Refuses packages with symlinks or paths escaping the staging folder.
    static func rejectUnsafe(_ staging: URL) throws {
        let base = staging.resolvingSymlinksInPath().path
        guard let e = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let u as URL in e {
            if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw InstallError.extract("the package contains a symbolic link (\(u.lastPathComponent))")
            }
            if !u.resolvingSymlinksInPath().path.hasPrefix(base) {
                throw InstallError.extract("a path escapes the package folder")
            }
        }
    }

    /// Nexus download names: "Mod Name-12345-1-2-0-1700000000.zip" -> ("Mod Name", 12345, "1.2.0").
    static func nexusMeta(_ fileName: String) -> (name: String, nexusId: Int?, version: String?) {
        let base = (fileName as NSString).deletingPathExtension
        // Versions can carry letters ("1-6-0m", "2-0-0cv", "1-0-0wlc").
        let regex = try! NSRegularExpression(pattern: #"^(.+?)-(\d{2,6})-(\d[\dA-Za-z-]*?)-(\d{9,11})$"#)
        if let m = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) {
            let name = String(base[Range(m.range(at: 1), in: base)!])
            let id = Int(base[Range(m.range(at: 2), in: base)!])
            let version = String(base[Range(m.range(at: 3), in: base)!]).replacingOccurrences(of: "-", with: ".")
            return (name, id, version)
        }
        // Nexus app names: "Mod Name 12345 1.0.4s 2026-09-15T22-51Z KRvfRxvPf.zip" -> ("Mod Name", 12345, "1.0.4s").
        let app = try! NSRegularExpression(pattern: #"^(.+?) (\d{2,6}) (\S+) \d{4}-\d{2}-\d{2}T[\d-]+Z \w+$"#)
        if let m = app.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) {
            return (String(base[Range(m.range(at: 1), in: base)!]), Int(base[Range(m.range(at: 2), in: base)!]),
                    String(base[Range(m.range(at: 3), in: base)!]))
        }
        return (base, nil, nil)
    }

    static func safeFolderName(_ name: String) -> String {
        let s = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
        return s.isEmpty ? "Mod" : s
    }
}
