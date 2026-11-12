# Cyberpunk 2077 Launcher (macOS)

The app for playing Cyberpunk 2077 with the macOS mod frameworks (RED4ext, CET, Codeware, TweakXL, ArchiveXL, Input Loader,
Mod Settings, and Audioware when installed).

- **Play:** pick Modded or Vanilla and press Play (⌘↩). The page checks Steam, the game build and the frameworks first.
  If a mod's scripts don't compile, the problem is shown under the mod that caused it, with a Turn Off button.
- **Mods:** turn mods on and off, search and filter them (⌘F, Space toggles the selection), and see each mod's
  compatibility notes, the frameworks it uses and its files. You can also rename entries, merge two entries into one,
  or remove a mod.
- **Install:** drop .zip, .7z or .rar files (or folders) anywhere on the window, or use Add Mods (⌘O).
  - The sheet shows a verdict (Works / Partial / Needs a framework / Won't work), FOMOD options, the files the
    install would replace, and a script compile check that takes about a second.
  - Windows-only parts (.dll and .asi files, Windows plugins, REDmod) are skipped and listed.
- **Frameworks:** turn each RED4ext plugin on or off. Each one shows how many enabled mods use it.
- **Looks:** switch the LUT with one click (`.archive` files in `<game>/_LUT_options`).
- **Profiles:** save which mods are on, then apply a saved set with one click.

**Nothing is deleted.** Turning a mod off moves its files to `<game>/_mod_launcher/disabled/`. Removing a mod moves
it to `_mod_launcher/removed/`. Files an install replaces go to `_mod_launcher/replaced/`. Every change is logged in
`_mod_launcher/activity.log`, and the mod list is kept in `_mod_launcher/registry.json`.

**Build:** `./make-app.sh` (Command Line Tools only) writes `Cyberpunk 2077 Launcher.app` in the repository root.
**Tests:**
- `swift build && .build/debug/launcher-check` runs the end-to-end checks against a fake game folder.
- `--scan` prints a read-only grouping report of the real game folder.
- `--script-check <scc dir>` compiles the game's scripts in an isolated temp folder.
- `--roundtrip "<mod name>"` turns a real mod off and on again and compares the files.
