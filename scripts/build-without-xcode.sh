#!/bin/bash
#
# Build Vibe Notch without Xcode.
#
# The normal build needs full Xcode (~20 GB) for xcodebuild. This script builds
# the app with the Swift compiler that ships with Command Line Tools instead,
# by compiling the sources directly — no xcodebuild, and no SwiftPM either
# (the SwiftPM bundled with Command Line Tools is frequently broken).
#
# To make that possible it produces a REDUCED build, assembled in a temporary
# staging copy. Your working tree is never modified. The reductions:
#
#   * Sparkle removed      -> no auto-update. A locally built, ad-hoc signed app
#                             must not replace itself with a signed upstream release.
#   * Mixpanel removed     -> no analytics.
#   * swift-markdown       -> replaced by Foundation's built-in AttributedString
#                             markdown parsing, so there are no package dependencies.
#   * #Preview blocks      -> stripped; the macro needs an Xcode plugin.
#
# Everything else — the notch UI, hooks, session monitoring, permission
# approvals — is the unmodified app.
#
# Usage:  ./scripts/build-without-xcode.sh [output-dir]
# Result: "<output-dir>/Vibe Notch Local.app"  (default output-dir: ./build)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="${1:-$PROJECT_DIR/build}"
STAGE="$(mktemp -d)"
APP="$OUT_DIR/Vibe Notch Local.app"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

echo "=== Vibe Notch — build without Xcode ==="

command -v swiftc >/dev/null 2>&1 || {
    echo "ERROR: swiftc not found. Install Command Line Tools:  xcode-select --install" >&2
    exit 1
}
echo "Swift: $(swiftc --version | head -1)"

# ---------------------------------------------------------------- stage sources
echo "Staging sources..."
mkdir -p "$STAGE/src"
cp -R "$PROJECT_DIR/ClaudeIsland/." "$STAGE/src/"
rm -rf "$STAGE/src/Assets.xcassets" "$STAGE/src/Info.plist"
rm -f  "$STAGE/src/Resources/ClaudeIsland.entitlements"
rm -f  "$STAGE/src/Services/Update/NotchUserDriver.swift"   # Sparkle-backed

# ------------------------------------------------- strip external dependencies
echo "Removing Sparkle / Mixpanel / swift-markdown..."
python3 - "$STAGE/src" <<'PYEOF'
import re, sys, os, glob

root = sys.argv[1]

def rewrite(rel, fn):
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        return
    s = open(p).read()
    out = fn(s)
    if out != s:
        open(p, "w").write(out)

def strip_appdelegate(s):
    s = s.replace("import Mixpanel\n", "").replace("import Sparkle\n", "")
    s = s.replace("    let updater: SPUUpdater\n", "")
    s = s.replace("    private let userDriver: NotchUserDriver\n", "")
    s = re.sub(r"    override init\(\) \{.*?\n    \}\n",
               "    override init() {\n        super.init()\n        AppDelegate.shared = self\n    }\n",
               s, count=1, flags=re.S)
    # Mixpanel calls, including multi-line dictionary arguments
    s = re.sub(r"[ \t]*Mixpanel\.[^\n]*\(\s*\[.*?\]\s*\)\n", "", s, flags=re.S)
    s = re.sub(r"[ \t]*Mixpanel\.[^\n]*\n", "", s)
    s = re.sub(r"[ \t]*let distinctId = getOrCreateDistinctId\(\)\n", "", s)
    # values that only fed analytics
    for dead in (
        '        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"\n',
        '        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"\n',
        '        let osVersion = Foundation.ProcessInfo.processInfo.operatingSystemVersionString\n',
        '            "app_version": version,\n            "build_number": build,\n            "macos_version": osVersion\n        ])\n',
    ):
        s = s.replace(dead, "")
    # Sparkle updater usage
    s = re.sub(r"[ \t]*if updater\.canCheckForUpdates \{\n[^}]*\}\n", "", s)
    s = re.sub(r"[ \t]*updateCheckTimer = Timer\.scheduledTimer.*?\n[ \t]*\}\n", "", s, flags=re.S)
    # AppKit-owning types must be main-actor when compiled outside Xcode's defaults
    s = s.replace("class AppDelegate: NSObject, NSApplicationDelegate {",
                  "@MainActor\nclass AppDelegate: NSObject, NSApplicationDelegate {")
    return s

