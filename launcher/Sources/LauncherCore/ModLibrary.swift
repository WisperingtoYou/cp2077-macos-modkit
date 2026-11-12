import Foundation

/// Owns the registry and every change to the game folder's mod files. All methods are synchronous and meant to be
/// called off the main thread (the app wraps them in Tasks); the class is not thread-safe by itself, so the app
/// serialises calls through one actor.
public final class ModLibrary: @unchecked Sendable {
    public let game: GamePaths
    public private(set) var data = RegistryData()
    let log: ActivityLog
    let vanilla: VanillaIndex
    /// Where earlier manual installs recorded their files (tools/modinstall.py): `<label>/installed.txt`.
    let installRecords: URL?
    /// The registry bytes last read or written: save() skips the write when nothing changed (refreshes run often).
    private var savedBytes: Data?

    public init(game: GamePaths, installRecords: URL? = nil) {
        self.game = game
        self.log = ActivityLog(game)
        self.vanilla = VanillaIndex.load(game: game)
        self.installRecords = installRecords
        if let d = try? Data(contentsOf: game.registryFile),
           let decoded = try? Self.decoder.decode(RegistryData.self, from: d) {
            data = decoded
            savedBytes = try? Self.encoder.encode(decoded)
        }
    }

    public var mods: [Mod] { data.mods }
    public var profiles: [Profile] { data.profiles }

    // MARK: persistence

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    public func save() throws {
        let bytes = try Self.encoder.encode(data)
        if bytes == savedBytes, FileManager.default.fileExists(atPath: game.registryFile.path) { return }
        try FileManager.default.createDirectory(at: game.data, withIntermediateDirectories: true)
        let tmp = game.registryFile.appendingPathExtension("tmp")
        try bytes.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(game.registryFile, withItemAt: tmp)
        savedBytes = bytes
    }

    // MARK: refresh

    /// Re-reads the game folder: keeps known mods (dropping files that no longer exist anywhere), and adds new files as
    /// mods (grouped by name), using install records and MOD_LIST.txt for names and Nexus ids.
    public func refresh() {
        let fm = FileManager.default
        // 1. Known mods: keep files that exist where the mod's state says they are.
        for i in data.mods.indices {
            let mod = data.mods[i]
            data.mods[i].files = mod.files.filter { fm.fileExists(atPath: location(of: $0, in: mod).path) }
        }
        data.mods.removeAll { $0.files.isEmpty }
        // Groups the launcher guessed are rebuilt every time (better records may exist now), unless the user edited
        // them or they are off (their files are in the store).
        // A rebuilt group with the same files keeps its verdict, so an idle refresh leaves the registry unchanged.
        let previous = Dictionary(data.mods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func carryOver(_ mod: inout Mod) {
            if let old = previous[mod.id], old.files == mod.files { mod.verdict = old.verdict }
        }
        data.mods.removeAll { $0.origin == .discovered && $0.enabled && $0.userEdited != true }

        // 2. Files on disk that no mod owns.
        var owned = Set(data.mods.filter(\.enabled).flatMap(\.files))
        let units = ModScanner(game: game, vanilla: vanilla).units()
        var free = units.compactMap { u -> ModScanner.Unit? in
            var u = u; u.files = u.files.filter { !owned.contains($0) }; return u.files.isEmpty ? nil : u
        }

        // 3. Install records claim their files first (exact grouping, Nexus id from the label "<id>-<Name>").
        // A record claims the files it lists. A unit's unlisted files (settings, databases a mod creates at runtime in
        // its CET folder) go to the record listing most of that unit, so an add-on that drops one file into another
        // mod's folder (a Car Mod Shop location) does not take the whole folder.
        let records = readInstallRecords()
        let listed = records.map { Set($0.files) }
        var claims = Array(repeating: [String](), count: records.count)
        for u in free {
            let counts = listed.map { l in u.files.filter { l.contains($0) }.count }
            guard let top = counts.indices.max(by: { counts[$0] < counts[$1] || (counts[$0] == counts[$1] && $0 > $1) }),
                  counts[top] > 0 else { continue }
            for f in u.files { claims[listed.firstIndex { $0.contains(f) } ?? top].append(f) }
        }
        for (record, files) in zip(records, claims) {
            guard !files.isEmpty else { continue }
            var mod = Mod(id: record.id, name: record.name, files: files.sorted(), origin: .imported)
            mod.nexusId = record.nexusId
            carryOver(&mod)
            add(mod)
            owned.formUnion(files)
            free = free.compactMap { u in var u = u; u.files = u.files.filter { !owned.contains($0) }; return u.files.isEmpty ? nil : u }
        }

        // 4. The rest: units with the same normalised name form one mod.
        let names = modListNames()
        var groups: [String: [ModScanner.Unit]] = [:]
        for u in free { groups[u.key, default: []].append(u) }
        for (key, units) in groups {
            let display = units.map(\.displayName).min { a, b in a.count < b.count } ?? key
            var mod = Mod(id: "d-\(key)", name: display, files: units.flatMap(\.files).sorted(), origin: .discovered)
            if let info = names[key] { mod.nexusId = info.nexusId; if let n = info.name { mod.name = n } }
            carryOver(&mod)
            add(mod)
        }
        data.mods.sort { $0.name.lowercased() < $1.name.lowercased() }
        try? save()
    }

    /// Adds a mod, or merges its files into an existing mod with the same id.
    func add(_ mod: Mod) {
        if let i = data.mods.firstIndex(where: { $0.id == mod.id }) {
            data.mods[i].files = Array(Set(data.mods[i].files + mod.files)).sorted()
        } else {
            data.mods.append(mod)
        }
    }

    /// Where a file of `mod` is right now.
    public func location(of file: String, in mod: Mod) -> URL {
        mod.enabled ? game.url(file) : game.disabledStore.appendingPathComponent(mod.id).appendingPathComponent(file)
    }

    // MARK: enable / disable / remove

    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard let i = data.mods.firstIndex(where: { $0.id == id }), data.mods[i].enabled != enabled else { return }
        let mod = data.mods[i]
        let store = game.disabledStore.appendingPathComponent(mod.id)
        let pairs = mod.files.map { f in enabled ? (store.appendingPathComponent(f), game.url(f))
                                                 : (game.url(f), store.appendingPathComponent(f)) }
        try FileOps.moveAll(pairs)
        for (from, _) in pairs { FileOps.pruneEmptyParents(of: from, stop: enabled ? store : game.root) }
        data.mods[i].enabled = enabled
        try save()
        log.write("\(enabled ? "enable" : "disable") \(mod.id) (\(mod.files.count) files)")
    }

