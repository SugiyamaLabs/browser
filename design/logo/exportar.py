#!/usr/bin/env python3
"""Exports the logo SVGs to PNG, .icns (macOS) and .ico (Windows), dark and light.

Usage: python3 design/logo/exportar.py [path-to-chromium]
Renders each SVG at the exact pixel size with headless Chromium (transparent background, scale 1),
then packs the macOS iconset with Apple's iconutil and writes the .ico by hand (PNG entries).
"""
import os, struct, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "exportados"
CHROME = sys.argv[1] if len(sys.argv) > 1 else str(Path.home() / "browser-work/ungoogled-chromium-macos/build/src/out/Default/Chromium.app/Contents/MacOS/Chromium")

# macOS iconset: name -> pixel size
ICNS = {"icon_16x16": 16, "icon_16x16@2x": 32, "icon_32x32": 32, "icon_32x32@2x": 64, "icon_128x128": 128,
        "icon_128x128@2x": 256, "icon_256x256": 256, "icon_256x256@2x": 512, "icon_512x512": 512, "icon_512x512@2x": 1024}
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]


def render(svg: Path, size: int, dest: Path):
    """One SVG to a transparent PNG of exactly size x size."""
    with tempfile.TemporaryDirectory() as tmp:
        page = Path(tmp) / "p.html"
        page.write_text(f'<!doctype html><style>html,body{{margin:0;background:transparent}}img{{display:block;width:{size}px;height:{size}px}}</style><img src="{svg.as_uri()}">')
        subprocess.run([CHROME, "--headless=new", "--no-first-run", "--use-mock-keychain", "--hide-scrollbars",
                        "--force-device-scale-factor=1", "--default-background-color=00000000",
                        f"--window-size={size},{size}", f"--user-data-dir={tmp}/profile",
                        "--allow-file-access-from-files", f"--screenshot={dest}", page.as_uri()],
                       check=True, capture_output=True, timeout=60)
    assert dest.exists() and dest.stat().st_size > 0, dest


def write_ico(pngs: list[tuple[int, Path]], dest: Path):
    """ICO with PNG-compressed entries (supported since Windows Vista)."""
    datas = [(s, p.read_bytes()) for s, p in pngs]
    header = struct.pack("<HHH", 0, 1, len(datas))
    offset = 6 + 16 * len(datas)
    entries, blobs = b"", b""
    for s, data in datas:
        entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), offset + len(blobs))
        blobs += data
    dest.write_bytes(header + entries + blobs)


def main():
    OUT.mkdir(exist_ok=True)
    for theme in ("escuro", "claro"):
        # macOS: the plated icon at every size
        iconset = OUT / f"agens-navegador-{theme}.iconset"
        iconset.mkdir(exist_ok=True)
        for name, size in ICNS.items():
            render(HERE / f"icone-macos-{theme}.svg", size, iconset / f"{name}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / f"agens-navegador-{theme}.icns")], check=True)
        # Windows: the small mark (two cards) up to 32 px, the full mark above
        pngs = []
        for size in ICO_SIZES:
            src = HERE / (f"marca-pequena-{theme}.svg" if size <= 32 else f"icone-windows-{theme}.svg")
            dest = OUT / f"windows-{theme}-{size}.png"
            render(src, size, dest)
            pngs.append((size, dest))
        write_ico(pngs, OUT / f"agens-navegador-{theme}.ico")
        # loose PNGs for the site, docs and stores
        for size in (64, 128, 256, 512, 1024):
            render(HERE / f"icone-macos-{theme}.svg", size, OUT / f"macos-{theme}-{size}.png")
        print("ok", theme)


if __name__ == "__main__":
    main()
