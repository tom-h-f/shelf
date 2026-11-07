#!/bin/zsh
# Render the SVG sources in Resources/art into the app's icon and menu bar template images.
set -euo pipefail
art=${0:A:h}/../Resources/art
out=$1
mkdir -p "$out"
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size "$art/logo.svg" -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$art/logo.svg" -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$out/AppIcon.icns"
for name in menubar menubar-busy logo; do
  rsvg-convert -f pdf "$art/$name.svg" -o "$out/$name.pdf"
done
