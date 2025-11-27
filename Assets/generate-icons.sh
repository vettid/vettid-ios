#!/bin/bash
# VettID iOS App Icon Generator
# Requires: ImageMagick (brew install imagemagick)
#
# Usage: ./generate-icons.sh [source-image]
# Default source: vettid-icon-300.png

set -e

SOURCE="${1:-vettid-icon-300.png}"
OUTPUT_DIR="../VettID/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SOURCE" ]; then
    echo "Source image not found: $SOURCE"
    echo "Please provide a 1024x1024 PNG image"
    exit 1
fi

echo "Generating iOS app icons from $SOURCE..."

# iPhone icons
convert "$SOURCE" -resize 40x40 "$OUTPUT_DIR/icon-20@2x.png"
convert "$SOURCE" -resize 60x60 "$OUTPUT_DIR/icon-20@3x.png"
convert "$SOURCE" -resize 58x58 "$OUTPUT_DIR/icon-29@2x.png"
convert "$SOURCE" -resize 87x87 "$OUTPUT_DIR/icon-29@3x.png"
convert "$SOURCE" -resize 80x80 "$OUTPUT_DIR/icon-40@2x.png"
convert "$SOURCE" -resize 120x120 "$OUTPUT_DIR/icon-40@3x.png"
convert "$SOURCE" -resize 120x120 "$OUTPUT_DIR/icon-60@2x.png"
convert "$SOURCE" -resize 180x180 "$OUTPUT_DIR/icon-60@3x.png"

# iPad icons
convert "$SOURCE" -resize 20x20 "$OUTPUT_DIR/icon-20.png"
convert "$SOURCE" -resize 40x40 "$OUTPUT_DIR/icon-20@2x-ipad.png"
convert "$SOURCE" -resize 29x29 "$OUTPUT_DIR/icon-29.png"
convert "$SOURCE" -resize 58x58 "$OUTPUT_DIR/icon-29@2x-ipad.png"
convert "$SOURCE" -resize 40x40 "$OUTPUT_DIR/icon-40.png"
convert "$SOURCE" -resize 80x80 "$OUTPUT_DIR/icon-40@2x-ipad.png"
convert "$SOURCE" -resize 76x76 "$OUTPUT_DIR/icon-76.png"
convert "$SOURCE" -resize 152x152 "$OUTPUT_DIR/icon-76@2x.png"
convert "$SOURCE" -resize 167x167 "$OUTPUT_DIR/icon-83.5@2x.png"

# App Store icon
convert "$SOURCE" -resize 1024x1024 "$OUTPUT_DIR/icon-1024.png"

echo "Done! Generated icons in $OUTPUT_DIR"
echo ""
echo "Icon sizes generated:"
ls -la "$OUTPUT_DIR"/*.png
