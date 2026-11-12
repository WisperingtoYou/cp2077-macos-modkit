import AppKit
import LauncherCore
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case play = "Play", mods = "Mods", frameworks = "Frameworks", looks = "Looks", profiles = "Profiles"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .play: return "play.circle"
        case .mods: return "square.stack.3d.up"
        case .frameworks: return "cpu"
        case .looks: return "camera.filters"
        case .profiles: return "person.2.crop.square.stack"
        }
    }
}

enum PlayMode: String, CaseIterable, Identifiable { case modded = "Modded", vanilla = "Vanilla"; var id: String { rawValue } }

enum LaunchPhase: Equatable {
    case idle, compiling, starting, running, failed(String), exited(Int32)
}

struct CompileProblem: Identifiable {
    let id = UUID()
    let modId: String?
    let modName: String
    let file: String
    let message: String
}

/// All UI state. Disk work runs on `work` (one serial queue: the library is not thread-safe) and results are
/// published back on the main actor.
@MainActor
final class AppModel: ObservableObject {
    let game: GamePaths
    private let library: ModLibrary
    private let work = DispatchQueue(label: "launcher.work", qos: .userInitiated)
    private let launcher: GameLauncher
    private var watcher: FolderWatcher?
    private var refreshAfterExit = false
    private var healthTimer: Timer?

    @Published var section: Section = .play
    @Published var mods: [Mod] = []
    @Published var frameworks: [ModLibrary.FrameworkState] = []
    @Published var profiles: [Profile] = []
    @Published var health: Health?
    @Published var luts: [Looks.LUT] = []
    @Published var activeLUT: String?
    @Published var playMode: PlayMode = .modded
    @Published var phase: LaunchPhase = .idle
    @Published var launchOutput: [String] = []
    @Published var compileProblems: [CompileProblem] = []
    @Published var busyMods: Set<String> = []
    @Published var refreshing = false
    @Published var installQueue: [Installer.Plan] = []
    @Published var preparing = 0
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var settingUp = false

