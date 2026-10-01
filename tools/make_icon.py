# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Render the app icon master from the artwork.

    uv run tools/make_icon.py

Reads Assets/AppIcon-art.jpeg (full-bleed square artwork) and writes Assets/AppIcon.png:
1024x1024 with the artwork scaled to the 824 px body of the macOS icon grid and cut to a
rounded rectangle (radius 185 px, the shape macOS 26 treats as standard), transparent around
it. scripts/bundle.sh builds the .icns from it.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
CANVAS = 1024
BODY = 824  # macOS (Big Sur and later) icon grid: body size within the 1024 canvas
# A plain rounded rectangle with this radius is what macOS 26 recognises as the standard icon
# shape; a superellipse mask made it shrink the artwork onto a gray plate ("icon jail").
CORNER_RADIUS = 185
SUPERSAMPLE = 4


def rounded_mask(size: int) -> Image.Image:
    big = size * SUPERSAMPLE
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, big - 1, big - 1), CORNER_RADIUS * SUPERSAMPLE, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def main() -> None:
    art = Image.open(ROOT / "Assets/AppIcon-art.jpeg").convert("RGB").resize((BODY, BODY), Image.LANCZOS)
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    icon.paste(art, (offset, offset), rounded_mask(BODY))
    icon.save(ROOT / "Assets/AppIcon.png")
    print(ROOT / "Assets/AppIcon.png")


if __name__ == "__main__":
    main()
