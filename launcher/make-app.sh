#!/bin/bash
# Builds "Cyberpunk 2077 Launcher.app" in the repository root (Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-../Cyberpunk 2077 Launcher.app}"
GAME="$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077"
VERSION="${VERSION:-1.0.0}"

swift build -c release --product CyberpunkLauncher
BIN="$(swift build -c release --show-bin-path)/CyberpunkLauncher"

rm -rf "$OUT.new"
mkdir -p "$OUT.new/Contents/MacOS" "$OUT.new/Contents/Resources/modkit"
cp "$BIN" "$OUT.new/Contents/MacOS/CyberpunkLauncher"
strip -S "$OUT.new/Contents/MacOS/CyberpunkLauncher" # drop debug symbols: they hold the build machine's source paths
[ -f "$GAME/Cyberpunk2077.app/Contents/Resources/AppIcon.icns" ] && cp "$GAME/Cyberpunk2077.app/Contents/Resources/AppIcon.icns" "$OUT.new/Contents/Resources/"
cp Resources/ChakraPetch.ttc Resources/ChakraPetch-NOTICE.txt "$OUT.new/Contents/Resources/" # title font (SIL OFL)
cp Resources/CyberpunkLogo.png Resources/Cyberpunk-Regular.ttf Resources/Cyberpunk-Regular-NOTICE.txt "$OUT.new/Contents/Resources/" # game logo and fan logo font (see THIRD_PARTY_NOTICES.md)
# The frameworks and installer, so the app can set up the game by itself (Install Frameworks on the Play page).
rsync -a ../install.sh ../game "$OUT.new/Contents/Resources/modkit/"
cat > "$OUT.new/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CyberpunkLauncher</string>
    <key>CFBundleIdentifier</key><string>io.github.wisperingtoyou.cp2077-modkit</string>
    <key>CFBundleName</key><string>Cyberpunk 2077 Launcher</string>
    <key>CFBundleDisplayName</key><string>Cyberpunk 2077 Launcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
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
