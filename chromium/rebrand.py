#!/usr/bin/env python3
"""Puts the Agens brand on a patched Chromium tree: user-visible strings and the macOS app icon.

Usage: rebrand.py <chromium-src>   (fetch.sh runs it after our patches; safe to run twice)

Strings: replaces "Chromium" in the message text of the .grd/.grdp files below and in their
translations (.xtb). Translations are keyed by a hash of the English text, so changing the text
changes the id: we compute old and new ids with grit itself and rename them in every .xtb, or every
non-English locale would fall back to English.
Icon: copies design/logo/exportados/agens-navegador-escuro.{icns,car} over the Chromium ones
(binary files can't go in a .patch).
"""
import re, shutil, sys
from pathlib import Path

SRC = Path(sys.argv[1]).resolve()
REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SRC / "tools/grit"))
from grit import grd_reader  # noqa: E402
from grit.node import message  # noqa: E402

# Top-level .grd files whose messages (or parts) say "Chromium".
GRDS = ["chrome/app/chromium_strings.grd", "chrome/app/generated_resources.grd",
        "components/components_chromium_strings.grd", "components/components_strings.grd",
        "components/privacy_sandbox_strings.grd", "extensions/strings/extensions_strings.grd"]
# English first; the copyright holder is the company, not "The Agens Authors".
# ", ungoogled-chromium" comes from an ungoogled patch to chrome://version; dropping it restores the upstream
# text, whose translations are still in the .xtb.
GRD_SUBS = [(", ungoogled-chromium", ""), ("The Chromium Authors", "SugiyamaLabs"), ("Chromium", "Agens")]
XTB_SUBS = [(re.compile(r"Autores do Chromium"), "SugiyamaLabs"), (re.compile(r"Chromium"), "Agens")]


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
            text = text.replace(old, new)
        write_if_changed(f, text)
    after = message_ids(grd)
    assert len(before) == len(after), grd  # same messages, same order: only the text changed
    renamed = {o: n for o, n in zip(before, after) if o != n}
    for rel in re.findall(r'<file path="([^"]+\.xtb)"', grd.read_text()):
        xtb = grd.parent / rel
        text = re.sub(r'(<translation id=")(\d+)(")', lambda m: m[1] + renamed.get(m[2], m[2]) + m[3], xtb.read_text())
        for old, new in XTB_SUBS:
            text = old.sub(new, text)
        write_if_changed(xtb, text)
    print(f"ok: {grd.relative_to(SRC)} ({len(renamed)} messages renamed)")


def main():
    for rel in GRDS:
        rebrand_grd(SRC / rel)
    icons = REPO / "design/logo/exportados"
    mac = SRC / "chrome/app/theme/chromium/mac"
    shutil.copyfile(icons / "agens-navegador-escuro.icns", mac / "app.icns")
    shutil.copyfile(icons / "agens-navegador-escuro.car", mac / "Assets.car")
    print("ok: app icon")


if __name__ == "__main__":
    main()
