#!/bin/bash
# Builds the bodycam menu bar app: the SwiftUI front end in app/ with the Go engine inside it.
#
#   tools/build-app.sh       -> app/.build/bodycam.app
#
# The engine goes to Contents/MacOS/bodycam and the app to Contents/MacOS/bodycam-app.
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(sed -n 's/^## \([0-9][0-9.]*\).*/\1/p' CHANGELOG.md | head -1)"
build="app/.build"
app="$build/bodycam.app"
rm -rf "$app" "$build/AppIcon.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

for arch in arm64 amd64; do
  GOOS=darwin GOARCH=$arch CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$build/bodycam-$arch" .
done
lipo -create -output "$app/Contents/MacOS/bodycam" "$build/bodycam-arm64" "$build/bodycam-amd64"

archs=(--arch arm64 --arch x86_64)
if ! (cd app && swift build -c release "${archs[@]}"); then
  echo "universal Swift build failed, building for arm64 only" >&2
  archs=(--arch arm64)
  (cd app && swift build -c release "${archs[@]}")
fi
cp "$(cd app && swift build -c release "${archs[@]}" --show-bin-path)/bodycam-app" "$app/Contents/MacOS/bodycam-app"

install -m 755 examples/sketchy-agent.sh "$app/Contents/Resources/sketchy-agent"

icon="app/Resources/AppIcon.png"
chrome="${CHROME:-/Applications/Chromium.app/Contents/MacOS/Chromium}"
if [ ! -f "$icon" ] || { [ assets/icon.svg -nt "$icon" ] && [ -x "$chrome" ]; }; then
  # macOS icon grid: the 824 px tile sits in a 1024 px canvas with room for its shadow.
  page="$PWD/$build/icon.html"
  printf '<body style="margin:0"><img src="%s" style="position:absolute;left:100px;top:100px;width:824px;height:824px;filter:drop-shadow(0 14px 18px rgba(0,0,0,.3))"></body>' \
    "file://$PWD/assets/icon.svg" > "$page"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$PWD/$icon" "file://$page" 2>/dev/null
  rm "$page"
fi
mkdir -p "$build/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$icon" --out "$build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$icon" --out "$build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>bodycam-app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>io.github.omlahore.bodycam</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>bodycam</string>
  <key>CFBundleDisplayName</key><string>bodycam</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app/Contents/MacOS/bodycam"
codesign --force --sign - "$app"
codesign --verify --strict --deep "$app"
echo "$app ($version, $(lipo -archs "$app/Contents/MacOS/bodycam-app"))"
