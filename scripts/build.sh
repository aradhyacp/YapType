#!/bin/zsh
# Builds Yaptype.app with the Swift command line tools (no Xcode needed) and installs it to /Applications.
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")/.."

swift build -c release 2>&1 | tail -3

BIN=.build/release
APP=dist/Yaptype.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Yaptype" "$APP/Contents/MacOS/Yaptype"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# A personal icon (not shipped) wins over the generic one when present.
if [ -f Resources/AppIcon-personal.icns ]; then cp Resources/AppIcon-personal.icns "$APP/Contents/Resources/AppIcon.icns"; else cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp README.md "$APP/Contents/Resources/README.md"
# SwiftPM resource bundles (FluidAudio ships one) must sit next to the binary's bundle resources.
for b in "$BIN"/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Dynamic frameworks from binary targets, if any.
for f in "$BIN"/*.framework "$BIN"/*.dylib; do
  [ -e "$f" ] || continue
  mkdir -p "$APP/Contents/Frameworks"; cp -R "$f" "$APP/Contents/Frameworks/"
done

# Identifier-based designated requirement so macOS keeps the Accessibility grant across rebuilds.
codesign --force --deep --sign - -r '=designated => identifier "com.yaptype.app"' "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Yaptype"' 2>/dev/null || true   # releases the microphone and saves the config
  sleep 1; pkill -x Yaptype || true
  rm -rf /Applications/Yaptype.app
  cp -R "$APP" /Applications/Yaptype.app
  echo "Installed /Applications/Yaptype.app"
fi
