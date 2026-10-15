#!/bin/sh
# Builds "AI Tempomat.app" into ./build.
# --install also copies it to ~/Applications and launches it.
set -eu
cd "$(dirname "$0")/.."

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
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x AITempomat || true
    # Opening the app before the old one has quit fails (error -600).
    while pgrep -x AITempomat >/dev/null; do sleep 0.2; done
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/AI Tempomat.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/AI Tempomat.app"
    echo "Installed to ~/Applications and launched"
fi
