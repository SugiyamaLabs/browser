#!/usr/bin/env python3
"""Generates the browser logo SVGs from one geometry (the r3-01 "cunha" concept, vectorized by hand).

Usage: python3 design/logo/gerar.py      (writes the SVGs next to this file)

Three slanted cards (the atos), raked like a car down a straight: the front one lit, the two behind it
shorter and set back. The gaps between cards are real cut-outs (masks), so the mark works on any background.
"""
from pathlib import Path

OUT = Path(__file__).resolve().parent

# Geometry in the 1024 space of the source PNG. One card; the ones behind are the same card moved up-left
# with the wedge tip pulled in.
def card(dx=0, dy=0, tip=0):
    x = lambda v: v + dx
    y = lambda v: v + dy
    return (f"M{x(520)} {y(400)} L{x(905 - tip)} {y(390)} L{x(618 - tip * .35)} {y(722)} "
            f"Q{x(600 - tip * .35)} {y(742)} {x(570 - tip * .35)} {y(742)} L{x(258)} {y(742)} "
            f"Q{x(222)} {y(742)} {x(236)} {y(708)} L{x(440)} {y(445)} Q{x(470)} {y(402)} {x(520)} {y(400)} Z")

CARDS = [card(-150, -120, 200), card(-75, -60, 100), card()]  # back, middle, front
GAP = 16  # the dark gap that separates a card from the one behind it

PALETTES = {
    # dark: the warm light of the brand on graphite
    "dark": {"plate": ("#1E1E23", "#0E0E11"), "edge": "rgba(255,255,255,.07)",
             "cards": [("#FFC98A", "#F7A95C"), ("#FFF1DC", "#FFC98A"), ("#FFFDF7", "#F7A95C")]},
    # light: off-white plate, warmer and deeper oranges so the cards keep contrast
    "light": {"plate": ("#FFFFFF", "#ECE9E3"), "edge": "rgba(0,0,0,.08)",
              "cards": [("#F2A75E", "#E07F2E"), ("#FFD9A8", "#F2A75E"), ("#FFE9C7", "#E8893A")]},
}

def mark(theme, uid, mono=None):
    """The three cards as an SVG fragment in the 1024 space. mono: one solid color (or currentColor)."""
    pal = PALETTES[theme]
    defs, body = [], []
    for i, path in enumerate(CARDS):
        if not mono:
            a, b = pal["cards"][i]
            defs.append(f'<linearGradient id="{uid}g{i}" x1="0.75" y1="0" x2="0.25" y2="1"><stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>')
        # each card is cut by every card in front of it, grown by GAP, so the gap is transparent
        cutters = "".join(f'<path d="{p}" fill="#000" stroke="#000" stroke-width="{GAP * 2}" stroke-linejoin="round"/>' for p in CARDS[i + 1:])
        if cutters:
            defs.append(f'<mask id="{uid}m{i}" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><rect width="1024" height="1024" fill="#fff"/>{cutters}</mask>')
        fill = mono or f"url(#{uid}g{i})"
        body.append(f'<path d="{path}" fill="{fill}"' + (f' mask="url(#{uid}m{i})"' if cutters else "") + "/>")
    return "".join(defs), "".join(body)

def mark_small(theme, uid, mono=None):
    """16-32 px: drop the back card, widen the gap, so it stays readable."""
    global CARDS, GAP
    keep = CARDS, GAP
    CARDS, GAP = [card(-95, -78, 120), card()], 28
    try:
        return mark(theme, uid, mono)
    finally:
        CARDS, GAP = keep

def svg(view, inner, size=1024):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}" width="{size}" height="{size}">{inner}</svg>\n'

# The mark alone sits in a square around the cards (x 121..905, y 290..742).
MARK_VIEW = "70 86 840 840"

def macos_icon(theme):
    """macOS app icon on Apple's 1024 grid: an 824 body at 100, ~185 corner radius; mark scaled into it."""
    pal = PALETTES[theme]
    d, b = mark(theme, f"mac{theme}")
    top, bottom = pal["plate"]
    s = 0.84  # mark size inside the body
    cx, cy = 495, 506  # center of the cards bbox (x 86..905, y 270..742)
    tf = f"translate({512 - cx * s} {512 - cy * s}) scale({s})"
    inner = (f'<defs><linearGradient id="p{theme}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>{d}</defs>'
             f'<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#p{theme})"/>'
             f'<rect x="100.5" y="100.5" width="823" height="823" rx="184.5" fill="none" stroke="{pal["edge"]}"/>'
             f'<g transform="{tf}">{b}</g>')
    return svg("0 0 1024 1024", inner)

def windows_icon(theme):
    """Windows 11 style: the mark itself, no plate, with a little room around it (Fluent app icons are free-form)."""
    d, b = mark(theme, f"win{theme}")
    return svg(MARK_VIEW, f"<defs>{d}</defs>{b}", 256)

FILES = {
    "icone-macos-escuro.svg": lambda: macos_icon("dark"),
    "icone-macos-claro.svg": lambda: macos_icon("light"),
    "icone-windows-escuro.svg": lambda: windows_icon("dark"),
    "icone-windows-claro.svg": lambda: windows_icon("light"),
    "marca-escuro.svg": lambda: svg(MARK_VIEW, "<defs>{}</defs>{}".format(*mark("dark", "md")), 512),
    "marca-claro.svg": lambda: svg(MARK_VIEW, "<defs>{}</defs>{}".format(*mark("light", "ml")), 512),
    "marca-pequena-escuro.svg": lambda: svg(MARK_VIEW, "<defs>{}</defs>{}".format(*mark_small("dark", "sd")), 32),
    "marca-pequena-claro.svg": lambda: svg(MARK_VIEW, "<defs>{}</defs>{}".format(*mark_small("light", "sl")), 32),
    "marca-uma-cor.svg": lambda: svg(MARK_VIEW, "<defs>{}</defs>{}".format(*mark("dark", "mo", mono="currentColor")), 512),
    # para quem não herda currentColor (img, Finder, documentos)
    "marca-uma-cor-branca.svg": lambda: svg(MARK_VIEW, "<defs>{}</defs>{}".format(*mark("dark", "mw", mono="#F2F2F4")), 512),
    "marca-uma-cor-preta.svg": lambda: svg(MARK_VIEW, "<defs>{}</defs>{}".format(*mark("dark", "mb", mono="#16161A")), 512),
}

if __name__ == "__main__":
    for name, make in FILES.items():
        (OUT / name).write_text(make())
        print("ok", name)
