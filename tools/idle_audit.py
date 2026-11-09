#!/usr/bin/env python3
"""Opens a browser with no tabs in a fresh profile, leaves it idle, and reports every network connection.

Usage: tools/idle_audit.py [BROWSER] [--minutes 10]     (BROWSER as in tools/measure.py; default: ungoogled)

Two sources, so nothing slips through:
- Chromium's own NetLog (every URL request, DNS lookup and socket the network service opens);
- lsof every 2 s over all browser processes (anything that opens a socket outside the network service).
Also reports CPU seconds used while idle. Pass criteria (#7): no connection at all, CPU near zero.
"""
import argparse, collections, json, subprocess, sys, tempfile, time
from pathlib import Path
from measure import BROWSERS, descendants, kind, quit_browser


def cpu_seconds(pids):
    out = subprocess.run(["ps", "-o", "time=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    total = 0.0
    for t in out.split():
        parts = t.replace("-", ":").split(":")  # [[dd-]hh:]mm:ss.ss
        sec = 0.0
        for p in parts:
            sec = sec * 60 + float(p)
        total += sec
    return total


def sockets(pids):
    out = subprocess.run(["lsof", "-nP", "-a", "-i", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    return {l for l in out.splitlines()[1:] if "->" in l or "UDP" in l}


def netlog_hosts(path):
    text = Path(path).read_text()
    if not text.rstrip().endswith("}"):  # NetLog is left unterminated if the browser is killed
        text = text.rstrip().rstrip(",") + "]}"
    log = json.loads(text)
    names = {v: k for k, v in log["constants"]["logEventTypes"].items()}
    hits = collections.Counter()
    for e in log.get("events", []):
        p = e.get("params", {})
        url = p.get("url") or p.get("host")
        if url and names.get(e["type"]) in ("URL_REQUEST_START_JOB", "HOST_RESOLVER_MANAGER_REQUEST", "HOST_RESOLVER_DNS_TASK", "SOCKET_POOL_CONNECT_JOB"):
            hits[url] += 1
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("browser", nargs="?", default="ungoogled")
    ap.add_argument("--minutes", type=float, default=10)
    a = ap.parse_args()
    exe = BROWSERS.get(a.browser, a.browser)
    work = Path(tempfile.mkdtemp(prefix="idle-audit-"))
    netlog = work / "netlog.json"
    proc = subprocess.Popen([exe, f"--user-data-dir={work / 'profile'}", "--no-first-run", "--no-default-browser-check",
                             "--use-mock-keychain", f"--log-net-log={netlog}", "--net-log-capture-mode=Default"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    seen, end = set(), time.monotonic() + a.minutes * 60
    time.sleep(10)  # let startup finish before the idle window
    cpu0 = cpu_seconds(descendants(proc.pid))
    while time.monotonic() < end:
        pids = descendants(proc.pid)
        seen |= sockets(pids)
        time.sleep(2)
    pids = descendants(proc.pid)
    cpu = cpu_seconds(pids) - cpu0
    kinds = collections.Counter(kind(p) for p in pids)
    quit_browser(proc)

    hosts = netlog_hosts(netlog)
    print(f"browser: {a.browser}  idle window: {a.minutes:g} min  processes at the end: {dict(kinds)}")
    print(f"CPU used while idle: {cpu:.1f} s ({100 * cpu / (a.minutes * 60):.2f}% of one core)")
    print(f"NetLog: {len(hosts)} hosts/URLs" + "".join(f"\n  {n:4d}  {h}" for h, n in hosts.most_common()))
    print(f"lsof: {len(seen)} sockets" + "".join(f"\n  {l}" for l in sorted(seen)))
    print(f"NetLog file: {netlog}")


if __name__ == "__main__":
    main()
