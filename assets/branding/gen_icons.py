"""Regenerates the app/notification/widget icons from the source SVGs in
assets/branding/source/. Requires: pip install pillow cairosvg numpy.

Usage: python3 assets/branding/gen_icons.py   (run from the repo root)
"""
import os
import io
import xml.etree.ElementTree as ET

import cairosvg
import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
COLOUR_SVG = os.path.join(HERE, "source", "coloured_logo_svg.svg")
BW_SVG = os.path.join(HERE, "source", "black_white_svg.svg")
NAVY = (0x00, 0x00, 0x80, 0xFF)

ANDROID_RES = os.path.join(REPO_ROOT, "android/app/src/main/res")
IOS_ICONSET = os.path.join(REPO_ROOT, "ios/Runner/Assets.xcassets/AppIcon.appiconset")
WEB_ROOT = os.path.join(REPO_ROOT, "web")

ET.register_namespace("", "http://www.w3.org/2000/svg")
ET.register_namespace("inkscape", "http://www.inkscape.org/namespaces/inkscape")
ET.register_namespace("sodipodi", "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd")


def render_svg_no_bg(svg_path, width=1024):
    """Render an SVG to a square RGBA canvas with the id=path2 background
    shape removed, artwork inset to roughly 62% (adaptive-icon safe zone)."""
    tree = ET.parse(svg_path)
    root = tree.getroot()
    for el in list(root):
        if el.get("id") == "path2":
            root.remove(el)
    buf = io.BytesIO()
    tree.write(buf)
    buf.seek(0)
    png_bytes = cairosvg.svg2png(bytestring=buf.read(), output_width=width)
    img = Image.open(io.BytesIO(png_bytes)).convert("RGBA")
    img = pad_to_square(img)  # viewBox is 448x430, not quite square
    bbox = img.getbbox()
    if bbox is None:
        return img
    cropped = img.crop(bbox)
    target = int(width * 0.62)
    scale = target / max(cropped.size)
    new_size = (max(1, round(cropped.width * scale)), max(1, round(cropped.height * scale)))
    resized = cropped.resize(new_size, Image.LANCZOS)
    canvas = Image.new("RGBA", (width, width), (0, 0, 0, 0))
    offset = ((width - new_size[0]) // 2, (width - new_size[1]) // 2)
    canvas.paste(resized, offset, resized)
    return canvas


def pad_to_square(img):
    w, h = img.size
    side = max(w, h)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(img, ((side - w) // 2, (side - h) // 2), img)
    return canvas


def render_full_icon(svg_path, width=1024):
    png_bytes = cairosvg.svg2png(url=svg_path, output_width=width)
    img = Image.open(io.BytesIO(png_bytes)).convert("RGBA")
    return pad_to_square(img)


def flatten_on_navy(img):
    bg = Image.new("RGBA", img.size, NAVY)
    bg.alpha_composite(img)
    return bg.convert("RGB")


def alpha_to_white(img, alpha_threshold=40):
    """Collapse any opaque ink (regardless of its own RGB) to solid white on
    transparent -- the source's black/near-black paths are compound shapes
    whose 'white' look comes from unfilled negative space, not literal white
    fills, so this must key off alpha, not luminance."""
    arr = np.array(img.convert("RGBA"), dtype=np.uint8)
    out = np.zeros_like(arr)
    keep = arr[..., 3] > alpha_threshold
    out[keep] = (255, 255, 255, 255)
    return Image.fromarray(out, mode="RGBA")


def simplify_for_tiny_size(img, dilate=61):
    """The full illustration (fine grid + small blobs) turns to noise once
    downsampled to a 24px status-bar icon. Dilate the alpha mask so it
    survives as a bold, simplified glyph at that one small size."""
    alpha = img.split()[-1].filter(ImageFilter.MaxFilter(dilate))
    arr = np.zeros((*alpha.size[::-1], 4), dtype=np.uint8)
    arr[..., 3] = np.array(alpha)
    arr[..., 0:3] = 255
    return Image.fromarray(arr, mode="RGBA")


def save_resized(img, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path)


def main():
    print("Rendering masters...")
    colour_full = render_full_icon(COLOUR_SVG, 1024)
    colour_fg = render_svg_no_bg(COLOUR_SVG, 1024)
    bw_fg_ink = render_svg_no_bg(BW_SVG, 1024)
    bw_silhouette = alpha_to_white(bw_fg_ink)

    colour_full.save(os.path.join(HERE, "app_icon_colour_master.png"))
    colour_fg.save(os.path.join(HERE, "app_icon_colour_foreground.png"))
    render_full_icon(BW_SVG, 1024).save(os.path.join(HERE, "app_icon_bw_master.png"))
    bw_silhouette.save(os.path.join(HERE, "notification_icon_silhouette.png"))

    # ---- Android legacy launcher icons (colour) ----
    for density, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        save_resized(colour_full, f"{ANDROID_RES}/mipmap-{density}/ic_launcher.png", size)

    # ---- Android adaptive icon foreground (colour) ----
    for density, size in {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}.items():
        save_resized(colour_fg, f"{ANDROID_RES}/mipmap-{density}/ic_launcher_foreground.png", size)

    # ---- Android notification icon (b/w silhouette) ----
    # At true 24px (mdpi) the fine grid lines alias into noise, so mdpi gets a
    # dilated/simplified glyph; hdpi and up downsample the full illustration fine.
    bw_silhouette_tiny = simplify_for_tiny_size(bw_silhouette)
    for density, size in {"mdpi": 24, "hdpi": 36, "xhdpi": 48, "xxhdpi": 72, "xxxhdpi": 96}.items():
        source = bw_silhouette_tiny if density == "mdpi" else bw_silhouette
        save_resized(source, f"{ANDROID_RES}/drawable-{density}/ic_stat_notify.png", size)

    # Android home-screen widget icon: see gen_widget_icon.py, which
    # composites this same colour master with a capture badge into
    # ic_widget_launcher.png (replaces the old plain-silhouette icon here).

    # ---- iOS AppIcon.appiconset (colour, flattened onto opaque navy) ----
    ios_master = flatten_on_navy(colour_full)
    ios_files = {
        "Icon-App-20x20@1x.png": 20, "Icon-App-20x20@2x.png": 40, "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29, "Icon-App-29x29@2x.png": 58, "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40, "Icon-App-40x40@2x.png": 80, "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120, "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76, "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167, "Icon-App-1024x1024@1x.png": 1024,
    }
    for fname, size in ios_files.items():
        save_resized(ios_master, f"{IOS_ICONSET}/{fname}", size)

    # ---- Web / PWA icons (colour) ----
    # "any"-purpose icons use the full flattened master (has its own
    # rounded-square padding baked in); maskable icons instead flatten the
    # *foreground* render, which is already inset to the 62% adaptive-icon
    # safe zone, so OS-applied circle/squircle masks don't crop the art.
    web_master = flatten_on_navy(colour_full)
    web_maskable = flatten_on_navy(colour_fg)
    save_resized(web_master, f"{WEB_ROOT}/favicon.png", 64)
    save_resized(web_master, f"{WEB_ROOT}/icons/Icon-192.png", 192)
    save_resized(web_master, f"{WEB_ROOT}/icons/Icon-512.png", 512)
    save_resized(web_maskable, f"{WEB_ROOT}/icons/Icon-maskable-192.png", 192)
    save_resized(web_maskable, f"{WEB_ROOT}/icons/Icon-maskable-512.png", 512)

    print("Done.")


if __name__ == "__main__":
    main()
