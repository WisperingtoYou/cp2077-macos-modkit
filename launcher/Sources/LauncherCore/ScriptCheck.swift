import Foundation

/// Compiles the game's redscript (plus plugin scripts, plus optionally a mod that isn't installed yet) in an isolated
/// temporary tree, to find compile errors before launching. Nothing in the game folder is written.
public struct ScriptCheck: Sendable {
    let game: GamePaths
    /// Folder holding a copy of `scc` + `libscc_lib.dylib` built without the error popup.
    let sccDir: URL

    public init(game: GamePaths, sccDir: URL) { self.game = game; self.sccDir = sccDir }

    public struct Result: Sendable {
        public var ok: Bool
        /// (path relative to the game, e.g. "r6/scripts/Mod/File.reds", message)
        public var errors: [(file: String, message: String)]
        public var output: String
    }

    /// `extra`: files that would be installed — (source file, target path relative to the game).
    public func run(extra: [(URL, String)] = []) throws -> Result {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("launcher-scc-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let r6 = tmp.appendingPathComponent("r6")
        try fm.createDirectory(at: r6.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try fm.createDirectory(at: r6.appendingPathComponent("logs"), withIntermediateDirectories: true)

        // Scripts: the game's (without the launcher's staging folder), then the new mod's on top.
        let scripts = r6.appendingPathComponent("scripts")
        try fm.copyItem(at: game.url("r6/scripts"), to: scripts)
        try? fm.removeItem(at: scripts.appendingPathComponent("zz_red4ext_plugins"))
        for (src, target) in extra where target.hasPrefix("r6/scripts/") {
            let dest = tmp.appendingPathComponent(target)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
        }
        let hints = game.url("r6/config/redsUserHints")
        if fm.fileExists(atPath: hints.path) {
            try fm.createDirectory(at: r6.appendingPathComponent("config"), withIntermediateDirectories: true)
            try fm.copyItem(at: hints, to: r6.appendingPathComponent("config/redsUserHints"))
        }
        // Base blob: the vanilla one.
        let bk = game.scriptCache.appendingPathComponent("final.redscripts.bk")
        let base = fm.fileExists(atPath: bk.path) ? bk : game.scriptCache.appendingPathComponent("final.redscripts")
        try fm.copyItem(at: base, to: r6.appendingPathComponent("cache/final.redscripts"))

        // Plugin scripts (as the launch script stages them).
        var pluginDirs: [String] = []
        for folder in (try? fm.contentsOfDirectory(atPath: game.plugins.path)) ?? [] {
            let s = game.plugins.appendingPathComponent(folder).appendingPathComponent("Scripts")
            if fm.fileExists(atPath: s.path) { pluginDirs.append(s.path) }
        }
        let pathsFile = tmp.appendingPathComponent("paths.txt")
        try pluginDirs.joined(separator: "\n").write(to: pathsFile, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = sccDir.appendingPathComponent("scc")
        p.arguments = ["-compile", scripts.path, "-compilePathsFile", pathsFile.path]
        p.environment = ProcessInfo.processInfo.environment.merging(["REDSCRIPT_NO_POPUP": "1"]) { $1 } // errors come back in the output, not a dialog
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        return Result(ok: p.terminationStatus == 0, errors: Self.errors(in: output, tmpRoot: tmp, game: game), output: output)
    }

    /// "[ERROR …] [CODE] At /tmp/…/r6/scripts/Mod/File.reds:12:5:" followed by the message lines.
    static func errors(in output: String, tmpRoot: URL, game: GamePaths) -> [(String, String)] {
        var out: [(String, String)] = []
        var current: (String, [String])?
        let tmpPath = tmpRoot.standardizedFileURL.path + "/"
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("[ERROR") {
                if let c = current { out.append((c.0, c.1.joined(separator: "\n"))) }
                current = nil
                if let r = line.range(of: #" At (/.+?\.reds):\d+"#, options: .regularExpression) {
                    var path = String(line[r]).replacingOccurrences(of: #"^ At "#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
                    if let i = path.range(of: tmpPath) { path = String(path[i.upperBound...]) }
                    else if path.hasPrefix(game.root.path) { path = game.relative(URL(fileURLWithPath: path)) }
                    else if let i = path.range(of: "/red4ext/plugins/") { path = "red4ext/plugins/" + path[i.upperBound...] }
                    current = (path, [])
                }
            } else if current != nil, !line.hasPrefix("[") {
                if current!.1.count < 4 { current!.1.append(line) }
            } else if let c = current {
                out.append((c.0, c.1.joined(separator: "\n"))); current = nil
            }
        }
        if let c = current { out.append((c.0, c.1.joined(separator: "\n"))) }
        return out
    }
}
