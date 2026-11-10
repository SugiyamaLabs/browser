#!/usr/bin/env python3
"""Lets the browser install and update extensions from the Chrome Web Store, as Brave does.

ungoogled-chromium renames every Google domain in the source (domain_substitution.py), which also
breaks the store: its page can't reach the install API and the update URL goes nowhere. This runs
after that step and puts back only the store's addresses. The logic (update checks, the
"Instalar no AgensBrowser" label, the on/off pref) is in patches/sugiyamalabs/webstore.patch.

Usage: python3 chromium/webstore.py <chromium src dir>
"""
import sys
from pathlib import Path

FIXES = {
    "extensions/common/extension_urls.cc": [
        ("https://chrome.9oo91e.qjz9zk/webstore", "https://chrome.google.com/webstore"),
        ("https://chromewebstore.9oo91e.qjz9zk/", "https://chromewebstore.google.com/"),
        ("https://clients2.9oo91e.qjz9zk/service/update2/crx", "https://clients2.google.com/service/update2/crx"),
        ("https://chromewebstore.9oo91eapis.qjz9zk/", "https://chromewebstore.googleapis.com/"),
    ],
    # The store page may use the install API (webstorePrivate) and the management API.
    "extensions/common/api/_api_features.json": [
        ('"https://chromewebstore.9oo91e.qjz9zk/*"', '"https://chromewebstore.google.com/*"'),
    ],
    # The store's update response is checked against this namespace; without it every install and update fails.
    "extensions/browser/updater/safe_manifest_parser.cc": [
        ("http://www.9oo91e.qjz9zk/update2/response", "http://www.google.com/update2/response"),
    ],
}


def main(src: Path) -> int:
    for rel, pairs in FIXES.items():
        path = src / rel
        text = path.read_text()
        for old, new in pairs:
            if old not in text and new not in text:
                print(f"webstore.py: {rel}: '{old}' not found", file=sys.stderr)
                return 1
            text = text.replace(old, new)
        path.write_text(text)
    print("ok: Chrome Web Store addresses restored")
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1])))
