#!/bin/sh
# Builds "AI Tempomat.app" into ./build.
# --install also copies it to ~/Applications and launches it.
set -eu
cd "$(dirname "$0")/.."

# The release this checkout is, and where the app asks whether a newer one is out (empty: it
# never asks). version.json is the one place to change them.
VERSION="$(plutil -extract version raw -o - version.json)"
BUILD="$(plutil -extract build raw -o - version.json)"
CHECK_URL="$(plutil -extract checkURL raw -o - version.json 2>/dev/null || true)"
case "$BUILD" in
    ''|*[!0-9]*) echo "version.json: build must be a whole number, not '$BUILD'" >&2; exit 1 ;;
esac
# The branch, so the app compares itself with the latest release of the branch it was built from.
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build -c release

APP="build/AI Tempomat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AITempomat "$APP/Contents/MacOS/AITempomat"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AITempomat</string>
    <key>CFBundleIdentifier</key><string>local.ai-tempomat</string>
    <key>CFBundleName</key><string>AI Tempomat</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# plutil takes the values as they are, whatever characters the clone's path has.
PLIST="$APP/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -insert CFBundleVersion -string "$BUILD" "$PLIST"
if [ -n "$CHECK_URL" ]; then plutil -insert AITCheckURL -string "$CHECK_URL" "$PLIST"; fi
# The clone the app's Update button pulls and builds in.
plutil -insert AITSourceFolder -string "$PWD" "$PLIST"
if [ -n "$BRANCH" ]; then plutil -insert AITSourceBranch -string "$BRANCH" "$PLIST"; fi
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    # -a: when the app's Update button runs this script, the app is one of its ancestors, which
    # pkill and pgrep leave out otherwise. -U: only this user's; another user's copy can't be
    # quit from here, and waiting for it would never end.
    pkill -a -U "$(id -u)" -x AITempomat || true
    # Opening the app before the old one has quit fails (error -600).
    while pgrep -a -U "$(id -u)" -x AITempomat >/dev/null; do sleep 0.2; done
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/AI Tempomat.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/AI Tempomat.app"
    echo "Installed to ~/Applications and launched"
fi
