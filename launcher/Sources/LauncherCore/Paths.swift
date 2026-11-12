import Foundation

/// Locations inside the game folder. The launcher keeps its own data in `<game>/_mod_launcher/`.
public struct GamePaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    /// The Steam install of the Mac game.
    public static var steamDefault: GamePaths {
        GamePaths(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"))
    }

    public var data: URL { root.appendingPathComponent("_mod_launcher") }
    public var registryFile: URL { data.appendingPathComponent("registry.json") }
    public var disabledStore: URL { data.appendingPathComponent("disabled") }
    public var frameworkStore: URL { data.appendingPathComponent("disabled_frameworks") }
    public var removedStore: URL { data.appendingPathComponent("removed") }
    public var staging: URL { data.appendingPathComponent("staging") }
    public var installBackups: URL { data.appendingPathComponent("replaced") }
    public var activityLog: URL { data.appendingPathComponent("activity.log") }

    public var gameBinary: URL { root.appendingPathComponent("Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077") }
    public var red4extDir: URL { root.appendingPathComponent("red4ext") }
    public var plugins: URL { red4extDir.appendingPathComponent("plugins") }
    public var addressDB: URL { red4extDir.appendingPathComponent("bin/x64/cyberpunk2077_addresses.json") }
    public var pluginCheck: URL { red4extDir.appendingPathComponent("bin/red4ext_plugin_check") }
    public var launchScript: URL { root.appendingPathComponent("launch_red4ext.sh") }
    public var scc: URL { root.appendingPathComponent("engine/tools/scc") }
    public var scriptCache: URL { root.appendingPathComponent("r6/cache") }
    public var cetMods: URL { root.appendingPathComponent("bin/x64/plugins/cyber_engine_tweaks/mods") }
    public var lutOptions: URL { root.appendingPathComponent("_LUT_options") }
    public var lutActive: URL { root.appendingPathComponent("archive/Mac/content/basegame_99_lut_active.archive") }
    public var modList: URL { root.appendingPathComponent("MOD_LIST.txt") }

    public func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    public func relative(_ url: URL) -> String {
        let r = url.standardizedFileURL.path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return r.hasPrefix(base) ? String(r.dropFirst(base.count)) : r
    }
}

/// Move-only file operations. Nothing here deletes: a move that would overwrite fails instead.
public enum FileOps {
    public struct MoveError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Moves every pair (from, to); on failure moves back what was already moved and throws.
    public static func moveAll(_ pairs: [(URL, URL)]) throws {
        let fm = FileManager.default
        var done: [(URL, URL)] = []
        do {
            for (from, to) in pairs {
                guard fm.fileExists(atPath: from.path) else { continue }
                if fm.fileExists(atPath: to.path) {
                    throw MoveError(message: "\(to.lastPathComponent) already exists at the destination")
                }
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: from, to: to)
                done.append((from, to))
            }
        } catch {
            for (from, to) in done.reversed() { try? fm.moveItem(at: to, to: from) }
            throw error
        }
    }

    /// Removes empty folders left behind under `dir`, up to (not including) `stop`.
    public static func pruneEmptyParents(of file: URL, stop: URL) {
        let fm = FileManager.default
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let stopPath = stop.standardizedFileURL.path
        while dir.path.count > stopPath.count, dir.path.hasPrefix(stopPath) {
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path),
                  items.allSatisfy({ $0 == ".DS_Store" }) else { break }
            for item in items { try? fm.removeItem(at: dir.appendingPathComponent(item)) } // only .DS_Store
            guard (try? fm.removeItem(at: dir)) != nil else { break }
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Lists regular files under `dir`, as paths relative to `base`.
    public static func files(under dir: URL, relativeTo base: GamePaths) -> [String] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            out.append(base.relative(u))
        }
        return out.sorted()
    }

    public static func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Appends one line per operation to `_mod_launcher/activity.log`.
public struct ActivityLog: Sendable {
    let url: URL
    public init(_ paths: GamePaths) { url = paths.activityLog }

    public func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
