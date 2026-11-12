#!/bin/bash
# Builds the launcher with the frameworks inside and zips it for a GitHub release.
#   ./release.sh <version>   ->  dist/Cyberpunk2077-Mac-Modkit-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?usage: ./release.sh <version>}"
mkdir -p dist
rm -rf "dist/Cyberpunk 2077 Launcher.app"
VERSION="$VERSION" ./launcher/make-app.sh "$PWD/dist/Cyberpunk 2077 Launcher.app"
ZIP="dist/Cyberpunk2077-Mac-Modkit-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "dist/Cyberpunk 2077 Launcher.app" "$ZIP"
echo "$ZIP"
