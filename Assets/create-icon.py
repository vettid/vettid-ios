#!/usr/bin/env python3
"""
Create app icon from VettID logo by cropping to just the tower.
"""

import sys
import os
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("Pillow not found. Install with: pip install Pillow")
    sys.exit(1)

def create_icon(source_path: str, output_path: str):
    """Crop the logo to just the castle tower for app icon use."""

    print(f"Loading source image: {source_path}")
    img = Image.open(source_path)

    # Convert to RGBA
    if img.mode != 'RGBA':
        img = img.convert('RGBA')

    width, height = img.size
    print(f"Original size: {width}x{height}")

    # The tower occupies roughly:
    # - Top: ~17% of image
    # - Bottom: ~60% of image (before text starts)
    # - Horizontally centered, about 32% width

    # For 1024x1024:
    # Tower top: ~175px
    # Tower bottom: ~615px
    # Tower height: ~440px
    # Tower width: ~330px (centered)

    # Tower only - precise crop without any text
    # Looking at the image: tower from ~17% to ~56% vertically
    tower_top = int(height * 0.17)
    tower_bottom = int(height * 0.56)
    tower_height = tower_bottom - tower_top

    # Make square
    square_size = int(tower_height * 1.1)  # Small padding

    center_x = width // 2
    center_y = (tower_top + tower_bottom) // 2

    left = center_x - square_size // 2
    top = center_y - square_size // 2
    right = left + square_size
    bottom = top + square_size

    # Ensure bounds
    left = max(0, left)
    top = max(0, top)
    right = min(width, right)
    bottom = min(height, bottom)

    print(f"Cropping to: ({left}, {top}, {right}, {bottom})")

    cropped = img.crop((left, top, right, bottom))

    # Resize to 1024x1024 for high quality source
    cropped = cropped.resize((1024, 1024), Image.LANCZOS)

    # Save
    cropped.save(output_path, 'PNG', optimize=True)
    print(f"Saved icon to: {output_path}")

def main():
    script_dir = Path(__file__).parent
    source = str(Path.home() / "Sites/vettid-scaffold-with-gsi/cdk/frontend/assets/logo.jpg")
    output = str(script_dir / "vettid-icon-1024.png")

    if len(sys.argv) > 1:
        source = sys.argv[1]

    create_icon(source, output)

if __name__ == "__main__":
    main()
