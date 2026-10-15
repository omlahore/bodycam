#!/bin/sh
# Renders the PNGs in assets/ from their sources with a headless Chromium.
set -eu
cd "$(dirname "$0")/../assets"
chrome="${CHROME:-/Applications/Chromium.app/Contents/MacOS/Chromium}"
shot() { "$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --virtual-time-budget=8000 --window-size="$2" --screenshot="$PWD/$3" "file://$PWD/$1" 2>/dev/null; }
shot banner.html 1280,640 banner.png
printf '<body style="margin:0"><img src="icon.svg" width="512" height="512"></body>' > .icon.html
shot .icon.html 512,512 icon.png
rm .icon.html
