#!/usr/bin/env python3
"""Puts the AgensBrowser brand on a patched Chromium tree: user-visible strings and the macOS app icon.

Usage: rebrand.py <chromium-src>   (fetch.sh runs it after our patches; safe to run twice)

Strings: replaces "Chromium" in the message text of the .grd/.grdp files below and in their
translations (.xtb). Translations are keyed by a hash of the English text, so changing the text
changes the id: we compute old and new ids with grit itself and rename them in every .xtb, or every
non-English locale would fall back to English.
Icons: copies design/logo/exportados/agens-navegador-escuro.{icns,car} and the mark PNGs over the Chromium ones
(binary files can't go in a .patch).
"""
import re, shutil, sys
from pathlib import Path

SRC = Path(sys.argv[1]).resolve()
REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SRC / "tools/grit"))
from grit import grd_reader  # noqa: E402
from grit.node import message  # noqa: E402

# The product name everywhere the UI says "Chromium". Not just "Agens": that is the Agens app's
# name, and the two install side by side.
PRODUCT = "AgensBrowser"

# Top-level .grd files whose messages (or parts) say "Chromium".
GRDS = ["chrome/app/chromium_strings.grd", "chrome/app/generated_resources.grd",
        "components/components_chromium_strings.grd", "components/components_strings.grd",
        "components/privacy_sandbox_strings.grd", "extensions/strings/extensions_strings.grd"]
# English first; the copyright holder is the company, not "The Agens Authors".
# ", ungoogled-chromium" comes from an ungoogled patch to chrome://version; dropping it restores the upstream
# text, whose translations are still in the .xtb.
# The About credit line keeps naming the Chromium project (the link to it), as its license asks.
CHROMIUM = re.compile(r'Chromium(?!<ph name="END_LINK_CHROMIUM")')
GRD_SUBS = [(re.compile(", ungoogled-chromium"), ""), (re.compile("The Chromium Authors"), "SugiyamaLabs"), (CHROMIUM, PRODUCT)]
XTB_SUBS = [(re.compile("Autores do Chromium"), "SugiyamaLabs"), (CHROMIUM, PRODUCT)]

# "Chrome" / "Google Chrome" naming this browser. Stays: Google services and programs (Web Store, Enterprise,
# Remote Desktop, Root Store/Program, Sync, Apps, Gemini in/on Chrome) and what isn't a bare word (ChromeOS,
# Chromebook, ChromeVox, Chromecast: no word boundary). Applied only to message text, never to desc/meaning.
CHROME = re.compile(
    r"(?<!Gemini in )(?<!Gemini on )(?<!Gemini no )(?<!Gemini na )(?:Google )?Chrome\b"
    r"(?! ?(?:Web ?[Ss]tore|Enterprise|Remote Desktop|Root|Sync|Apps?\b|Dino|for Testing|Browser Cloud))")
MESSAGE = re.compile(r"(<message\b[^>]*>)(.*?)(</message>)", re.S)

# pt-BR: Chromium says "guia" for a tab, we say "aba". Skipped: "guide" senses, i.e. masculine "guia"
# (o/um/este guia) and "Guia de privacidade/configuração".
GUIA = re.compile(r"(?<!\b[Oo] )(?<!\b[Uu]m )(?<!\b[Ee]ste )(?<!\b[Ee]sse )(?<!\b[Dd]o )(?<!\b[Nn]o )(?<!\b[Aa]o )"
                  r"\b([Gg])uia(s?)\b(?! de (?:privacidade|configura))")
# Other pt-BR xtbs that say "guia" for tabs and whose English has no "Chrome" to rebrand.
PT_ONLY_GRDS = ["ui/strings/ax_strings.grd", "components/omnibox/resources/omnibox_pedal_synonyms.grd"]


def guia_to_aba(text: str) -> str:
    return GUIA.sub(lambda m: ("A" if m[1] == "G" else "a") + "ba" + m[2], text)


def rebrand_chrome(text: str) -> str:
    return CHROME.sub(PRODUCT, text)


