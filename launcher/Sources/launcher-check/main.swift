import Foundation
import LauncherCore

// launcher-check            : runs the LauncherCore tests against a fake game folder in a temp directory
// launcher-check --scan     : read-only report of how the real game folder's mods would be grouped

var failures = 0
func check(_ ok: Bool, _ what: String, file: StaticString = #fileID, line: UInt = #line) {
    if ok { print("  ok   \(what)") } else { print("  FAIL \(what) (\(file):\(line))"); failures += 1 }
}

func write(_ url: URL, _ text: String) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

if CommandLine.arguments.contains("--scan") {
    let game = GamePaths.steamDefault
    let vanilla = VanillaIndex.load(game: game)
    print("vanilla content archives in the Steam manifest: \(vanilla.contentArchives.count)")
    let units = ModScanner(game: game, vanilla: vanilla).units()
    var groups: [String: [ModScanner.Unit]] = [:]
    for u in units { groups[u.key, default: []].append(u) }
    for (key, us) in groups.sorted(by: { $0.key < $1.key }) {
        let kinds = Set(us.flatMap(\.files).map { ModKind.of($0).rawValue }).sorted().joined(separator: ",")
        print(String(format: "%-34@ %3d files  %@", key as NSString, us.flatMap(\.files).count, kinds))
    }
    print("\(groups.count) mods from \(units.count) units")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--script-check"), i + 1 < CommandLine.arguments.count {
    let check = ScriptCheck(game: .steamDefault, sccDir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    let start = Date()
    let r = try! check.run()
    print("ok=\(r.ok) errors=\(r.errors.count) in \(Int(Date().timeIntervalSince(start)))s")
    for e in r.errors.prefix(10) { print("  \(e.file): \(e.message.prefix(120))") }
    print(r.output.split(separator: "\n").suffix(8).joined(separator: "\n"))
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--roundtrip"), i + 1 < CommandLine.arguments.count {
    // Real game: turn one mod off and on again, and compare the game folder's file list before and after.
    let game = GamePaths.steamDefault
    let records = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/projects/cet/backups/mod-install")
    let lib = ModLibrary(game: game, installRecords: records)
    lib.refresh()
    let name = CommandLine.arguments[i + 1]
    guard let mod = lib.mods.first(where: { $0.name == name }) else { print("no mod named \(name)"); exit(1) }
    func listing() -> [String] { mod.files.filter { FileManager.default.fileExists(atPath: game.url($0).path) } }
    let before = listing()
    try! lib.setEnabled(mod.id, false)
    let off = listing()
    try! lib.setEnabled(mod.id, true)
    let after = listing()
    print("\(mod.name): \(before.count) files on, \(off.count) while off, \(after.count) after; identical: \(before == after)")
    exit(before == after && off.isEmpty ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--set"), i + 2 < CommandLine.arguments.count {
    // Real game: turn one mod on or off by id, as the app does (quit the app first: it keeps its own copy).
    let lib = ModLibrary(game: .steamDefault)
    let id = CommandLine.arguments[i + 1], on = CommandLine.arguments[i + 2] == "on"
    guard let mod = lib.mods.first(where: { $0.id == id }) else { print("no mod with id \(id)"); exit(1) }
    try! lib.setEnabled(id, on)
    print("\(mod.name): \(on ? "enabled" : "disabled") (\(mod.files.count) files)")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--install") {
    // Real game: plan installs of the archives given (dry run), and install them with --commit (quit the app first).
    let commit = CommandLine.arguments.contains("--commit")
    let lib = ModLibrary(game: .steamDefault)
    let installer = Installer(game: .steamDefault)
    for path in CommandLine.arguments[(i + 1)...] where !path.hasPrefix("--") {
        let plan = try! installer.prepare(URL(fileURLWithPath: path), library: lib)
        print("\(plan.modName) [nexus \(plan.nexusId.map(String.init) ?? "-") \(plan.version ?? "-")]: \(plan.installFiles.count) files, "
              + "verdict \(plan.verdict.level) \(plan.verdict.requires.map(\.rawValue)) \(plan.verdict.notes)")
        for (f, owner) in plan.conflicts { print("   replaces \(f) (owner \(owner ?? "unknown"))") }
        if commit { let mod = try! installer.commit(plan, library: lib); print("   installed as \(mod.id)") }
        else { installer.discard(plan) }
    }
    exit(0)
}

// ---- fake game folder ----
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-check-\(UUID().uuidString)")
let game = GamePaths(root: tmp.appendingPathComponent("Cyberpunk 2077"))
defer { try? FileManager.default.removeItem(at: tmp) }

write(game.url("archive/Mac/content/basegame_1_engine.archive"), "vanilla")       // vanilla (fallback rule)
write(game.url("archive/Mac/content/basegame_99_cool_texture.archive"), "tex")
write(game.url("archive/pc/mod/DarkThing.archive"), "a")
write(game.url("archive/pc/mod/DarkThing.archive.xl"), "xl")
write(game.url("r6/scripts/Dark Thing/Main.reds"), "import Codeware.*\nmodule DarkThing")
write(game.url("r6/tweaks/DarkThing/items.yaml"), "Items.X:\n  $type: Clothing")
write(game.url("bin/x64/plugins/cyber_engine_tweaks/mods/coolmod/init.lua"), "print('hi')")
write(game.url("red4ext/plugins/Codeware/Codeware.dylib"), "bin")
write(game.url("red4ext/plugins/TweakXL/TweakXL.dylib"), "bin")
write(game.url("red4ext/plugins/ArchiveXL/ArchiveXL.dylib"), "bin")
write(game.url("_LUT_options/warm.archive"), "warm-lut")
write(game.url("_LUT_options/cold.archive"), "cold-lut-bytes")

print("scan + group")
let lib = ModLibrary(game: game)
lib.refresh()
let names = lib.mods.map(\.name)
check(lib.mods.count == 3, "3 mods found (\(names))")
let dark = lib.mods.first { $0.files.contains("archive/pc/mod/DarkThing.archive") }
check(dark?.files.count == 4, "archive + xl + script + tweak grouped into one mod (\(dark?.files ?? []))")
check(!lib.mods.contains { $0.files.contains { $0.contains("basegame_1_engine") } }, "vanilla archive is not a mod")
check(exists(game.registryFile), "registry saved")

print("idle refresh writes nothing")
lib.fillMissingVerdicts()
let stamp = (try? FileManager.default.attributesOfItem(atPath: game.registryFile.path)[.modificationDate]) as? Date
Thread.sleep(forTimeInterval: 1.1)
for _ in 0..<3 {
    lib.refresh()
    lib.fillMissingVerdicts()
}
let stamp2 = (try? FileManager.default.attributesOfItem(atPath: game.registryFile.path)[.modificationDate]) as? Date
check(stamp != nil && stamp == stamp2, "registry untouched by refreshes that change nothing (\(String(describing: stamp)) vs \(String(describing: stamp2)))")

print("disable / enable")
let darkId = dark!.id
try! lib.setEnabled(darkId, false)
check(!exists(game.url("r6/scripts/Dark Thing/Main.reds")), "files left the game folder")
check(exists(game.disabledStore.appendingPathComponent(darkId).appendingPathComponent("r6/scripts/Dark Thing/Main.reds")), "files are in the store")
check(!exists(game.url("r6/scripts/Dark Thing")), "empty folder pruned")
lib.refresh()
check(lib.mods.first { $0.id == darkId }?.enabled == false, "refresh keeps the disabled mod")
check(lib.mods.count == 3, "refresh doesn't rediscover disabled files")
try! lib.setEnabled(darkId, true)
check(exists(game.url("r6/scripts/Dark Thing/Main.reds")) && exists(game.url("archive/pc/mod/DarkThing.archive.xl")), "files are back")

print("rollback on conflict")
try! lib.setEnabled(darkId, false)
write(game.url("r6/tweaks/DarkThing/items.yaml"), "someone else's file")
do { try lib.setEnabled(darkId, true); check(false, "enable over an existing file must fail") }
catch { check(true, "enable over an existing file fails: \(error.localizedDescription)") }
check(!exists(game.url("archive/pc/mod/DarkThing.archive")), "nothing half-enabled after the failure")
try! FileManager.default.removeItem(at: game.url("r6/tweaks/DarkThing/items.yaml")) // test cleanup only
try! lib.setEnabled(darkId, true)

print("profiles")
try! lib.saveProfile("All")
try! lib.setEnabled(darkId, false)
try! lib.applyProfile("All")
check(lib.mods.first { $0.id == darkId }?.enabled == true, "profile re-enables the mod")

print("remove")
let cool = lib.mods.first { $0.files.contains { $0.contains("coolmod") } }!
try! lib.remove(cool.id)
check(!exists(game.url("bin/x64/plugins/cyber_engine_tweaks/mods/coolmod/init.lua")), "removed from the game")
let removed = FileOps.files(under: game.removedStore, relativeTo: game)
check(removed.contains { $0.hasSuffix("coolmod/init.lua") }, "kept in the removed store (\(removed.count) files)")

print("frameworks")
try! lib.setFrameworkEnabled("TweakXL", false)
check(!exists(game.url("red4ext/plugins/TweakXL")) && lib.frameworks().contains { $0.folder == "TweakXL" && !$0.enabled }, "framework off")
try! lib.setFrameworkEnabled("TweakXL", true)
check(exists(game.url("red4ext/plugins/TweakXL/TweakXL.dylib")), "framework back on")

print("compatibility")
let comp = Compatibility(game: game)
let v = comp.analyse(installed: lib.mods.first { $0.id == darkId }!, library: lib)
check(v.requires.contains(.codeware) && v.requires.contains(.tweakXL) && v.requires.contains(.archiveXL), "requirements: \(v.requires.map(\.rawValue))")
check(v.level == .works, "verdict works (\(v.level))")

print("install a zip (Windows layout + a Windows plugin)")
let pkg = tmp.appendingPathComponent("pkg")
write(pkg.appendingPathComponent("Fancy Mod/archive/pc/mod/Fancy.archive"), "fancy")
write(pkg.appendingPathComponent("Fancy Mod/archive/pc/mod/Fancy.archive.xl"), "xl")
write(pkg.appendingPathComponent("Fancy Mod/r6/scripts/Fancy/Fancy.reds"), "module Fancy")
write(pkg.appendingPathComponent("Fancy Mod/red4ext/plugins/AppearanceRuntimePlugin/AppearanceRuntimePlugin.dll"), "MZ")
write(pkg.appendingPathComponent("Fancy Mod/readme.txt"), "read me")
let zip = tmp.appendingPathComponent("Fancy Mod-12345-1-2-0-1700000000.zip")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
p.arguments = ["-c", "-k", "--keepParent", pkg.appendingPathComponent("Fancy Mod").path, zip.path]
try! p.run(); p.waitUntilExit()
let installer = Installer(game: game)
var plan = try! installer.prepare(zip, library: lib)
check(plan.nexusId == 12345 && plan.version == "1.2.0" && plan.modName == "Fancy Mod", "Nexus name/id/version parsed (\(plan.modName), \(plan.nexusId ?? 0))")
check(Set(plan.installFiles) == ["archive/pc/mod/Fancy.archive", "archive/pc/mod/Fancy.archive.xl", "r6/scripts/Fancy/Fancy.reds"],
      "installs the Mac parts only (\(plan.installFiles))")
check(plan.verdict.level == .partial && plan.verdict.notes.contains { $0.contains("AppearanceRuntimePlugin") }, "partial verdict with the plugin note")
let mod = try! installer.commit(plan, library: lib)
check(exists(game.url("archive/pc/mod/Fancy.archive")) && mod.id == "nexus-12345", "installed as \(mod.id)")
check(!exists(plan.stagingDir), "staging cleaned up")

print("install over an existing file backs it up")
write(pkg.appendingPathComponent("Fancy Mod/r6/scripts/Fancy/Fancy.reds"), "module Fancy // v2")
try? FileManager.default.removeItem(at: zip)
let p2 = Process(); p2.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
p2.arguments = ["-c", "-k", "--keepParent", pkg.appendingPathComponent("Fancy Mod").path, zip.path]
try! p2.run(); p2.waitUntilExit()
plan = try! installer.prepare(zip, library: lib)
check(plan.conflicts.count == 1, "only the changed file is a conflict (\(plan.conflicts.count))")
try! installer.commit(plan, library: lib)
check((try? String(contentsOf: game.url("r6/scripts/Fancy/Fancy.reds"), encoding: .utf8))?.contains("v2") == true, "new version installed")
check(!FileOps.files(under: game.installBackups, relativeTo: game).isEmpty, "old version backed up")
check(lib.mods.filter { $0.id == "nexus-12345" }.count == 1, "reinstall updates the same mod")

print("FOMOD")
let fom = tmp.appendingPathComponent("fom/Pick")
write(fom.appendingPathComponent("fomod/ModuleConfig.xml"), """
<config><moduleName>Pick One</moduleName><installSteps><installStep name="Main"><optionalFileGroups>
<group name="Variant" type="SelectExactlyOne"><plugins>
<plugin name="Clean"><description>clean</description><files><folder source="A" destination=""/></files><typeDescriptor><type name="Optional"/></typeDescriptor></plugin>
<plugin name="Fancy"><description>fancy</description><files><folder source="B" destination=""/></files><typeDescriptor><type name="Recommended"/></typeDescriptor></plugin>
</plugins></group></optionalFileGroups></installStep></installSteps></config>
""")
write(fom.appendingPathComponent("A/archive/pc/mod/Pick_A.archive"), "a")
write(fom.appendingPathComponent("B/archive/pc/mod/Pick_B.archive"), "b")
let fzip = tmp.appendingPathComponent("Pick.zip")
let p3 = Process(); p3.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
p3.arguments = ["-c", "-k", "--keepParent", fom.path, fzip.path]
try! p3.run(); p3.waitUntilExit()
var fplan = try! installer.prepare(fzip, library: lib)
check(fplan.fomod != nil && fplan.installFiles == ["archive/pc/mod/Pick_B.archive"], "recommended option preselected (\(fplan.installFiles))")
fplan.fomodSelection = [fplan.fomod!.steps[0].groups[0].options[0].id]
installer.replan(&fplan, mods: lib.mods)
check(fplan.installFiles == ["archive/pc/mod/Pick_A.archive"], "switching option changes the files")
installer.discard(fplan)

print("LUTs")
let looks = Looks(game: game)
check(looks.options().map(\.name) == ["cold", "warm"], "options listed")
check(looks.active() == "off", "off at start")
try! looks.activate("warm")
check(looks.active() == "warm", "warm active")
try! looks.activate("cold")
check(looks.active() == "cold", "cold active")
lib.refresh()
check(!lib.mods.contains { $0.files.contains { $0.contains("lut_active") } }, "the active LUT is not listed as a mod")
try! looks.activate("off")
check(looks.active() == "off" && exists(game.lutOptions.appendingPathComponent("cold.archive")), "off, options intact")

print("Nexus app download names")
let appPkg = tmp.appendingPathComponent("apppkg")
write(appPkg.appendingPathComponent("archive/pc/mod/AppStyle.archive"), "app")
let appZip = tmp.appendingPathComponent("Fancy App 23456 1.0.4s 2026-09-15T22-51Z KRvfRxvPf.zip")
let pz = Process(); pz.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
pz.arguments = ["-c", "-k", appPkg.path, appZip.path]; try! pz.run(); pz.waitUntilExit()
let appPlan = try! Installer(game: game).prepare(appZip, library: lib)
check(appPlan.modName == "Fancy App" && appPlan.nexusId == 23456 && appPlan.version == "1.0.4s",
      "parsed \(appPlan.modName) / \(appPlan.nexusId ?? 0) / \(appPlan.version ?? "-")")
let letterZip = tmp.appendingPathComponent("Preem Fixes - Metal-15800-1-6-0m-1731099482.zip")
try! FileManager.default.copyItem(at: appZip, to: letterZip)
let letterPlan = try! Installer(game: game).prepare(letterZip, library: lib)
check(letterPlan.modName == "Preem Fixes - Metal" && letterPlan.nexusId == 15800 && letterPlan.version == "1.6.0m",
      "letters in the version: \(letterPlan.modName) / \(letterPlan.nexusId ?? 0) / \(letterPlan.version ?? "-")")
Installer(game: game).discard(letterPlan)
let appMod = try! Installer(game: game).commit(appPlan, library: lib)
check(appMod.id == "nexus-23456", "first file of the page installed as \(appMod.id)")

print("a second file from the same Nexus page is its own mod")
let addonPkg = tmp.appendingPathComponent("addonpkg")
write(addonPkg.appendingPathComponent("archive/pc/mod/AppAddon.archive"), "addon")
let addonZip = tmp.appendingPathComponent("Fancy App - Addon 23456 1.0.0a 2026-09-15T22-51Z XyZ.zip")
let pa = Process(); pa.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
pa.arguments = ["-c", "-k", addonPkg.path, addonZip.path]; try! pa.run(); pa.waitUntilExit()
let addon = try! Installer(game: game).commit(try! Installer(game: game).prepare(addonZip, library: lib), library: lib)
check(addon.id != appMod.id && lib.mods.first { $0.id == appMod.id }?.files == ["archive/pc/mod/AppStyle.archive"],
      "addon is \(addon.id), the first mod keeps only its file")

print("install records: an add-on file does not take its host's folder")
let rec = tmp.appendingPathComponent("records")
let shop = "bin/x64/plugins/cyber_engine_tweaks/mods/Shop"
write(game.url("\(shop)/init.lua"), "x"); write(game.url("\(shop)/parts/a.lua"), "x")
write(game.url("\(shop)/db.sqlite3"), "runtime"); write(game.url("\(shop)/locations/addon.lua"), "x")
write(rec.appendingPathComponent("1-Addon/installed.txt"), "# add-on, sorts first\n\(shop)/locations/addon.lua\n")
write(rec.appendingPathComponent("2-Shop/installed.txt"), "\(shop)/init.lua\n\(shop)/parts/a.lua\n")
let rlib = ModLibrary(game: game, installRecords: rec)
rlib.refresh()
check(rlib.mods.first { $0.id == "nexus-1" }?.files == ["\(shop)/locations/addon.lua"], "add-on owns only its file")
check(rlib.mods.first { $0.id == "nexus-2" }?.files.count == 3, "host owns its files and the runtime database")

print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
