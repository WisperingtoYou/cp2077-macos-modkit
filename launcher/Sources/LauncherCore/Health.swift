import AppKit
import Foundation

/// Pre-flight state shown on the Play page.
public struct Health: Sendable {
    public enum SteamState: Sendable, Equatable { case notRunning, offline, online }

    public var steam: SteamState
    /// The game's Mach-O UUID matches the address DB (otherwise a game update arrived and modded play is blocked).
    public var gameSupported: Bool
    public var gameUUID: String
    /// Plugins the RED4ext gate would refuse (folder names).
    public var refusedPlugins: [String]
    public var gameRunning: Bool
    /// The game exists in the expected folder.
    public var gameFound: Bool
    /// RED4ext and the launch script are in the game folder.
    public var frameworksInstalled: Bool
    /// The game binary carries the entitlements RED4ext needs (install_macos.sh re-signs it; a Steam update undoes it).
    public var binaryPrepared: Bool

    public var needsSetup: Bool { gameFound && (!frameworksInstalled || !binaryPrepared) }
    public var canPlayModded: Bool { gameSupported && frameworksInstalled && binaryPrepared && steam != .notRunning && !gameRunning }
    public var canPlayVanilla: Bool { steam != .notRunning && !gameRunning }

    public static func check(game: GamePaths, gatePlugins: Bool = true) -> Health {
        let uuid = machoUUID(game.gameBinary) ?? ""
        let dbUUID = (try? String(contentsOf: game.addressDB, encoding: .utf8))
            .flatMap { text -> String? in
                guard let r = text.range(of: #""uuid"\s*:\s*"([^"]+)""#, options: .regularExpression) else { return nil }
                return String(text[r]).components(separatedBy: "\"").dropLast().last
            }?.replacingOccurrences(of: "-", with: "").uppercased() ?? ""
        let fm = FileManager.default
        return Health(steam: steamState(), gameSupported: !uuid.isEmpty && uuid == dbUUID, gameUUID: uuid,
                      refusedPlugins: gatePlugins ? refused(game) : [], gameRunning: isGameRunning(),
                      gameFound: fm.fileExists(atPath: game.gameBinary.path),
                      frameworksInstalled: fm.fileExists(atPath: game.red4extDir.appendingPathComponent("RED4ext.dylib").path)
                          && fm.fileExists(atPath: game.launchScript.path),
                      binaryPrepared: hasRED4extEntitlements(game.gameBinary))
    }

    public static func isGameRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.executableURL?.lastPathComponent == "Cyberpunk2077" }
    }

    /// Steam's client runs and its connection log says it is logged on (a "Session Replaced" logoff leaves the app
    /// open but offline; games then can't see the user).
    public static func steamState() -> SteamState {
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.valvesoftware.steam" || $0.executableURL?.lastPathComponent == "steam_osx"
        }
        guard running else { return .notRunning }
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/logs/connection_log.txt")
        guard let h = try? FileHandle(forReadingFrom: log) else { return .online }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        let on = tail.range(of: "[Logged On", options: .backwards)?.lowerBound
        let off = tail.range(of: "[Logged Off", options: .backwards)?.lowerBound
        switch (on, off) {
        case let (on?, off?): return on > off ? .online : .offline
        case (nil, _?): return .offline
        default: return .online
        }
    }

    static func refused(_ game: GamePaths) -> [String] {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: game.pluginCheck.path) else { return [] }
        var out: [String] = []
        for folder in (try? fm.contentsOfDirectory(atPath: game.plugins.path)) ?? [] {
            let dir = game.plugins.appendingPathComponent(folder)
            let dylibs = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".dylib") }
            guard !dylibs.isEmpty else { continue }
            let p = Process()
            p.executableURL = game.pluginCheck
            p.arguments = [game.addressDB.path] + dylibs.map { dir.appendingPathComponent($0).path }
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            if (try? p.run()) != nil { p.waitUntilExit(); if p.terminationStatus != 0 { out.append(folder) } }
        }
        return out.sorted()
    }

    /// LC_UUID of a Mach-O (thin arm64) binary, uppercase hex without dashes.
    static func machoUUID(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let header = try? h.read(upToCount: 32), header.count == 32 else { return nil }
        func u32(_ d: Data, _ o: Int) -> UInt32 { d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        guard u32(header, 0) == 0xFEEDFACF else { return nil }
        let ncmds = Int(u32(header, 16)), sizeofcmds = Int(u32(header, 20))
        guard let cmds = try? h.read(upToCount: sizeofcmds) else { return nil }
        var off = 0
        for _ in 0..<ncmds where off + 8 <= cmds.count {
            let cmd = u32(cmds, off), size = Int(u32(cmds, off + 4))
            if cmd == 0x1B, off + 24 <= cmds.count {
                return cmds.subdata(in: off + 8..<off + 24).map { String(format: "%02X", $0) }.joined()
            }
            off += max(size, 8)
        }
        return nil
    }
}

extension Health {
    /// Same test as launch_red4ext.sh: the signature's entitlements allow unsigned executable memory.
    static func hasRED4extEntitlements(_ binary: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-d", "--entitlements", "-", "--xml", binary.path]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("allow-unsigned-executable-memory")
    }
}
