import CryptoKit
import Foundation

/// LUT profiles: `_LUT_options/<name>.archive` copied to `archive/Mac/content/basegame_99_lut_active.archive`
/// (the same files and steps as switch_lut.sh). "Off" means no active LUT archive.
public struct Looks: Sendable {
    let game: GamePaths

    public init(game: GamePaths) { self.game = game }

    public struct LUT: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public let name: String
        public let sizeBytes: Int64
    }

    public func options() -> [LUT] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: game.lutOptions.path)) ?? [])
            .filter { $0.hasSuffix(".archive") }
            .map { LUT(name: String($0.dropLast(".archive".count)),
                       sizeBytes: FileOps.size(of: game.lutOptions.appendingPathComponent($0))) }
            .sorted { $0.name < $1.name }
    }

    /// The active LUT's name, "off", or nil if the active archive matches no option.
    public func active() -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: game.lutActive.path) else { return "off" }
        let size = FileOps.size(of: game.lutActive)
        let candidates = options().filter { $0.sizeBytes == size }
        if candidates.count == 1 { return candidates[0].name }
        let digest = Self.hash(game.lutActive)
        return candidates.first { Self.hash(game.lutOptions.appendingPathComponent("\($0.name).archive")) == digest }?.name
    }

    /// Activates a LUT (or "off"). The previous active archive is a copy of an option, so replacing it loses nothing;
    /// an active archive that matches no option is kept in `_LUT_options/` first.
    public func activate(_ name: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: game.lutActive.path), active() == nil {
            let keep = game.lutOptions.appendingPathComponent("previous_active_\(Int(Date().timeIntervalSince1970)).archive")
            try fm.moveItem(at: game.lutActive, to: keep)
        }
        if name == "off" {
            if fm.fileExists(atPath: game.lutActive.path) {
                let tmp = game.data.appendingPathComponent("lut_off.tmp")
                try fm.createDirectory(at: game.data, withIntermediateDirectories: true)
                try? fm.removeItem(at: tmp)
                try fm.moveItem(at: game.lutActive, to: tmp) // a copy of an option; kept until the next switch
            }
        } else {
            let src = game.lutOptions.appendingPathComponent("\(name).archive")
            let tmp = game.lutActive.appendingPathExtension("tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: src, to: tmp)
            if fm.fileExists(atPath: game.lutActive.path) {
                _ = try fm.replaceItemAt(game.lutActive, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: game.lutActive)
            }
        }
        try? (name + "\n").write(to: game.lutOptions.appendingPathComponent("ACTIVE.txt"), atomically: true, encoding: .utf8)
        ActivityLog(game).write("LUT -> \(name)")
    }

    static func hash(_ url: URL) -> String {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return "" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}