    /// Moves a mod's files to `_mod_launcher/removed/<date>/<id>/` and forgets it. Nothing is deleted.
    public func remove(_ id: String) throws {
        guard let i = data.mods.firstIndex(where: { $0.id == id }) else { return }
        let mod = data.mods[i]
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = game.removedStore.appendingPathComponent(stamp).appendingPathComponent(mod.id)
        let pairs = mod.files.map { (location(of: $0, in: mod), dest.appendingPathComponent($0)) }
        try FileOps.moveAll(pairs)
        for (from, _) in pairs { FileOps.pruneEmptyParents(of: from, stop: game.root) }
        try (Self.encoder.encode(mod)).write(to: dest.appendingPathComponent("mod.json"))
        data.mods.remove(at: i)
        for p in data.profiles.indices { data.profiles[p].enabledModIds.removeAll { $0 == id } }
        try save()
        log.write("remove \(mod.id) -> \(game.relative(dest))")
    }

    public func rename(_ id: String, to name: String) throws {
        guard let i = data.mods.firstIndex(where: { $0.id == id }) else { return }
        data.mods[i].name = name
        data.mods[i].userEdited = true
        try save()
    }

    /// Moves `other`'s files into `target` (both must be in the same enabled state).
    public func merge(_ other: String, into target: String) throws {
        guard let t = data.mods.firstIndex(where: { $0.id == target }),
              let o = data.mods.firstIndex(where: { $0.id == other }), t != o else { return }
        guard data.mods[t].enabled == data.mods[o].enabled else {
            throw FileOps.MoveError(message: "Turn both mods on (or both off) before merging them.")
        }
        if !data.mods[o].enabled { // move the disabled files to the target's store
            let pairs = data.mods[o].files.map { (location(of: $0, in: data.mods[o]),
                                                  game.disabledStore.appendingPathComponent(target).appendingPathComponent($0)) }
            try FileOps.moveAll(pairs)
        }
        data.mods[t].files = Array(Set(data.mods[t].files + data.mods[o].files)).sorted()
        data.mods[t].userEdited = true
        if data.mods[t].nexusId == nil { data.mods[t].nexusId = data.mods[o].nexusId }
        data.mods.remove(at: o)
        try save()
        log.write("merge \(other) into \(target)")
    }

    /// Records a mod installed by the Installer.
    public func register(_ mod: Mod) throws {
        data.mods.removeAll { $0.id == mod.id }
        data.mods.append(mod)
        data.mods.sort { $0.name.lowercased() < $1.name.lowercased() }
        try save()
    }

    /// Files now owned by mod `id` are dropped from the other mods that listed them.
    func release(_ files: [String], except id: String) {
        let taken = Set(files.map { $0.lowercased() })
        for i in data.mods.indices where data.mods[i].id != id {
            data.mods[i].files.removeAll { taken.contains($0.lowercased()) }
        }
        data.mods.removeAll { $0.files.isEmpty && $0.id != id }
    }

