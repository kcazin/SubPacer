#!/usr/bin/env python3
"""Renders the README's images from the demo accounts: python3 docs/make-images.py [path/to/SubPacer.app]

Runs the app's snapshot mode (SUBPACER_DEMO, SUBPACER_SNAPSHOT) once per menu bar style and appearance,
then lays the captures out with Pillow (pip install pillow). Writes docs/images/.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "images"
APP = Path(sys.argv[1] if len(sys.argv) > 1 else "~/Applications/SubPacer.app").expanduser()
BINARY = APP / "Contents/MacOS/SubPacer"
FONT = "/System/Library/Fonts/SFNS.ttf"

# MenuBarStyle's raw values and titles, in settings order.
STYLES = [
    ("forecast", "Forecast graph"), ("ring", "Ring"), ("ringHeadroom", "Ring + headroom"),
    ("sessionWeekly", "Session | weekly"), ("perAccount", "Per account"), ("runway", "Mini runway"),
    ("battery", "Battery"), ("daily", "Day by day"), ("gauge", "Pace gauge"),
    ("headroom", "Headroom"), ("checkmark", "Checkmark"), ("percent", "Remaining %"),
]
# The menu bar strip DebugSnapshot draws behind the label.
BAR = {"light": (237, 237, 237), "dark": (41, 41, 41)}


def snapshot(tmp, name, appearance="light", style="forecast", sections=True, settings=False):
    """Captures the panel (or settings) and the menu bar label; returns their paths."""
    panel, label = tmp / f"{name}-panel.png", tmp / f"{name}-label.png"
    env = dict(os.environ, SUBPACER_DEMO="1", SUBPACER_APPEARANCE=appearance,
               SUBPACER_SNAPSHOT=str(panel), SUBPACER_MENUBAR=str(label))
    if settings:
        env["SUBPACER_SETTINGS"] = "1"
    show = "YES" if sections else "NO"
    subprocess.run([str(BINARY), "-menuBarStyle", style, "-menuBarCompact", "NO",
                    "-show.runway", "YES", "-show.accounts", "YES", "-show.tonight", show, "-show.proxy", show],
                   env=env, check=True, stdout=subprocess.DEVNULL)
    return Image.open(panel).convert("RGBA"), Image.open(label).convert("RGBA")


def font(size, weight=400):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_axes([100, 17, 400, weight])  # width, optical size, grade, weight
    except OSError:
        pass
    return f


def rounded(image, radius):
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *image.size), radius, fill=255)
    out = image.copy()
    out.putalpha(Image.composite(image.getchannel("A"), mask, mask))
    return out


def shadowed(canvas, image, x, y, blur=36, offset=18, opacity=90):
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    alpha = image.getchannel("A").point(lambda a: a * opacity // 255)
    shadow.paste((0, 0, 0, 255), (x, y + offset), alpha)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(image, (x, y))


def fade_bottom(image, height):
    alpha = image.getchannel("A")
    ramp = Image.linear_gradient("L").resize((image.width, height)).transpose(Image.FLIP_TOP_BOTTOM)
    bottom = Image.composite(alpha.crop((0, image.height - height, image.width, image.height)),
                             Image.new("L", (image.width, height), 0), ramp)
    alpha.paste(bottom, (0, image.height - height))
    image.putalpha(alpha)
    return image


def wallpaper(size, top, bottom):
    gradient = Image.linear_gradient("L").resize(size)
    return Image.composite(Image.new("RGBA", size, bottom), Image.new("RGBA", size, top), gradient)


def hero(panel, label, appearance):
    """The label in a menu bar on a desktop, the panel open under it, fading out below the first account."""
    w, h, bar_h = 1080, 1100, 48
    dark = appearance == "dark"
    canvas = wallpaper((w, h), (58, 72, 120) if dark else (196, 214, 245), (24, 28, 52) if dark else (236, 222, 240))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle((0, 0, w, bar_h), fill=BAR[appearance])
    ink = (235, 235, 235) if dark else (30, 30, 30)
    clock = "Sat 24 Oct  12:17"
    clock_font = font(26, 500)
    clock_w = draw.textlength(clock, font=clock_font)
    draw.text((w - 36 - clock_w, bar_h / 2), clock, font=clock_font, fill=ink, anchor="lm")
    label_x = int(w - 36 - clock_w - 40 - label.width)
    canvas.alpha_composite(label, (label_x, (bar_h - label.height) // 2))

    top = rounded(panel, 36).crop((0, 0, panel.width, h - bar_h - 12))
    panel_x = min(label_x + label.width // 2 - panel.width // 2, w - panel.width - 24)
    shadowed(canvas, fade_bottom(top, 260), panel_x, bar_h + 12)
    return canvas


def styles_grid(labels):
    """Every menu bar style on its own strip of menu bar, titled, on a transparent background."""
    cols, cell_w, cell_h, gap = 3, 420, 128, 24
    rows = -(-len(labels) // cols)
    canvas = Image.new("RGBA", (cols * cell_w + (cols - 1) * gap, rows * cell_h + (rows - 1) * gap), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    title_font = font(24, 500)
    for i, ((_, title), label) in enumerate(zip(STYLES, labels)):
        x, y = (i % cols) * (cell_w + gap), (i // cols) * (cell_h + gap)
        draw.rounded_rectangle((x, y, x + cell_w, y + 72), 18, fill=BAR["light"] + (255,))
        canvas.alpha_composite(label, (x + (cell_w - label.width) // 2, y + (72 - label.height) // 2))
        draw.text((x + cell_w / 2, y + 102), title, font=title_font, fill=(128, 128, 128), anchor="mm")
    return canvas


def card(panel, top, bottom):
    """One card of the panel, by its 2x pixel rows, with a little of the panel around it."""
    return rounded(panel.crop((12, top, panel.width - 12, bottom)), 40)


def main():
    if not BINARY.exists():
        sys.exit(f"No app at {APP}: run ./build.sh first, or pass the app's path")
    OUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for appearance in ("light", "dark"):
            panel, label = snapshot(tmp, f"hero-{appearance}", appearance, sections=False)
            hero(panel, label, appearance).save(OUT / f"hero-{appearance}.png", optimize=True)

        labels = [snapshot(tmp, style, style=style, sections=False)[1] for style, _ in STYLES]
        styles_grid(labels).save(OUT / "menubar-styles.png", optimize=True)

        # The panel's cards with every section shown: Runway, the first account, Tonight.
        panel, _ = snapshot(tmp, "full", "light")
        card(panel, 72, 402).save(OUT / "runway.png", optimize=True)
        card(panel, 394, 824).save(OUT / "account.png", optimize=True)
        card(panel, 1376, 1746).save(OUT / "tonight.png", optimize=True)

        settings, _ = snapshot(tmp, "settings", settings=True)
        rounded(settings, 36).save(OUT / "settings.png", optimize=True)


if __name__ == "__main__":
    main()
