"""Composites the app icon (plate) with a small badge for the Android
home-screen widget's tap targets -- icon-only, no text label. The widget has
two: "capture" (camera badge, launches straight into Basic-mode capture) and
"advanced" (tune/sliders badge, launches Advanced Setup), shown side by side
once the operator resizes the widget wider than its default compact size.

Requires: pip install pillow (run assets/branding/gen_icons.py first so
app_icon_colour_master.png is up to date).

Usage: python3 assets/branding/gen_widget_icon.py   (run from the repo root)
"""
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MASTER = os.path.join(HERE, "app_icon_colour_master.png")
ANDROID_RES = os.path.join(REPO_ROOT, "android/app/src/main/res")

TEAL = (27, 111, 104, 255)  # #1B6F68, matches the old widget gradient's dark stop
TEAL_LIGHT = (77, 192, 164, 255)  # #4DC0A4, matches its light stop
WHITE = (255, 255, 255, 255)


def _base_with_badge(size):
    """Plate art plus the empty badge circle (white ring + teal fill) that
    every widget icon variant draws its glyph on top of."""
    base = Image.open(MASTER).convert("RGBA").resize((size, size), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(base)
    draw = ImageDraw.Draw(canvas)

    badge_d = int(size * 0.50)
    cx, cy = int(size * 0.755), int(size * 0.755)
    r = badge_d // 2

    # White ring behind the badge for contrast against both the navy corner
    # and the tan plate art, then the teal badge fill on top.
    draw.ellipse(
        [cx - r - int(size * 0.018), cy - r - int(size * 0.018), cx + r + int(size * 0.018), cy + r + int(size * 0.018)],
        fill=WHITE,
    )
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=TEAL_LIGHT)
    draw.ellipse(
        [cx - r + int(size * 0.012), cy - r + int(size * 0.012), cx + r - int(size * 0.012), cy + r - int(size * 0.012)],
        fill=TEAL,
    )
    return canvas, draw, cx, cy, badge_d


def build_capture(size=1024):
    """Basic Capture: plate + camera badge (viewfinder bump + lens ring)."""
    canvas, draw, cx, cy, badge_d = _base_with_badge(size)

    body_w, body_h = badge_d * 0.56, badge_d * 0.42
    body_cx, body_cy = cx, cy + badge_d * 0.06
    body_box = [body_cx - body_w / 2, body_cy - body_h / 2, body_cx + body_w / 2, body_cy + body_h / 2]
    draw.rounded_rectangle(body_box, radius=body_h * 0.22, fill=WHITE)

    bump_w, bump_h = badge_d * 0.22, badge_d * 0.10
    bump_box = [
        body_cx - bump_w / 2,
        body_cy - body_h / 2 - bump_h * 0.65,
        body_cx + bump_w / 2,
        body_cy - body_h / 2 + bump_h * 0.35,
    ]
    draw.rounded_rectangle(bump_box, radius=bump_h * 0.3, fill=WHITE)

    lens_r = body_h * 0.34
    draw.ellipse([body_cx - lens_r, body_cy - lens_r, body_cx + lens_r, body_cy + lens_r], fill=TEAL)
    lens_inner_r = lens_r * 0.55
    draw.ellipse(
        [body_cx - lens_inner_r, body_cy - lens_inner_r, body_cx + lens_inner_r, body_cy + lens_inner_r], fill=WHITE
    )
    return canvas


def build_advanced(size=1024):
    """Advanced Setup: plate + tune/sliders badge -- three horizontal rails
    with staggered handles, matching the in-app options chip's tune icon."""
    canvas, draw, cx, cy, badge_d = _base_with_badge(size)

    rail_w = badge_d * 0.50
    rail_x0, rail_x1 = cx - rail_w / 2, cx + rail_w / 2
    rail_stroke = badge_d * 0.045
    handle_r = badge_d * 0.075
    # Handle position along each rail alternates side to side, the standard
    # "equalizer sliders" look -- fractions of the rail's own width.
    handle_fractions = (0.32, 0.68, 0.44)

    for i, frac in enumerate(handle_fractions):
        rail_y = cy + (i - 1) * badge_d * 0.19
        draw.line([(rail_x0, rail_y), (rail_x1, rail_y)], fill=WHITE, width=max(1, round(rail_stroke)))
        handle_x = rail_x0 + rail_w * frac
        draw.ellipse(
            [handle_x - handle_r, rail_y - handle_r, handle_x + handle_r, rail_y + handle_r],
            fill=WHITE,
        )
        draw.ellipse(
            [handle_x - handle_r * 0.45, rail_y - handle_r * 0.45, handle_x + handle_r * 0.45, rail_y + handle_r * 0.45],
            fill=TEAL,
        )
    return canvas


def save_resized(img, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path)


def main():
    capture = build_capture(1024)
    capture.save(os.path.join(HERE, "widget_capture_icon.png"))
    advanced = build_advanced(1024)
    advanced.save(os.path.join(HERE, "widget_advanced_capture_icon.png"))

    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        save_resized(capture, f"{ANDROID_RES}/drawable-{density}/ic_widget_launcher.png", size)
        save_resized(advanced, f"{ANDROID_RES}/drawable-{density}/ic_widget_launcher_advanced.png", size)
    print("Done.")


if __name__ == "__main__":
    main()
