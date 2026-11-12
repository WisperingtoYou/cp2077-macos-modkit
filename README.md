# Cyberpunk 2077 Mac Modkit

The main Cyberpunk 2077 mod frameworks, built for the native macOS version of the game. The kit also includes a launcher app to manage mods. With it, most Windows mods (archives, redscript, TweakXL, ArchiveXL, CET Lua mods) run on a Mac without Wine or a Windows VM.

The kit contains the frameworks only, not the mods themselves. It was tested with about 600 mods installed at the same time.

## Requirements

- Apple silicon Mac. Tested on an M5 Pro with macOS 27.2.
- Cyberpunk 2077 from Steam, **version 2.3.1 (build 5314028)**. The addresses are tied to this build. To get this version, open Steam > Cyberpunk 2077 > Properties > Betas and select `2_31_old`.
- Xcode Command Line Tools (`xcode-select --install`). You need them only to build the launcher.

## What is included

| Component | Version | What it does |
|---|---|---|
| RED4ext | 1.29.1 | Plugin loader: injects into the game and loads the plugins below |
| Cyber Engine Tweaks | 1.37.1 | Lua mods and the in-game overlay |
| Codeware | 1.20.5 | Script library that many redscript mods need |
| TweakXL | 1.11.4 | Loads `r6/tweaks` (game data records) |
| ArchiveXL | 1.27.4 | Loads `archive/pc/mod` extensions (`.xl`): new items, appearances, world edits |
| Input Loader | 0.2.3 | Merges mod key bindings from `r6/input` |
| Mod Settings | 0.2.21 | In-game settings menu for redscript mods |
| redscript (`scc`) | 0.5.31 | Script compiler, replaces the one the game ships |
| gpuguard | – | Metal error logging and a mip-level guard (new, see below) |
| IesRaceFix | – | Fixes a startup crash in the game (new, see below) |
| exEntitySpawner shim | – | CET's entity spawner API in redscript (new, see below) |
| Launcher | – | macOS app to install, turn on/off and launch mods |

**Audioware is not included.** The Mac port works, but the upstream project has no licence, so we cannot redistribute it. Mods that need Audioware show up in the launcher as "Needs a framework".

## Install

