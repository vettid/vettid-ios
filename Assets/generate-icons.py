#!/usr/bin/env python3
"""
VettID iOS App Icon Generator
Requires: Pillow (pip install Pillow)

Usage: python generate-icons.py [source-image]
Default source: vettid-icon-300.png
"""

import sys
import os
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Pillow not found. Install with: pip install Pillow")
    sys.exit(1)

# iOS icon specifications: (filename, size)
IOS_ICONS = [
    # iPhone
    ("icon-20@2x.png", 40),
    ("icon-20@3x.png", 60),
    ("icon-29@2x.png", 58),
    ("icon-29@3x.png", 87),
    ("icon-40@2x.png", 80),
    ("icon-40@3x.png", 120),
    ("icon-60@2x.png", 120),
    ("icon-60@3x.png", 180),
    # iPad
    ("icon-20.png", 20),
    ("icon-20@2x-ipad.png", 40),
    ("icon-29.png", 29),
    ("icon-29@2x-ipad.png", 58),
    ("icon-40.png", 40),
    ("icon-40@2x-ipad.png", 80),
    ("icon-76.png", 76),
    ("icon-76@2x.png", 152),
    ("icon-83.5@2x.png", 167),
    # App Store
    ("icon-1024.png", 1024),
]

def generate_icons(source_path: str, output_dir: str):
    """Generate all iOS app icon sizes from source image."""

    # Load source image
    print(f"Loading source image: {source_path}")
    img = Image.open(source_path)

    # Convert to RGBA if needed
    if img.mode != 'RGBA':
        img = img.convert('RGBA')

    # Ensure output directory exists
    os.makedirs(output_dir, exist_ok=True)

    print(f"Generating icons in: {output_dir}")

    for filename, size in IOS_ICONS:
        output_path = os.path.join(output_dir, filename)

        # High-quality resize using LANCZOS
        resized = img.resize((size, size), Image.LANCZOS)

        # Save as PNG
        resized.save(output_path, 'PNG', optimize=True)
        print(f"  Created: {filename} ({size}x{size})")

    print(f"\nDone! Generated {len(IOS_ICONS)} icons.")

def main():
    # Default paths
    script_dir = Path(__file__).parent
    source = sys.argv[1] if len(sys.argv) > 1 else str(script_dir / "vettid-icon-300.png")
    output_dir = str(script_dir.parent / "VettID" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset")

    if not os.path.exists(source):
        print(f"Error: Source image not found: {source}")
        print("Please provide a high-resolution PNG image (1024x1024 recommended)")
        sys.exit(1)

    generate_icons(source, output_dir)

if __name__ == "__main__":
    main()