rewrite("App/AppDelegate.swift", strip_appdelegate)
rewrite("Services/State/SessionStore.swift",
        lambda s: re.sub(r"[ \t]*Mixpanel\.[^\n]*\n", "", s.replace("import Mixpanel\n", "")))
rewrite("UI/Views/NotchMenuView.swift", lambda s: s.replace("import Sparkle\n", ""))
rewrite("App/WindowManager.swift",
        lambda s: s.replace("\nclass WindowManager {", "\n@MainActor\nclass WindowManager {"))

# #Preview needs an Xcode macro plugin — remove the blocks, matching braces.
for p in glob.glob(os.path.join(root, "**/*.swift"), recursive=True):
    s = open(p).read()
    if "#Preview" not in s:
        continue
    out, i = [], 0
    while True:
        m = re.search(r"#Preview[^\{]*\{", s[i:])
        if not m:
            out.append(s[i:])
            break
        out.append(s[i:i + m.start()])
        j = i + m.end() - 1
        depth = 0
        while j < len(s):
            if s[j] == '{':
                depth += 1
            elif s[j] == '}':
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            j += 1
        i = j
    open(p, "w").write("".join(out))
PYEOF

# swift-markdown -> Foundation, and a no-op updater so the settings UI still builds
cp "$SCRIPT_DIR/no-xcode/MarkdownRenderer.swift"  "$STAGE/src/UI/Components/MarkdownRenderer.swift"
cp "$SCRIPT_DIR/no-xcode/UpdateManagerStub.swift" "$STAGE/src/Services/Update/UpdateManagerStub.swift"

# ---------------------------------------------------------------------- compile
echo "Compiling $(find "$STAGE/src" -name '*.swift' | wc -l | tr -d ' ') Swift files..."
mkdir -p "$STAGE/out"
swiftc -O -parse-as-library -swift-version 5 \
    -target arm64-apple-macosx15.0 \
    -o "$STAGE/out/VibeNotch" \
    $(find "$STAGE/src" -name '*.swift')

# ------------------------------------------------------------------ app bundle
echo "Assembling app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$STAGE/out/VibeNotch" "$APP/Contents/MacOS/VibeNotch"
cp "$STAGE/src/Resources/claude-island-state.py" "$APP/Contents/Resources/"

# App icon. Xcode would compile Assets.xcassets with actool, which Command Line
# Tools does not ship, so build an .icns from the same PNGs with iconutil.
ICON_SRC="$PROJECT_DIR/ClaudeIsland/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICON_SRC" ] && command -v iconutil >/dev/null 2>&1; then
    ICONSET="$STAGE/AppIcon.iconset"
    mkdir -p "$ICONSET"
    # iconutil requires this exact naming; @2x entries reuse the next size up.
    cp "$ICON_SRC/icon_16x16.png"     "$ICONSET/icon_16x16.png"
    cp "$ICON_SRC/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
    cp "$ICON_SRC/icon_32x32.png"     "$ICONSET/icon_32x32.png"
    cp "$ICON_SRC/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
    cp "$ICON_SRC/icon_128x128.png"   "$ICONSET/icon_128x128.png"
    cp "$ICON_SRC/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
    cp "$ICON_SRC/icon_256x256.png"   "$ICONSET/icon_256x256.png"
    cp "$ICON_SRC/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
    cp "$ICON_SRC/icon_512x512.png"   "$ICONSET/icon_512x512.png"
    cp "$ICON_SRC/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
    if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        echo "  app icon: built from Assets.xcassets"
    else
        echo "  app icon: iconutil failed, continuing without one" >&2
    fi
else
    echo "  app icon: skipped (no iconutil or no icon assets)" >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vibe Notch Local</string>
    <key>CFBundleDisplayName</key><string>Vibe Notch Local</string>
    <key>CFBundleIdentifier</key><string>com.celestial.ClaudeIsland</string>
    <key>CFBundleExecutable</key><string>VibeNotch</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>local</string>
    <key>CFBundleShortVersionString</key><string>local</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Apache 2.0 — local build: no telemetry, no auto-update</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null 2>&1

echo ""
echo "=== Done ==="
echo "  $APP"
echo ""
echo "Run it:   open \"$APP\""
echo "Note:     quit any installed Vibe Notch first — both use /tmp/claude-island.sock"