1. Quit the game. Install 2.3.1 with the Steam beta branch above.
2. Download or clone this repository, then run:
   ```bash
   ./install.sh
   ```
   If the game is not in the default Steam folder, pass its path: `./install.sh "/path/to/Cyberpunk 2077"`.

   The script:
   - checks that the game build matches the address database,
   - copies `game/` into the game folder (files it replaces go to `<game>/_modkit_backup/<date>/`),
   - removes the quarantine flag,
   - re-signs the game binary (see [How it works](#how-it-works)).

   The original binary is kept as `Cyberpunk2077.orig`.
3. If the re-sign step says "Operation not permitted", open System Settings > Privacy & Security > App Management, allow your terminal app, then run `./install.sh` again.
4. Build the launcher:
   ```bash
   ./launcher/make-app.sh
   ```
   This writes `Cyberpunk 2077 Launcher.app` to the repository folder. You can also start modded play without the app: run `<game>/launch_red4ext.sh` while Steam is running.

Install mods the same way as on Windows. You can drop the archives on the launcher window, or put the files in the same folders as on Windows. Mods with only Windows parts (`.dll`, `.asi`, REDmod) cannot work. The launcher skips those parts and lists them.

## Usage

The launcher has five pages:

- **Play:** starts Modded or Vanilla play. First it checks Steam, the game build and the frameworks. If a mod's scripts do not compile, the page shows the error under that mod, with a button to turn it off.
- **Mods:** turn mods on or off, search them, and see each mod's files and the frameworks it uses. Turning a mod off moves its files to `<game>/_mod_launcher/disabled/`. Nothing is deleted.
- **Frameworks:** turn each RED4ext plugin on or off.
- **Looks:** switch the colour-grading LUT (put LUT `.archive` files in `<game>/_LUT_options`).
- **Profiles:** save a set of enabled mods and apply it later.

Modded play runs `launch_red4ext.sh`. Vanilla play uses Steam's own launch, and Steam's Play button also starts the game without mods.

## How it works

**Getting code into the game.** The Steam binary has the hardened runtime. CD PROJEKT already signs it with `allow-dyld-environment-variables` and `disable-library-validation`, so `DYLD_INSERT_LIBRARIES` can load RED4ext. But installing hooks writes to code pages, and that also needs `allow-unsigned-executable-memory`. `install_macos.sh` re-signs the binary ad hoc with these three entitlements. The re-signed binary loses CDPR's own `sustained-execution` entitlement, because an ad hoc signature cannot keep it. To undo the re-sign, use Steam > Verify integrity of game files.

**Launch.** `launch_red4ext.sh` does these steps:
- It checks the binary's Mach-O UUID against the address database. After a game update it stops instead of hooking the wrong addresses.
- It copies each enabled plugin's `Scripts` folder into `r6/scripts/zz_red4ext_plugins` and compiles everything with `scc`.
- It merges the input files.
- It starts the game with `DYLD_INSERT_LIBRARIES=RED4ext.dylib:gpuguard.dylib`.
- When the game exits, it removes the plugin scripts and compiles again, so a plain Steam launch still works. If that compile fails, it restores the vanilla script blob.

**Addresses.** On Windows, RED4ext finds game functions through hashes in an address library. The Mac binary has different code, so `red4ext/bin/x64/cyberpunk2077_addresses.json` maps each hash to its offset in the Mac binary. A hash is used only when its offset was confirmed. `red4ext_plugin_check` refuses a plugin that needs a hash with no confirmed offset, so the plugin does not jump into the wrong code. We added the offsets that CET, Codeware, ArchiveXL, Mod Settings and Audioware need. We found them by reverse engineering the Mac binary with Ghidra, and the notes for each one are in `patches/RED4ext.SDK.diff`.

**ABI differences.** The Mac game is built with clang for the Itanium C++ ABI, and Windows uses MSVC. The ports handle three differences:
- Functions that return a non-trivial struct return it through `x8` (sret).
- Vtables have two destructor slots, so the slots that follow are 8 bytes later.
- MSVC reverses the vtable order of some overloads.

Each binding that we changed has a comment and a `static_assert` where possible.

**File order.** Windows lists a folder in NTFS order, and some mods depend on that load order. APFS lists files in a different order. RED4ext, CET, TweakXL, ArchiveXL, Input Loader and redscript sort files into the Windows order.

**CET on Metal.** Windows CET draws its overlay with D3D12 and reads input from Win32. The Mac port does these things instead:
- It hooks `presentDrawable` to draw ImGui through Metal, and reads keyboard and mouse input from AppKit.
- It runs LuaJIT with `MAP_JIT` write protection switched on each code-page update.
- It uses a pool of prebuilt arm64 thunks for `Observe`/`Override`.

**gpuguard.** This is a small dylib that is injected next to RED4ext. It uses no game addresses.
- It logs every Metal command buffer that fails, with its queue, error, and event waits and signals. It also logs memory use every 15 s to `<game>/gpuguard.log`. Use this log when the game freezes.
- Its mip guard clamps texture descriptors that ask for more mip levels than the texture size allows, and drops copies into levels that do not exist. D3D12 accepts such textures, but Metal asserts and crashes. Some mods ship them (for example, the Virtual Atelier store icons).

**IesRaceFix.** About 4 s after start, a render job sometimes uploads light-profile (IES) data before the renderer has created the object it locks. The game then crashes on a null pointer. The more mods load at startup, the more often this happens. The plugin makes that job wait for the object.

**exEntitySpawner shim.** CET on Windows provides `exEntitySpawner`, and the Mac CET build does not. The shim (`r6/scripts/macOS exEntitySpawner`) gives the same API through Codeware's `DynamicEntitySystem`. One difference: the spawn is asynchronous. A Lua mod that uses the entity right after `Spawn` must wait until `Game.FindEntityByID` returns it.

## Changes to the upstream projects

The full diffs are in `patches/`. Each file starts with the upstream URL and the base commit it applies to. The main changes are:

- **RED4ext** (on jackmaxwil's macOS fork):
  - Plugins load in NTFS name order.
  - A trampoline page pool is used when a hook target is too far for a near branch.
  - A crash handler writes a signal-safe report to `red4ext/logs/crash_report.txt`.
  - `DYLD_INSERT_LIBRARIES` is cleared after load, so child processes of the game do not abort.
  - Plugin logs keep their names when the logs rotate.
  - The launch script detects compile failures and restores the vanilla scripts.
- **RED4ext.SDK** (on jackmaxwil's macOS fork):
  - 113 new and 24 corrected Mac addresses.
  - sret and vtable fixes for `IType::FromString`, `IRTTISystem::GetFunction`, `GetPersistentState`, `FindEntity`, `IsSavingLocked` and `IEntityStubSystem::CreateStub`.
  - `JobDispatcher` calls pass the dispatcher in `x0`.
  - `ExecuteFunction` no longer wraps game systems in a temporary `Handle`. That handle freed `cpPlayerSystem` when it was destroyed, for example in Lua `Game.AddToInventory`.
- **Cyber Engine Tweaks** (on upstream CET): the macOS platform layer.
  - CMake build, a Metal renderer and AppKit input.
  - Game hooks for 2.3.1 arm64, and the arm64 thunk pool.
  - The Lua image API on Metal.
  - TweakDB loading on a thread with a 16 MiB stack, because the default 512 KiB stack overflowed.
  - Fixes for a font atlas use-after-free, dangling captures in `Override` and a `GetAbsolutePath` recursion.
  - Key and mouse releases now reach the game while the overlay is open. Cmd+V paste works in text fields.
  - The full list is in `docs/MACOS_PORT.md` in the diff.
- **Codeware** (on upstream Codeware): the macOS port.
  - Platform layer and the sret/vtable bindings for ink, entity spawning, resources, persistence and input.
  - `static_assert`s on the ABI and a binding table in `docs/MACOS_PORT.md`.
  - Functions that need native types missing from the Mac build fail closed: they return nothing and do not crash.
- **TweakXL** (on jackmaxwil's macOS fork):
  - Files load in NTFS order.
  - Record names are registered inline at startup. Before, a parallel job read the pending records while they were still being written, and `GetRecordType` crashed.
- **ArchiveXL** (on jackmaxwil's macOS fork):
  - Files load in NTFS order.
  - These features are now enabled: collision deletions in streaming sectors, hot reload, the WorldWidgetComponent limit patch, PuppetState enums, the Transmog template override and the nails colour fallback.
  - A race in `ArchiveXL.Reload()` is fixed.
  - A garment mesh that failed to load is skipped and logged. Before, it crashed `RefreshAppearance`.
- **Input Loader**, **Mod Settings**: built as macOS RED4ext plugins, with files loaded in NTFS order. Mod Settings no longer touches script handles at load time, and it registers its archive after ArchiveXL is ready.
- **redscript**: sources compile in NTFS order. `REDSCRIPT_NO_POPUP=1` turns off the error dialog, so the launcher can read the errors from the output.

Changes in this release, compared with the setup it came from:
- The launcher no longer sets `RED4EXT_ALLOW_STOCK=1`. That variable skipped the signature check and only works on a Mac with modified SIP. Other users need the re-signed binary instead.
- The launcher's script check now runs `scc` with `REDSCRIPT_NO_POPUP=1`.
- The build paths compiled into four binaries were made anonymous.

## Building from source

Each binary in `game/` can be rebuilt from its upstream repository at the base commit in its patch file:
```bash
git clone <upstream url> && cd <repo> && git checkout <base commit> && git apply ../patches/<name>.diff
```
Then follow that project's own build instructions. The C++ plugins build with CMake against the patched RED4ext.SDK.
- gpuguard: run `src/gpuguard/build.sh`.
- IesRaceFix: run `cmake -S src/ies-race-fix -B build -DRED4EXT_SDK_DIR=<RED4ext.SDK-macos checkout> && cmake --build build`.

## Known issues

- Only 2.3.1 is supported. Patch 2.5 changes every address, and a 2.5 port is not done.
- The game can crash at startup now and then. This happens most often with many mods, and the crash location changes between runs (for example, `ArchiveXL GetFix`). Start the game again.
- With frame generation and heavy memory use, the GPU can stop responding and the game freezes. `gpuguard.log` records this. Turning off ray tracing, or using fewer high-resolution texture mods, helps.
- Some Codeware functions return nothing on Mac (see `docs/MACOS_PORT.md` in `patches/Codeware.diff`). A mod that depends on them can partly fail.
- Mods for 2.5 or later can need game features that 2.3.1 does not have.
- The re-sign step and `install.sh` were tested on one Mac only. That Mac has a modified SIP configuration, so the kit has not yet been tested on a Mac with default SIP.

## Uninstall

1. Use Steam > Verify integrity of game files. This restores the original binary and `engine/tools/scc`.
2. Delete these from the game folder:
   - `red4ext/`
   - `bin/x64/plugins/cyber_engine_tweaks/`
   - `launch_red4ext.sh`
   - `r6/scripts/macOS exEntitySpawner/`
   - `_mod_launcher/` (it holds the mods you turned off, so move out any you want to keep first)
   - `_modkit_backup/`
   - `Cyberpunk2077.orig`

## Credits

This kit is mostly other people's work. We ported, fixed and packaged it.

- **WopsS (Octavian Dima)**: [RED4ext](https://github.com/WopsS/RED4ext) and [RED4ext.SDK](https://github.com/WopsS/RED4ext.SDK). These are the plugin loader and the reverse-engineered game type headers that all the plugins build on. jekky and Jack Humbert also contributed to them.
- **jackmaxwil**: the macOS forks of [RED4ext](https://github.com/jackmaxwil/RED4ext-macos), [RED4ext.SDK](https://github.com/jackmaxwil/RED4ext.SDK-macos), [TweakXL](https://github.com/jackmaxwil/cp2077-tweak-xl-macos) and [ArchiveXL](https://github.com/jackmaxwil/cp2077-archive-xl-macos). Their work includes:
  - the Mach-O loader, the hash-to-address database with its UUID gate, and native inline hooking,
  - the codesign and install scripts (`install_macos.sh`, `codesign_macos.sh`),
  - the first Mac builds of TweakXL and ArchiveXL.

  This kit starts from those forks. Our changes are listed above.
- **yamashi, Maxime and the CET team**: [Cyber Engine Tweaks](https://github.com/maximegmd/CyberEngineTweaks), the Lua scripting runtime and overlay. Their code is used as is. We added the macOS platform layer and the fixes listed above.
- **psiberx (Pavel Siberx)**: [Codeware](https://github.com/psiberx/cp2077-codeware), [TweakXL](https://github.com/psiberx/cp2077-tweak-xl) and [ArchiveXL](https://github.com/psiberx/cp2077-archive-xl). The Codeware macOS port is ours. TweakXL and ArchiveXL come through jackmaxwil's forks.
- **Jack Humbert**: [Input Loader](https://github.com/jackhumbert/cyberpunk2077-input-loader) and [Mod Settings](https://github.com/jackhumbert/mod_settings). We added the macOS build and the fixes listed above.
- **jac3km4 (jekky)**: [redscript](https://github.com/jac3km4/redscript), the script compiler. We changed the file order and added the popup switch.
- **ysrdevs**: the technical notes of [nightcity-console-mac](https://github.com/ysrdevs/nightcity-console-mac). We used them to cross-check some CET addresses. No code was taken.
- **Our own work**: the launcher, gpuguard, IesRaceFix, the exEntitySpawner shim, `install.sh`, the Codeware and CET macOS ports, and the fixes and addresses listed above.

The licence texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

This project is not affiliated with CD PROJEKT RED. Cyberpunk 2077 is a trademark of CD PROJEKT S.A. The kit contains no game files and does not ship a modified game binary: the re-sign happens on your Mac, on your own copy.

## Licence

Our own code is MIT licensed (see [LICENSE](LICENSE)). Each framework keeps its upstream MIT licence.
