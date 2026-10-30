#!/bin/zsh
# Builds Lina.app (release) and Lina.zip into ./build. Usage: scripts/build-app.sh [--open]
# For a release others can open without a warning: SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=lina
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Lina.app
VERSION=${VERSION:-2.1.0}

echo "› Compiling"
swift build -c release --arch arm64 2>&1 | tail -1
BIN=$(swift build -c release --arch arm64 --show-bin-path)/Lina

# Lina's server (Supabase). The URL and publishable (anon) key are public by design and go into Info.plist,
# so people who download Lina just sign in. Taken from the environment, or from .env for local builds.
# Never put the service_role key or provider keys here; they live in Supabase secrets.
env_value() { [[ -f .env ]] && grep -E "^(export )?$1=" .env | tail -1 | cut -d= -f2- | tr -d "\"'" || true; }
SUPABASE_URL=${SUPABASE_URL:-$(env_value SUPABASE_URL)}
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY:-$(env_value SUPABASE_ANON_KEY)}
[[ -n "$SUPABASE_URL" ]] && echo "› Lina server: $SUPABASE_URL" || echo "› No SUPABASE_URL: this build uses developer keys"

echo "› Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lina"

if [[ ! -f build/AppIcon.icns ]]; then
  echo "› Drawing icon"
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lina</string>
  <key>CFBundleDisplayName</key><string>Lina</string>
  <key>CFBundleIdentifier</key><string>app.lina.mac</string>
  <key>CFBundleExecutable</key><string>Lina</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Open source under the MIT License.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSMicrophoneUsageDescription</key><string>Hold ⌃⌥ to say a command to Lina. Your voice is turned into text on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Lina turns what you say into a /lina command, on this Mac when your language supports it.</string>
  <key>LinaSupabaseURL</key><string>${SUPABASE_URL}</string>
  <key>LinaSupabaseAnonKey</key><string>${SUPABASE_ANON_KEY}</string>
</dict>
</plist>
PLIST

# Release builds for other people: set SIGN_IDENTITY to a "Developer ID Application" certificate and
# NOTARY_PROFILE to a notarytool keychain profile, and Lina is signed, notarized and stapled, so macOS opens it
# without a warning. Without them it's signed ad-hoc for this Mac.
SIGN_IDENTITY=${SIGN_IDENTITY:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-}
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "› Signing with $SIGN_IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --entitlements scripts/Lina.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=1 "$APP"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "› Notarizing (this takes a few minutes)"
    rm -f build/Lina-notarize.zip
    ditto -c -k --keepParent "$APP" build/Lina-notarize.zip
    xcrun notarytool submit build/Lina-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f build/Lina-notarize.zip
    spctl --assess --type execute --verbose "$APP"
  fi
else
  # Ad-hoc signatures change with every build, and macOS ties the Accessibility switch to the signature,
  # so pin the requirement to the bundle ID: the permission you granted survives rebuilds.
  echo "› Signing (ad-hoc, stable requirement)"
  codesign --force --deep --sign - --identifier app.lina.mac \
    --requirements '=designated => identifier "app.lina.mac"' "$APP" >/dev/null
fi

rm -f build/Lina.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" build/Lina.zip
echo "✓ Built $APP and build/Lina.zip"

if [[ "${1:-}" == "--open" ]]; then open "$APP"; fi
