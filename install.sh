#!/bin/bash
# Installs the frameworks in game/ into the Mac Steam copy of Cyberpunk 2077 and prepares the game binary for RED4ext.
#   ./install.sh [path to the "Cyberpunk 2077" folder]
# Files that would be overwritten are first copied to <game>/_modkit_backup/<date>/.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME="${1:-$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077}"
BIN="$GAME/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
DB="$HERE/game/red4ext/bin/x64/cyberpunk2077_addresses.json"

[[ -f "$BIN" ]] || { echo "Cyberpunk2077.app not found in: $GAME"; echo "Pass the game folder: ./install.sh \"/path/to/Cyberpunk 2077\""; exit 1; }
if pgrep -xq Cyberpunk2077; then echo "Quit the game first."; exit 1; fi

# Same check as red4ext/macos/scripts/install_macos.sh, done before anything is copied.
macho_uuid() {
    perl -e 'open F,"<",$ARGV[0] or exit 1; binmode F; read F,$h,32; ($m,$ct,$st,$ft,$n)=unpack("V5",$h);
        exit 1 unless $m==0xfeedfacf; $o=32; for(1..$n){seek F,$o,0; read F,$c,8; ($cmd,$sz)=unpack("V2",$c);
        if($cmd==0x1b){read F,$u,16; print uc unpack("H*",$u); exit 0} $o+=$sz} exit 1' "$1"
}
want=$(grep -o '"uuid" *: *"[^"]*"' "$DB" | head -1 | sed 's/.*"\([^"]*\)"$/\1/' | tr -d '-' | tr '[:lower:]' '[:upper:]')
have=$(macho_uuid "$BIN" || true)
if [[ "$have" != "$want" ]]; then
    echo "Wrong game build: this package supports 2.3.1 (build $want), the installed game is $have."
    echo "Steam > Cyberpunk 2077 > Properties > Betas: select 2_31_old, let Steam download it, then run this again."
    exit 1
fi

backup="$GAME/_modkit_backup/$(date +%Y-%m-%d-%H%M%S)"
n=0
while IFS= read -r -d '' f; do
    rel="${f#"$HERE/game/"}"
    if [[ -f "$GAME/$rel" ]] && ! cmp -s "$f" "$GAME/$rel"; then
        mkdir -p "$backup/$(dirname "$rel")"
        cp -p "$GAME/$rel" "$backup/$rel"
        n=$((n + 1))
    fi
done < <(find "$HERE/game" -type f ! -name .keep -print0)
[[ $n -gt 0 ]] && echo "Backed up $n replaced file(s) to $backup"

rsync -a --exclude .keep "$HERE/game/" "$GAME/"
# Files downloaded with a browser carry the quarantine flag, and macOS then refuses to load the unsigned plugins.
for p in red4ext engine/tools/scc engine/tools/libscc_lib.dylib bin/x64/plugins/cyber_engine_tweaks launch_red4ext.sh; do
    xattr -dr com.apple.quarantine "$GAME/$p" 2>/dev/null || true
done
echo "Frameworks installed."

"$GAME/red4ext/macos/scripts/install_macos.sh"
echo
echo "Ready. Start modded play from the launcher, or run \"$GAME/launch_red4ext.sh\" (Steam must be running)."
