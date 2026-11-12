import AppKit
import Foundation

/// Starts the game. Modded: `launch_red4ext.sh` (compiles scripts with the plugin scripts, merges input, injects
/// RED4ext). Vanilla: Steam's own launch, after making sure the script cache is the vanilla one.
public final class GameLauncher: @unchecked Sendable {
    public enum Event: Sendable {
        case status(String)
        case output(String)
        /// Compilation failed: (file path relative to the game, message) pairs.
        case compileFailed([(file: String, message: String)])
        case started
        case exited(Int32)
    }

    let game: GamePaths
    private var process: Process?

    public init(game: GamePaths) { self.game = game }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Runs the modded launch. Events arrive on a background queue.
    public func playModded(events: @escaping @Sendable (Event) -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [game.launchScript.path]
        p.currentDirectoryURL = game.root
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let collector = OutputCollector(game: game, events: events)
        // The whole console output of each launch is kept in _mod_launcher (the previous one as .previous.log): errors
        // printed while the game quits come after RED4ext's own log is closed.
        let fm = FileManager.default
        let logURL = game.data.appendingPathComponent("launch-output.log")
        let previousURL = game.data.appendingPathComponent("launch-output.previous.log")
        try? fm.createDirectory(at: game.data, withIntermediateDirectories: true)
        if fm.fileExists(atPath: logURL.path) { _ = try? fm.replaceItemAt(previousURL, withItemAt: logURL) }
        fm.createFile(atPath: logURL.path, contents: Data("launch \(Date())\n".utf8))
        let logFile = try? FileHandle(forWritingTo: logURL)
        _ = try? logFile?.seekToEnd()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { return }
            try? logFile?.write(contentsOf: data)
            collector.feed(String(decoding: data, as: UTF8.self))
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let how = proc.terminationReason == .uncaughtSignal ? "signal" : "exit code"
            try? logFile?.write(contentsOf: Data("\nexited \(Date()): \(how) \(proc.terminationStatus)\n".utf8))
            try? logFile?.close()
            collector.finish()
            events(.exited(proc.terminationStatus))
        }
        events(.status("Compiling scripts…"))
        try p.run()
        process = p
    }

    /// Vanilla: restores the vanilla script blob if a modded one is in place, then asks Steam to start the game.
    public func playVanilla() throws {
        let cache = game.scriptCache
        let blob = cache.appendingPathComponent("final.redscripts")
        let vanilla = cache.appendingPathComponent("final.redscripts.bk")
        let fm = FileManager.default
        if fm.fileExists(atPath: vanilla.path), FileOps.size(of: blob) != FileOps.size(of: vanilla) {
            let tmp = cache.appendingPathComponent("final.redscripts.launcher-tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: vanilla, to: tmp)
            _ = try fm.replaceItemAt(blob, withItemAt: tmp)
            ActivityLog(game).write("vanilla play: restored the vanilla script blob")
        }
        NSWorkspace.shared.open(URL(string: "steam://rungameid/1091500")!)
    }

    /// Asks a running game to quit (TERM).
    public func stop() { process?.interrupt() }
}

/// Turns the launch script's output into events (status lines, compile errors).
final class OutputCollector: @unchecked Sendable {
    let game: GamePaths
    let events: @Sendable (GameLauncher.Event) -> Void
    private var buffer = ""
    private var errors: [(String, String)] = []
    private var pendingError: (file: String, lines: [String])?
    private var started = false
    private let lock = NSLock()

    init(game: GamePaths, events: @escaping @Sendable (GameLauncher.Event) -> Void) { self.game = game; self.events = events }

    func feed(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += text
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]); buffer.removeSubrange(...nl)
            handle(line)
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty { handle(buffer); buffer = "" }
        flushError()
        if !started && !errors.isEmpty { events(.compileFailed(errors)) }
    }

    private func handle(_ line: String) {
        events(.output(line))
        if line.hasPrefix("[ERROR") {
            flushError()
            // "[ERROR - date] [CODE] At /path/to/file.reds:12:5:" — the message follows on the next lines.
            if let r = line.range(of: #" At (/.+?\.reds):\d+"#, options: .regularExpression) {
                let path = String(line[r]).replacingOccurrences(of: #"^ At "#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
                pendingError = (game.relative(URL(fileURLWithPath: path)), [])
            }
        } else if pendingError != nil, !line.hasPrefix("[") {
            if pendingError!.lines.count < 4 { pendingError!.lines.append(line) }
        } else {
            flushError()
        }
        if line.contains("Launching with RED4ext") { started = true; events(.status("Starting the game…")); events(.started) }
        if line.contains("REDscript compilation failed") || line.contains("compilation has failed") {
            events(.status("Script compilation failed"))
        }
    }

    private func flushError() {
        if let e = pendingError { errors.append((e.file, e.lines.joined(separator: "\n"))); pendingError = nil }
    }
}
