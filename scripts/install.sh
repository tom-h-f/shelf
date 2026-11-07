#!/bin/zsh
# Build Shelf, assemble Shelf.app, ad-hoc sign it, install to ~/Applications and launch it.
set -euo pipefail
root=${0:A:h}/..
cd "$root"
"$root/scripts/setup-kindle-previewer.sh"
source "$root/scripts/env.sh"
swift build -c release
app="$root/.build/Shelf.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Shelf "$app/Contents/MacOS/Shelf"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/claude-settings.json Resources/result-schema.json scripts/prepare.py "$app/Contents/Resources/"
"$root/scripts/build-art.sh" "$app/Contents/Resources"
"$root/scripts/make-cert.sh" >/dev/null
identity=$(security find-identity -p codesigning | awk '/"Shelf Local Code Signing"/ {print $2; exit}')
codesign --force --sign "$identity" --identifier org.tomfrench.shelf "$app"
codesign --verify --strict "$app"
pkill -x Shelf || true
rm -rf "$HOME/Applications/Shelf.app"
cp -R "$app" "$HOME/Applications/Shelf.app"
open "$HOME/Applications/Shelf.app"
echo "installed: $HOME/Applications/Shelf.app"
