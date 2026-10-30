#!/bin/zsh
# Installs the latest Lina into /Applications and opens it.
#   curl -fsSL https://sppdd.github.io/lina/install.sh | zsh
# Lina isn't notarized yet. Downloading with curl, unlike a browser, doesn't mark the app as "from the internet",
# so macOS opens it without the "could not verify" warning. Read this script first if you like: it's short.
set -euo pipefail

URL="https://github.com/Sppdd/lina/releases/latest/download/Lina.zip"
DEST="/Applications/Lina.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[[ "$(uname -m)" == "arm64" ]] || { echo "Lina needs a Mac with Apple Silicon."; exit 1; }

echo "› Downloading Lina"
curl -fsSL "$URL" -o "$TMP/Lina.zip"
ditto -x -k "$TMP/Lina.zip" "$TMP"

# Make sure it's Lina before it goes into Applications.
id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$TMP/Lina.app/Contents/Info.plist" 2>/dev/null || true)
[[ "$id" == "app.lina.mac" ]] || { echo "The download isn't Lina. Nothing was installed."; exit 1; }
codesign --verify "$TMP/Lina.app" || { echo "Lina's signature didn't check out. Nothing was installed."; exit 1; }

if pgrep -xq Lina; then
  echo "› Quitting the Lina that's running"
  osascript -e 'quit app "Lina"' 2>/dev/null || true
  sleep 1
fi

echo "› Installing to $DEST"
rm -rf "$DEST"
ditto "$TMP/Lina.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DEST/Contents/Info.plist")
echo "✓ Lina $version is installed. Opening it now."
open "$DEST"
