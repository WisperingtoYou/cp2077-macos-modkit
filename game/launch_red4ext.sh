#!/bin/bash
# RED4ext macOS Launcher
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED4EXT_DIR="$SCRIPT_DIR/red4ext"
GAME_BINARY="$SCRIPT_DIR/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"

echo "=== RED4ext macOS Launcher ==="

# The game binary's Mach-O UUID (LC_UUID), uppercase hex without dashes. Perl ships with macOS; dwarfdump/otool need
# the Xcode command line tools.
macho_uuid() {
    perl -e 'open F,"<",$ARGV[0] or exit 1; binmode F; read F,$h,32; ($m,$ct,$st,$ft,$n)=unpack("V5",$h);
        exit 1 unless $m==0xfeedfacf; $o=32; for(1..$n){seek F,$o,0; read F,$c,8; ($cmd,$sz)=unpack("V2",$c);
        if($cmd==0x1b){read F,$u,16; print uc unpack("H*",$u); exit 0} $o+=$sz} exit 1' "$1"
}
db_uuid() { grep -o '"uuid" *: *"[^"]*"' "$1" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' | tr -d '-' | tr '[:lower:]' '[:upper:]'; }

# Pre-flight. A Steam update (or "Verify integrity") replaces the game binary: it loses RED4ext's signature, and a new
# game build is one this release's addresses were not verified for. In both cases stop here; Steam's Play button still
# starts the game without mods.
DB_FILE="$RED4EXT_DIR/bin/x64/cyberpunk2077_addresses.json"
if [[ "$(macho_uuid "$GAME_BINARY")" != "$(db_uuid "$DB_FILE")" ]]; then
    echo "The game was updated to a build this RED4ext release does not support yet. Not starting with mods."
    echo "Wait for a RED4ext release for the new game version, or play without mods from Steam."
    exit 1
fi
# RED4EXT_ALLOW_STOCK=1: the stock (CDPR-signed) binary is used as is. Hooking works on it on Macs whose SIP
# configuration allows patching (verified on the cet-mac author's machine); otherwise run install_macos.sh.
if [[ "${RED4EXT_ALLOW_STOCK:-0}" != 1 ]] && ! codesign -d --entitlements - --xml "$GAME_BINARY" 2>/dev/null | grep -q allow-unsigned-executable-memory; then
    echo "The game binary is not set up for RED4ext (Steam replaced it). Run this once, then launch again:"
    echo "  \"$RED4EXT_DIR/macos/scripts/install_macos.sh\""
    exit 1
fi


# Compile REDscript together with the scripts of the plugins RED4ext will load (staged under r6/scripts because scc
# takes one folder). A plugin's scripts declare its natives, and the game stops with "Failed to initialize scripts
# data!" when a declared native's plugin is not loaded. So a plugin's scripts are staged only if config.ini does not
# ignore it and it passes the loader's address gate (red4ext_plugin_check).
STAGE="$SCRIPT_DIR/r6/scripts/zz_red4ext_plugins"
CHECK="$RED4EXT_DIR/bin/red4ext_plugin_check"
DB="$RED4EXT_DIR/bin/x64/cyberpunk2077_addresses.json"
IGNORED=$(awk '/^ignored *=/{f=1} f{print} f&&/\]/{exit}' "$RED4EXT_DIR/config.ini" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' || true)
# When the launcher exits (after the game, or on a compile failure), take the plugin scripts out again and recompile. Otherwise a later launch from Steam (without
# RED4ext) would load scripts that declare natives of plugins that are not loaded and stop at script initialization.
# If r6/scripts holds mods that need a plugin (Codeware, TweakXL...), that compile fails and scc keeps the modded blob,
# which a plain Steam launch can't load. Then fall back to scc's backup of the vanilla blob (final.redscripts.bk): Steam's
# Play button starts the game without script mods, as it would without RED4ext on Windows.
cleanup() {
    rm -rf "$STAGE"
    local scc="$SCRIPT_DIR/engine/tools/scc" cache="$SCRIPT_DIR/r6/cache"
    [[ -x "$scc" ]] || return 0
    # No error dialog: this compile is expected to fail when mods need plugins (handled below), and it runs after the
    # game has quit, so a redscript popup would appear out of nowhere and block until dismissed.
    if ! REDSCRIPT_NO_POPUP=1 "$scc" -compile "$SCRIPT_DIR/r6/scripts" >/dev/null 2>&1; then
        if [[ -f "$cache/final.redscripts.bk" ]]; then
            cp "$cache/final.redscripts.bk" "$cache/final.redscripts"
            echo "Scripts for a launch without RED4ext: some r6/scripts mods need RED4ext plugins, so the vanilla scripts were restored."
        fi
    fi
}
trap cleanup EXIT
rm -rf "$STAGE"
for dir in "$RED4EXT_DIR"/plugins/*/; do
    name=$(basename "$dir")
    [[ -d "$dir/Scripts" ]] || continue
    if grep -qxF "$name" <<<"$IGNORED"; then
        echo "Not compiling $name's scripts: ignored in config.ini"
        continue
    fi
    dylibs=("$dir"*.dylib)
    if [[ ! -x "$CHECK" ]] || ! "$CHECK" "$DB" "${dylibs[@]}" >/dev/null 2>&1; then
        echo "Not compiling $name's scripts: RED4ext will not load it (unverified addresses)"
        continue
    fi
    mkdir -p "$STAGE" && cp -R "$dir/Scripts" "$STAGE/$name"
done
if [[ -x "$SCRIPT_DIR/engine/tools/scc" ]]; then
    # scc exits non-zero when compilation fails ("REDScript compilation has failed.").
    SCC_RC=0
    # Failures are reported below (and by the launcher app) from the exit code and output, not by a redscript popup.
    SCC_OUT=$(REDSCRIPT_NO_POPUP=1 "$SCRIPT_DIR/engine/tools/scc" -compile "$SCRIPT_DIR/r6/scripts" 2>&1) || SCC_RC=$?
    echo "$SCC_OUT" | tail -3
    if [[ $SCC_RC -ne 0 ]]; then
        echo "$SCC_OUT" | grep -A3 "^\[ERROR" | head -40
        echo "REDscript compilation failed; not launching (the game would stop at the same errors)."
        exit 1
    fi
fi

# Merge mod key bindings (r6/input/*.xml) into r6/cache, where the game reads them. The loader uses paths relative to
# the game folder, so it runs from there wherever this script is started from.
[[ -x "$SCRIPT_DIR/engine/tools/inputloader.pl" ]] && (cd "$SCRIPT_DIR" && engine/tools/inputloader.pl) 2>&1 || true

# Started outside Steam, the game's SteamAPI_Init has no app ID and fails (no saves, no achievements). Pass the ID that
# Steam itself sets, only when Steam is already running; this script never starts Steam.
if pgrep -q steam_osx; then
    export SteamAppId=1091500 SteamGameId=1091500
else
    echo "Steam is not running: start Steam and sign in first, or saves will not be available."
fi

echo "Launching with RED4ext..."
# gpuguard: logs failed Metal command buffers and memory use to gpuguard.log in the game folder, and clamps textures
# that ask for impossible mip counts (Metal asserts on them). Source: src/gpuguard in the modkit repository.
INJECT="$RED4EXT_DIR/RED4ext.dylib"
[[ -f "$RED4EXT_DIR/gpuguard.dylib" ]] && INJECT="$INJECT:$RED4EXT_DIR/gpuguard.dylib"
DYLD_INSERT_LIBRARIES="$INJECT" "$GAME_BINARY" "$@"
