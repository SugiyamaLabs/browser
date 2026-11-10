#!/usr/bin/env bash
# Downloads the ad blocker filter lists into lists/. Run by hand (or from CI) to refresh the lists on main; the browser downloads them from there once a day.
# Then commit the lists, run fetch.sh (or copy lists/ into third_party/sugiyamalabs_adblock/lists) and build.
set -euo pipefail
cd "$(dirname "$0")/lists"
get() { curl -sSfL --retry 3 -o "$1.tmp" "$2" && mv "$1.tmp" "$1"; }
get easylist.txt        https://easylist.to/easylist/easylist.txt
get easyprivacy.txt     https://easylist.to/easylist/easyprivacy.txt
get ublock-filters.txt  https://ublockorigin.github.io/uAssets/filters/filters.txt
get ublock-privacy.txt  https://ublockorigin.github.io/uAssets/filters/privacy.txt
get easylist-cookie.txt https://ublockorigin.github.io/uAssets/thirdparties/easylist-cookies.txt
grep -m1 -H -i "^! \(Version\|Last modified\)" *.txt
