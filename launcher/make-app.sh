#!/bin/bash
# Builds "Cyberpunk 2077 Launcher.app" in the repository root (Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-../Cyberpunk 2077 Launcher.app}"
GAME="$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
SCC_DIR="../game/engine/tools" # the redscript compiler this package installs, used for the install-time script check

swift build -c release --product CyberpunkLauncher
BIN="$(swift build -c release --show-bin-path)/CyberpunkLauncher"

rm -rf "$OUT.new"
mkdir -p "$OUT.new/Contents/MacOS" "$OUT.new/Contents/Resources/scc"
cp "$BIN" "$OUT.new/Contents/MacOS/CyberpunkLauncher"
[ -f "$GAME/Cyberpunk2077.app/Contents/Resources/AppIcon.icns" ] && cp "$GAME/Cyberpunk2077.app/Contents/Resources/AppIcon.icns" "$OUT.new/Contents/Resources/"
cp Resources/ChakraPetch.ttc Resources/ChakraPetch-NOTICE.txt "$OUT.new/Contents/Resources/" # title font (SIL OFL)
cp Resources/CyberpunkLogo.png Resources/Cyberpunk-Regular.ttf Resources/Cyberpunk-Regular-NOTICE.txt "$OUT.new/Contents/Resources/" # game logo (from Steam's library cache) and fan logo font: private use only
if [ -x "$SCC_DIR/scc" ]; then cp "$SCC_DIR/scc" "$SCC_DIR/libscc_lib.dylib" "$OUT.new/Contents/Resources/scc/"; fi
cat > "$OUT.new/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CyberpunkLauncher</string>
    <key>CFBundleIdentifier</key><string>local.cet-mac.launcher</string>
    <key>CFBundleName</key><string>Cyberpunk 2077 Launcher</string>
    <key>CFBundleDisplayName</key><string>Cyberpunk 2077 Launcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST
codesign -s - -f --deep "$OUT.new" >/dev/null 2>&1
# Replace the previous build (kept as .old until the next build).
[ -d "$OUT" ] && { rm -rf "$OUT.old"; mv "$OUT" "$OUT.old"; }
mv "$OUT.new" "$OUT"
echo "built $OUT"
