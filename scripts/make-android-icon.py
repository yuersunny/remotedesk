#!/usr/bin/env python3
"""Draw the Android launcher icon instead of shipping the default Flutter one.

Run from anywhere:  python3 scripts/make-android-icon.py

Writes legacy `mipmap-*/ic_launcher.png` plus the adaptive-icon layers
(`ic_launcher_foreground.png` per density and a background colour). Everything
is rendered at 1024 and downsampled so the curves stay smooth at 48 px.

Why a script rather than a checked-in PNG only: the mark has to survive five
densities and two icon systems, and hand-editing five files is how icons end up
inconsistent between launchers.
"""

from __future__ import annotations

import pathlib
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - guidance instead of a traceback
    sys.exit("需要 Pillow：python3 -m pip install pillow")

ROOT = pathlib.Path(__file__).resolve().parent.parent
RES = ROOT / "app" / "android" / "app" / "src" / "main" / "res"

BASE = 1024
NAVY_TOP = (11, 21, 34)
NAVY_BOTTOM = (22, 38, 61)
WHITE = (245, 248, 252)
SCREEN = (27, 58, 92)
ACCENT = (96, 165, 250)

# Densities Android asks for: folder -> icon px, adaptive foreground px (108dp).
DENSITIES = {
    "mipmap-mdpi": (48, 108),
    "mipmap-hdpi": (72, 162),
    "mipmap-xhdpi": (96, 216),
    "mipmap-xxhdpi": (144, 324),
    "mipmap-xxxhdpi": (192, 432),
}


def gradient(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size), NAVY_TOP)
    draw = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(1, size - 1)
        colour = tuple(
            round(NAVY_TOP[i] + (NAVY_BOTTOM[i] - NAVY_TOP[i]) * t) for i in range(3)
        )
        draw.line([(0, y), (size, y)], fill=colour)
    return img


def draw_mark(img: Image.Image, box: tuple[float, float, float, float]) -> None:
    """Monitor outline, stand and a blue cursor, fitted into `box`."""
    draw = ImageDraw.Draw(img)
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0

    screen_h = h * 0.66
    radius = w * 0.10
    stroke = max(2.0, w * 0.055)
    draw.rounded_rectangle(
        [x0, y0, x1, y0 + screen_h], radius=radius, fill=SCREEN, outline=WHITE,
        width=int(stroke),
    )

    # Taskbar strip, so the shape reads as a computer and not a television.
    draw.rounded_rectangle(
        [x0 + stroke, y0 + screen_h * 0.80, x1 - stroke, y0 + screen_h - stroke],
        radius=radius * 0.45,
        fill=ACCENT,
    )

    # Stand.
    neck_w = w * 0.12
    cx = (x0 + x1) / 2
    neck_top = y0 + screen_h
    draw.rectangle(
        [cx - neck_w / 2, neck_top, cx + neck_w / 2, neck_top + h * 0.14],
        fill=WHITE,
    )
    draw.rounded_rectangle(
        [cx - w * 0.24, neck_top + h * 0.14, cx + w * 0.24, y1],
        radius=h * 0.035,
        fill=WHITE,
    )

    # Cursor: the one detail that says "remote control" rather than "display".
    px, py = x0 + w * 0.62, y0 + screen_h * 0.20
    s = w * 0.22
    draw.polygon(
        [(px, py), (px, py + s), (px + s * 0.28, py + s * 0.74), (px + s * 0.52, py + s * 0.70)],
        fill=WHITE,
    )
    draw.polygon(
        [(px + s * 0.16, py + s * 0.30), (px + s * 0.16, py + s * 0.62),
         (px + s * 0.38, py + s * 0.58)],
        fill=NAVY_BOTTOM,
    )


def legacy(size: int) -> Image.Image:
    img = gradient(BASE)
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([0, 0, BASE - 1, BASE - 1], radius=BASE * 0.22, fill=None)
    draw_mark(img, (BASE * 0.17, BASE * 0.26, BASE * 0.83, BASE * 0.74))
    return img.resize((size, size), Image.LANCZOS)


def foreground(size: int) -> Image.Image:
    """Adaptive foreground: transparent, and only the middle 66 % is safe."""
    img = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    draw_mark(img, (BASE * 0.27, BASE * 0.33, BASE * 0.73, BASE * 0.67))
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    for folder, (icon_px, fg_px) in DENSITIES.items():
        target = RES / folder
        target.mkdir(parents=True, exist_ok=True)
        legacy(icon_px).save(target / "ic_launcher.png")
        foreground(fg_px).save(target / "ic_launcher_foreground.png")
        print(f"{folder}: ic_launcher {icon_px}px, foreground {fg_px}px")

    values = RES / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="ic_launcher_background">#0B1522</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n",
        encoding="utf-8",
    )
    print("adaptive icon written")


if __name__ == "__main__":
    main()