def message_ids(grd: Path) -> list[str]:
    root = grd_reader.Parse(str(grd), debug=False, skip_validation_checks=True)
    return [n.GetCliques()[0].GetMessage().GetId() for n in root.Preorder() if isinstance(n, message.MessageNode)]


def parts(path: Path) -> list[Path]:
    found = [path]
    for rel in re.findall(r'<part file="([^"]+)"', path.read_text()):
        found += parts(path.parent / rel)
    return found


def write_if_changed(path: Path, text: str):
    if path.read_text() != text:  # untouched files keep their mtime, so a re-run doesn't rebuild every locale
        path.write_text(text)


def rebrand_grd(grd: Path):
    before = message_ids(grd)
    for f in parts(grd):
        text = f.read_text()
        for old, new in GRD_SUBS:
            text = old.sub(new, text)
        text = MESSAGE.sub(lambda m: m[1] + rebrand_chrome(m[2]) + m[3], text)
        write_if_changed(f, text)
    after = message_ids(grd)
    assert len(before) == len(after), grd  # same messages, same order: only the text changed
    renamed = {o: n for o, n in zip(before, after) if o != n}
    for rel in re.findall(r'<file path="([^"]+\.xtb)"', grd.read_text()):
        xtb = grd.parent / rel
        text = re.sub(r'(<translation id=")(\d+)(")', lambda m: m[1] + renamed.get(m[2], m[2]) + m[3], xtb.read_text())
        for old, new in XTB_SUBS:
            text = old.sub(new, text)
        # only translations of messages whose English changed (their id is in `renamed`) get "Chrome" replaced
        changed = set(renamed.values())
        text = re.sub(r'(<translation id=")(\d+)(".*?>)(.*?)(</translation>)',
                      lambda m: m[1] + m[2] + m[3] + (rebrand_chrome(m[4]) if m[2] in changed else m[4]) + m[5], text, flags=re.S)
        if xtb.name.endswith("_pt-BR.xtb"):
            text = guia_to_aba(text)
        # two messages that differed only by "Chrome"/"Chromium" now share an id: keep one translation (grit asserts on duplicates)
        seen = set()
        def first(m):
            if m[1] in seen:
                return ""
            seen.add(m[1])
            return m[0]
        text = re.sub(r'<translation id="(\d+)"[^>]*?(?:/>|>.*?</translation>)\n?', first, text, flags=re.S)
        write_if_changed(xtb, text)
    print(f"ok: {grd.relative_to(SRC)} ({len(renamed)} messages renamed)")


def rebrand_pt_only(grd: Path):
    for rel in re.findall(r'<file path="([^"]+_pt-BR\.xtb)"', grd.read_text()):
        xtb = grd.parent / rel
        write_if_changed(xtb, guia_to_aba(xtb.read_text()))
    print(f"ok: {grd.relative_to(SRC)} (pt-BR tabs)")


def main():
    for rel in GRDS:
        rebrand_grd(SRC / rel)
    for rel in PT_ONLY_GRDS:
        rebrand_pt_only(SRC / rel)
    icons = REPO / "design/logo/exportados"
    mac = SRC / "chrome/app/theme/chromium/mac"
    shutil.copyfile(icons / "agens-navegador-escuro.icns", mac / "app.icns")
    shutil.copyfile(icons / "agens-navegador-escuro.car", mac / "Assets.car")
    # product logo inside the UI (About, settings, omnibox chip): the bare mark, no plate
    theme = SRC / "chrome/app/theme"
    for size in (16, 24, 48, 64, 128, 256):
        shutil.copyfile(icons / f"windows-escuro-{size}.png", theme / f"chromium/product_logo_{size}.png")
    for scale, mult in (("100", 1), ("200", 2)):
        for size in (16, 32):
            shutil.copyfile(icons / f"windows-escuro-{size * mult}.png", theme / f"default_{scale}_percent/chromium/product_logo_{size}.png")
    print("ok: app icon and product logos")


if __name__ == "__main__":
    main()
