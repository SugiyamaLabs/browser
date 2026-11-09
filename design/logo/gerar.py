#!/usr/bin/env python3
"""Generates the browser logo SVGs from one geometry (the r3-01 "cunha" concept, vectorized by hand).

Usage: python3 design/logo/gerar.py      (needs shapely: pip install shapely; writes the SVGs next to this file)

Three slanted cards (the atos), raked like a car down a straight: the front one lit, the two behind it
shorter and set back. The gaps are computed as real geometry (each card minus the cards in front of it,
grown by GAP), so every file is plain filled shapes: no masks, no strokes, same look on any background,
and clean anti-aliasing at every size.
"""
from pathlib import Path

from shapely.geometry import MultiPolygon, Polygon
from shapely.ops import unary_union

OUT = Path(__file__).resolve().parent
TIP_ROUND = 9  # rounds the wedge tips a little so they don't render as a 1 px jagged spike


def sample(path_cmds, steps=24):
    """Points along a path made of ("M"|"L", x, y) and ("Q", cx, cy, x, y)."""
    pts, cur = [], None
    for c in path_cmds:
        if c[0] in "ML":
            cur = (c[1], c[2]); pts.append(cur)
        else:  # quadratic Bézier
            _, cx, cy, x, y = c
            for i in range(1, steps + 1):
                t = i / steps
                pts.append(((1 - t) ** 2 * cur[0] + 2 * (1 - t) * t * cx + t * t * x,
                            (1 - t) ** 2 * cur[1] + 2 * (1 - t) * t * cy + t * t * y))
            cur = (x, y)
    return pts


def card(dx=0, dy=0, tip=0):
    """One card in the 1024 space of the source PNG. Cards behind are moved up-left with the wedge tip pulled in."""
    x = lambda v: v + dx
    y = lambda v: v + dy
    k = tip * .35
    cmds = [("M", x(520), y(400)), ("L", x(905 - tip), y(390)), ("L", x(618 - k), y(722)),
            ("Q", x(600 - k), y(742), x(570 - k), y(742)), ("L", x(258), y(742)),
            ("Q", x(222), y(742), x(236), y(708)), ("L", x(440), y(445)),
            ("Q", x(470), y(402), x(520), y(400))]
    poly = Polygon(sample(cmds))
    return poly.buffer(-TIP_ROUND, join_style="round").buffer(TIP_ROUND, join_style="round")


def visible(cards, gap):
    """Each card minus everything in front of it grown by gap. Returns [(shape, full_card), …] back to front."""
    out = []
    for i, c in enumerate(cards):
        front = unary_union(cards[i + 1:]) if i + 1 < len(cards) else None
        shape = c.difference(front.buffer(gap, join_style="round")) if front is not None else c
        out.append((shape, c))
    return out


def d_attr(geom):
    polys = geom.geoms if isinstance(geom, MultiPolygon) else [geom]
    parts = []
    for p in polys:
        for ring in [p.exterior, *p.interiors]:
            coords = list(ring.coords)[:-1]
            parts.append("M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in coords) + " Z")
    return " ".join(parts)


FULL = [card(-150, -120, 200), card(-75, -60, 100), card()]  # back, middle, front
SMALL = [card(-95, -78, 120), card()]                          # 16–32 px: two cards
GAP, GAP_SMALL = 22, 32

PALETTES = {
    # dark: the warm light of the brand on graphite
    "dark": {"plate": ("#1E1E23", "#0E0E11"), "edge": "rgba(255,255,255,.07)",
             "cards": [("#FFC98A", "#F7A95C"), ("#FFF1DC", "#FFC98A"), ("#FFFDF7", "#F7A95C")]},
    # light: off-white plate, warmer and deeper oranges so the cards keep contrast
    "light": {"plate": ("#FFFFFF", "#ECE9E3"), "edge": "rgba(0,0,0,.08)",
              "cards": [("#F2A75E", "#E07F2E"), ("#FFD9A8", "#F2A75E"), ("#FFE9C7", "#E8893A")]},
}


def mark(theme, uid, mono=None, small=False):
    """The cards as an SVG fragment in the 1024 space. mono: one solid color (or currentColor)."""
    pal = PALETTES[theme]
    cards = SMALL if small else FULL
    colors = pal["cards"][-len(cards):]
    defs, body = [], []
    for i, (shape, full) in enumerate(visible(cards, GAP_SMALL if small else GAP)):
        if mono:
            fill = mono
        else:
            # gradient across the whole card, so a cut card keeps the same light as if it were whole
            x0, y0, x1, y1 = full.bounds
            a, b = colors[i]
            defs.append(f'<linearGradient id="{uid}g{i}" gradientUnits="userSpaceOnUse" x1="{x0 + .75 * (x1 - x0):.1f}" y1="{y0:.1f}" '
                        f'x2="{x0 + .25 * (x1 - x0):.1f}" y2="{y1:.1f}"><stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>')
            fill = f"url(#{uid}g{i})"
        body.append(f'<path d="{d_attr(shape)}" fill="{fill}"/>')
    return "".join(defs), "".join(body)


def svg(view, inner, size=1024):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}" width="{size}" height="{size}">{inner}</svg>\n'


# The mark alone sits in a square around the cards (x ~86..905, y ~270..742).
MARK_VIEW = "70 86 840 840"


def macos_icon(theme):
    """macOS app icon on Apple's 1024 grid: an 824 body at 100, ~185 corner radius; mark scaled into it."""
    pal = PALETTES[theme]
    top, bottom = pal["plate"]
    d, b = mark(theme, f"mac{theme}")
    s = 0.84               # mark size inside the body
    cx, cy = 495, 506      # center of the cards bbox
    tf = f"translate({512 - cx * s:.1f} {512 - cy * s:.1f}) scale({s})"
    inner = (f'<defs><linearGradient id="p{theme}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>{d}</defs>'
             f'<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#p{theme})"/>'
             f'<rect x="100.5" y="100.5" width="823" height="823" rx="184.5" fill="none" stroke="{pal["edge"]}"/>'
             f'<g transform="{tf}">{b}</g>')
    return svg("0 0 1024 1024", inner)


def plain(theme, uid, size, **kw):
    return svg(MARK_VIEW, "<defs>{}</defs>{}".format(*mark(theme, uid, **kw)), size)


FILES = {
    "icone-macos-escuro.svg": lambda: macos_icon("dark"),
    "icone-macos-claro.svg": lambda: macos_icon("light"),
    # Windows 11: the mark itself, no plate (Fluent app icons are free-form)
    "icone-windows-escuro.svg": lambda: plain("dark", "wd", 256),
    "icone-windows-claro.svg": lambda: plain("light", "wl", 256),
    "marca-escuro.svg": lambda: plain("dark", "md", 512),
    "marca-claro.svg": lambda: plain("light", "ml", 512),
    "marca-pequena-escuro.svg": lambda: plain("dark", "sd", 32, small=True),
    "marca-pequena-claro.svg": lambda: plain("light", "sl", 32, small=True),
    "marca-uma-cor.svg": lambda: plain("dark", "mo", 512, mono="currentColor"),
    # for places that don't inherit the text color (img, Finder, documents)
    "marca-uma-cor-branca.svg": lambda: plain("dark", "mw", 512, mono="#F2F2F4"),
    "marca-uma-cor-preta.svg": lambda: plain("dark", "mb", 512, mono="#16161A"),
}

if __name__ == "__main__":
    for name, make in FILES.items():
        (OUT / name).write_text(make())
        print("ok", name)