    init() {
        game = .steamDefault
        library = ModLibrary(game: game, installRecords: nil)
        launcher = GameLauncher(game: game)
        playMode = UserDefaults.standard.string(forKey: "playMode").flatMap(PlayMode.init(rawValue:)) ?? .modded
        mods = library.mods
        profiles = library.profiles
        try? FileManager.default.removeItem(at: game.staging) // the launcher's own temporary extraction folder
        refresh()
        checkHealth()
        watcher = FolderWatcher(paths: watchedFolders()) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Mods can't change while the game runs (the UI locks them), and the game writes logs and databases
                // into these folders constantly: refresh once after it exits instead.
                if self.gameRunning { self.refreshAfterExit = true } else { self.refresh(quiet: true) }
            }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth(gate: false) }
        }
    }

    var gameRunning: Bool { health?.gameRunning ?? false || phase == .running || phase == .starting }
    var enabledCount: Int { mods.filter(\.enabled).count }
    var issueCount: Int { mods.filter { ($0.verdict?.level ?? .works) > .works }.count }

    private func watchedFolders() -> [String] {
        ["archive/pc/mod", "archive/Mac/content", "r6/scripts", "r6/tweaks", "r6/input", "r6/audioware",
         "bin/x64/plugins/cyber_engine_tweaks/mods", "red4ext/plugins", "_LUT_options"].map { game.url($0).path }
    }

    // MARK: background helpers

    /// Runs `body` on the work queue and publishes the library state afterwards.
    private func perform(_ body: @escaping @Sendable (ModLibrary) throws -> Void, done: (@MainActor () -> Void)? = nil) {
        let lib = library
        work.async {
            var failure: Error?
            do { try body(lib) } catch { failure = error }
            let mods = lib.mods, profiles = lib.profiles, fws = lib.frameworks()
            Task { @MainActor in
                self.mods = mods; self.profiles = profiles; self.frameworks = fws
                if let failure { self.errorMessage = failure.localizedDescription }
                done?()
            }
        }
    }

    func refresh(quiet: Bool = false) {
        if !quiet { refreshing = true }
        let looks = Looks(game: game)
        perform({ lib in
            lib.refresh()
            lib.fillMissingVerdicts()
        }, done: {
            self.refreshing = false
        })
        work.async {
            let options = looks.options(), active = looks.active()
            Task { @MainActor in self.luts = options; self.activeLUT = active }
        }
    }

    func checkHealth(gate: Bool = true) {
        let game = game
        DispatchQueue.global(qos: .utility).async {
            let h = Health.check(game: game, gatePlugins: gate)
            Task { @MainActor in
                if let old = self.health, !gate { // keep the slow gate result between quick polls
                    var merged = h; merged.refusedPlugins = old.refusedPlugins; self.health = merged
                } else {
                    self.health = h
                }
                if !h.gameRunning, self.phase == .running { self.phase = .idle }
            }
        }
    }

    // MARK: mods

    func setEnabled(_ mod: Mod, _ on: Bool) {
        guard !gameRunning else { errorMessage = "Quit the game before changing mods."; return }
        busyMods.insert(mod.id)
        if let i = mods.firstIndex(where: { $0.id == mod.id }) { mods[i].enabled = on } // optimistic
        perform({ lib in try lib.setEnabled(mod.id, on) }, done: { self.busyMods.remove(mod.id) })
    }

    func setEnabled(_ ids: [String], _ on: Bool) {
        guard !gameRunning else { errorMessage = "Quit the game before changing mods."; return }
        busyMods.formUnion(ids)
        perform({ lib in for id in ids { try lib.setEnabled(id, on) } }, done: { self.busyMods.subtract(ids) })
    }

    func remove(_ mod: Mod) {
        guard !gameRunning else { errorMessage = "Quit the game before changing mods."; return }
        perform({ lib in try lib.remove(mod.id) }, done: { self.toast = "\(mod.name) moved to the launcher's removed folder" })
    }

    func rename(_ mod: Mod, _ name: String) { perform { lib in try lib.rename(mod.id, to: name) } }
    func merge(_ other: Mod, into target: Mod) { perform { lib in try lib.merge(other.id, into: target.id) } }

    func reveal(_ mod: Mod) {
        let urls = mod.files.prefix(20).map { library.location(of: $0, in: mod) }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    func openNexus(_ id: Int) {
        NSWorkspace.shared.open(URL(string: "https://www.nexusmods.com/cyberpunk2077/mods/\(id)")!)
    }

    // MARK: frameworks

    func setFramework(_ folder: String, _ on: Bool) {
        guard !gameRunning else { errorMessage = "Quit the game before changing frameworks."; return }
        perform({ lib in try lib.setFrameworkEnabled(folder, on) }, done: { self.checkHealth() })
    }

    /// Mods that list `framework` among their requirements.
    func dependents(of framework: Framework) -> [Mod] {
        mods.filter { $0.enabled && ($0.verdict?.requires.contains(framework) ?? false) }
    }

    // MARK: looks

    func activateLUT(_ name: String) {
        guard !gameRunning else { errorMessage = "Quit the game before switching the LUT."; return }
        activeLUT = name
        let looks = Looks(game: game)
        work.async {
            do { try looks.activate(name) } catch { Task { @MainActor in self.errorMessage = error.localizedDescription } }
            let active = looks.active()
            Task { @MainActor in self.activeLUT = active; self.toast = "LUT: \(name == "off" ? "off (vanilla colours)" : name)" }
        }
    }

    // MARK: profiles

    func saveProfile(_ name: String) { perform { lib in try lib.saveProfile(name) } }
    func deleteProfile(_ name: String) { perform { lib in try lib.deleteProfile(name) } }
    func applyProfile(_ name: String) {
        guard !gameRunning else { errorMessage = "Quit the game before switching profiles."; return }
        perform({ lib in try lib.applyProfile(name) }, done: { self.toast = "Profile \"\(name)\" applied" })
    }

    // MARK: install

    func addMods(_ urls: [URL]) {
        guard !gameRunning else { errorMessage = "Quit the game before installing mods."; return }
        section = .mods
        for url in urls {
            preparing += 1
            let lib = library, game = game
            work.async {
                do {
                    let plan = try Installer(game: game).prepare(url, library: lib)
                    Task { @MainActor in self.preparing -= 1; self.installQueue.append(plan) }
                } catch {
                    Task { @MainActor in self.preparing -= 1; self.errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)" }
                }
            }
        }
    }

    func updatePlan(_ plan: Installer.Plan) {
        guard let i = installQueue.firstIndex(where: { $0.id == plan.id }) else { return }
        var p = plan
        let lib = library, game = game
        work.async {
            Installer(game: game).replan(&p, mods: lib.mods)
            let updated = p
            Task { @MainActor in if let j = self.installQueue.firstIndex(where: { $0.id == updated.id }) { self.installQueue[j] = updated } }
        }
        installQueue[i] = plan
    }

    func install(_ plan: Installer.Plan) {
        installQueue.removeAll { $0.id == plan.id }
        let game = game
        perform({ lib in try Installer(game: game).commit(plan, library: lib) }, done: { self.toast = "Installed \(plan.modName)" })
    }

    func cancelInstall(_ plan: Installer.Plan) {
        installQueue.removeAll { $0.id == plan.id }
        let game = game
        work.async { Installer(game: game).discard(plan) }
    }

    /// Compiles the game's scripts with this plan's scripts added (isolated; about a second).
    func checkScripts(_ plan: Installer.Plan, completion: @escaping @MainActor (ScriptCheck.Result?) -> Void) {
        let game = game
        let extra = plan.entries.compactMap { e in e.target.map { (e.source, $0) } }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = try? ScriptCheck(game: game, sccDir: Self.sccDir).run(extra: extra)
            Task { @MainActor in completion(result) }
        }
    }

    /// The redscript compiler the frameworks install into the game (run from there, not from the downloaded app bundle).
    static var sccDir: URL { GamePaths.steamDefault.url("engine/tools") }

    // MARK: frameworks setup

    /// The frameworks and install.sh shipped inside the app (make-app.sh copies them).
    static var kitDir: URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("modkit"),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("install.sh").path) else { return nil }
        return dir
    }

    /// Runs the bundled install.sh: checks the game build, backs up replaced files, copies the frameworks and
    /// re-signs the game binary. Its output goes to the output panel on the Play page.
    func installFrameworks() {
        guard let kit = Self.kitDir else { errorMessage = "This build has no bundled frameworks. Run install.sh from the repository."; return }
        guard !gameRunning else { errorMessage = "Quit the game before installing the frameworks."; return }
        settingUp = true
        launchOutput = []
        let root = game.root
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [kit.appendingPathComponent("install.sh").path, root.path]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            var status: Int32 = -1, text = "Could not start install.sh"
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                status = p.terminationStatus
                text = String(decoding: data, as: UTF8.self)
            }
            Task { @MainActor in
                self.settingUp = false
                self.launchOutput = text.split(separator: "\n").map(String.init)
                if status == 0 { self.toast = "Frameworks installed" } else {
                    self.errorMessage = "Installing the frameworks failed. The details are in the output panel on the Play page."
                }
                self.checkHealth()
                self.refresh(quiet: true)
            }
        }
    }

    // MARK: play

    func play() {
        launchOutput = []
        compileProblems = []
        UserDefaults.standard.set(playMode.rawValue, forKey: "playMode")
        switch playMode {
        case .vanilla:
            do { try launcher.playVanilla(); phase = .starting; toast = "Starting the game through Steam" }
            catch { errorMessage = error.localizedDescription }
        case .modded:
            phase = .compiling
            do {
                try launcher.playModded { [weak self] event in
                    Task { @MainActor in self?.handle(event) }
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func handle(_ event: GameLauncher.Event) {
        switch event {
        case .status: break
        case .output(let line):
            launchOutput.append(line)
            if launchOutput.count > 400 { launchOutput.removeFirst(launchOutput.count - 400) }
        case .compileFailed(let errors):
            var owner: [String: Mod] = [:]
            for m in mods { for f in m.files { owner[f] = m } }
            compileProblems = errors.map { e in
                let m = owner[e.file]
                return CompileProblem(modId: m?.id, modName: m?.name ?? e.file.components(separatedBy: "/").dropFirst(2).first ?? e.file,
                                      file: e.file, message: e.message)
            }
            phase = .failed("Script compilation failed")
        case .started:
            phase = .running
        case .exited(let code):
            if case .failed = phase { return }
            phase = phase == .compiling ? .failed("The launch stopped before the game started") : .exited(code)
            checkHealth(gate: false)
            if refreshAfterExit { refreshAfterExit = false; refresh(quiet: true) }
        }
    }

    func stopGame() { launcher.stop() }

    func openLogs() {
        for p in ["red4ext/logs", "bin/x64/plugins/cyber_engine_tweaks"] {
            NSWorkspace.shared.open(game.url(p))
        }
    }

    func openGameFolder() { NSWorkspace.shared.open(game.root) }
}

/// FSEvents watcher with a short debounce.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void
    private var pending: DispatchWorkItem?

    init(paths: [String], callback: @escaping () -> Void) {
        self.callback = callback
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) } as CFArray
        stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            guard let info else { return }
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // Logs, databases and temp files are written by the running game and by mods, not installs.
            guard list.prefix(count).contains(where: { !FolderWatcher.isNoise($0) }) else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().fire()
        }, &ctx, existing, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    static func isNoise(_ path: String) -> Bool {
        let p = path.lowercased()
        let name = (p as NSString).lastPathComponent
        if p.contains("/logs/") || name.hasPrefix(".") { return true }
        for suffix in [".log", ".txt", ".sqlite3", ".sqlite", ".db", "-journal", "-wal", "-shm", ".tmp", ".json", ".ini", ".bak"]
        where name.hasSuffix(suffix) || name.contains(suffix + ".") { return true }
        return false
    }

    private func fire() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.callback() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