    /// Sets verdicts and saves once (one save per mod made every refresh rewrite the registry ~180 times).
    public func setVerdicts(_ verdicts: [(id: String, verdict: Verdict)]) {
        guard !verdicts.isEmpty else { return }
        for (id, verdict) in verdicts {
            if let i = data.mods.firstIndex(where: { $0.id == id }) { data.mods[i].verdict = verdict }
        }
        try? save()
    }

    public func setVerdict(_ id: String, _ verdict: Verdict) { setVerdicts([(id, verdict)]) }

    /// Cheap static compatibility checks for mods that don't have a verdict yet (new or rediscovered), one save.
    public func fillMissingVerdicts() {
        let comp = Compatibility(game: game)
        setVerdicts(mods.filter { $0.verdict == nil }.map { ($0.id, comp.analyse(installed: $0, library: self)) })
    }

    // MARK: profiles

    public func saveProfile(_ name: String) throws {
        data.profiles.removeAll { $0.name == name }
        data.profiles.append(Profile(name: name, enabledModIds: data.mods.filter(\.enabled).map(\.id), created: Date()))
        try save()
        log.write("save profile \(name)")
    }

    public func deleteProfile(_ name: String) throws {
        data.profiles.removeAll { $0.name == name }
        try save()
    }

    /// Turns on exactly the profile's mods. Mods installed after the profile was saved are left as they are.
    public func applyProfile(_ name: String) throws {
        guard let profile = data.profiles.first(where: { $0.name == name }) else { return }
        let wanted = Set(profile.enabledModIds)
        let known = Set(data.mods.map(\.id))
        for mod in data.mods where known.contains(mod.id) {
            let shouldEnable = wanted.contains(mod.id)
            if mod.installedAt ?? .distantPast > profile.created { continue }
            if mod.enabled != shouldEnable { try setEnabled(mod.id, shouldEnable) }
        }
        log.write("apply profile \(name)")
    }

    // MARK: frameworks

    public struct FrameworkState: Identifiable, Sendable {
        public var id: String { folder }
        public let folder: String
        public let enabled: Bool
        public let hasMacBinary: Bool   // a .dylib (a Windows .dll alone can't load)
    }

    public func frameworks() -> [FrameworkState] {
        let fm = FileManager.default
        var out: [FrameworkState] = []
        for folder in ModScanner(game: game, vanilla: vanilla).frameworkFolders() {
            let files = (try? fm.contentsOfDirectory(atPath: game.plugins.appendingPathComponent(folder).path)) ?? []
            out.append(FrameworkState(folder: folder, enabled: true, hasMacBinary: files.contains { $0.hasSuffix(".dylib") }))
        }
        for folder in data.disabledFrameworks {
            out.append(FrameworkState(folder: folder, enabled: false, hasMacBinary: true))
        }
        return out.sorted { $0.folder.lowercased() < $1.folder.lowercased() }
    }

    public func setFrameworkEnabled(_ folder: String, _ enabled: Bool) throws {
        let live = game.plugins.appendingPathComponent(folder)
        let stored = game.frameworkStore.appendingPathComponent(folder)
        try FileOps.moveAll([enabled ? (stored, live) : (live, stored)])
        if enabled { data.disabledFrameworks.removeAll { $0 == folder } }
        else if !data.disabledFrameworks.contains(folder) { data.disabledFrameworks.append(folder) }
        try save()
        log.write("\(enabled ? "enable" : "disable") framework \(folder)")
    }

    // MARK: names from earlier records

    struct InstallRecord { let id: String; let name: String; let nexusId: Int?; let files: [String] }

    func readInstallRecords() -> [InstallRecord] {
        guard let dir = installRecords,
              let labels = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return labels.sorted().compactMap { label in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(label).appendingPathComponent("installed.txt"),
                                         encoding: .utf8) else { return nil }
            let files = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
            let parts = label.split(separator: "-", maxSplits: 1)
            let nexus = parts.count == 2 ? Int(parts[0]) : nil
            let raw = parts.count == 2 ? String(parts[1]) : label
            let name = raw.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            return InstallRecord(id: nexus.map { "nexus-\($0)" } ?? "rec-\(label)", name: name, nexusId: nexus, files: files)
        }
    }

    /// MOD_LIST.txt lines like "name   [12345]" or "Name [12345]  description": normalised key -> (Nexus id, name).
    func modListNames() -> [String: (nexusId: Int?, name: String?)] {
        guard let text = try? String(contentsOf: game.modList, encoding: .utf8) else { return [:] }
        var out: [String: (Int?, String?)] = [:]
        let regex = try! NSRegularExpression(pattern: #"^\s*([A-Za-z0-9][^\[\n]{2,60}?)\s+\[(\d{2,6})\]"#, options: .anchorsMatchLines)
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(m.range(at: 1), in: text)!]).trimmingCharacters(in: .whitespaces)
            let id = Int(text[Range(m.range(at: 2), in: text)!])
            out[ModScanner.normalise(name)] = (id, name)
        }
        return out
    }
}
