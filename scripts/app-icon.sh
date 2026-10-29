#!/usr/bin/env bash
# Makes the non-production app icon (IOS-PLAN §8 I4) from the production one. AppIcon.png is the owner-supplied VettID
# app icon, used as is (never redrawn); the Debug, DevStack and Staging builds show it with vettid-android's
# non-production band (app/src/nonProduction/res/drawable/ic_launcher_background.xml): white across the bottom from 85
# of the adaptive icon's 108 units, which is 953 of the 1024 pixels of its visible 72-unit square, below the rook and
# its clear space. Opaque, as App Store Connect requires. Needs ImageMagick; run it after replacing AppIcon.png and
# commit the result.
set -euo pipefail
cd "$(dirname "$0")/../App/Assets.xcassets"

magick AppIcon.appiconset/AppIcon.png -fill '#FFFFFF' -draw 'rectangle 0,953 1023,1023' -alpha off -strip \
  "PNG24:AppIcon-NonProduction.appiconset/AppIcon-NonProduction.png"
echo App/Assets.xcassets/AppIcon-NonProduction.appiconset/AppIcon-NonProduction.png
