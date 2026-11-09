#!/usr/bin/env python3
"""Measures a Chromium-based browser with the fixed tab set (docs/performance.md).

Usage:
  tools/measure.py BROWSER --login          open the tab set in the bench profile; sign in, then quit the browser
  tools/measure.py BROWSER [--runs 3]       measure; prints a docs/medicoes.md row

BROWSER is brave, chrome, ungoogled, dev, or a path to the browser executable.
Metrics: launch-to-load time of a local page, total memory (footprint "total footprint" over all
browser processes, shared memory counted once), memory per tab, process count. Speedometer 3 and
battery are manual for now (docs/performance.md).
"""
import argparse, http.server, json, os, signal, statistics, subprocess, sys, tempfile, threading, time
import urllib.request
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WORK = Path(os.environ.get("BROWSER_WORK", Path.home() / "browser-work"))
SRC = WORK / "ungoogled-chromium-macos/build/src"
BROWSERS = {
    "brave": "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "chrome": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "ungoogled": str(SRC / "out/Default/Chromium.app/Contents/MacOS/Chromium"),
    "dev": str(SRC / "out/Dev/Chromium.app/Contents/MacOS/Chromium"),
}
PORT = 9333


def tabs(path):
    return [l.split("#")[0].strip() for l in Path(path).read_text().splitlines() if l.split("#")[0].strip()]


def version(exe):
    plist = Path(exe).parents[1] / "Info.plist"
    out = subprocess.run(["defaults", "read", str(plist), "CFBundleShortVersionString"], capture_output=True, text=True)
    return out.stdout.strip() or "?"


class Beacon(http.server.BaseHTTPRequestHandler):
    """Serves a page that pings /loaded on its load event; the ping time is the launch-to-load mark."""
    loaded = None

    def do_GET(self):
        if self.path == "/loaded":
            Beacon.loaded = time.monotonic()
        body = b"<title>ready</title><script>addEventListener('load',()=>fetch('/loaded'))</script>ready"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def descendants(root):
    rows = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout.split("\n")
    kids = {}
    for r in rows:
        if r.strip():
            pid, ppid = map(int, r.split())
            kids.setdefault(ppid, []).append(pid)
    found, todo = [], [root]
    while todo:
        p = todo.pop()
        found.append(p)
        todo += kids.get(p, [])
    return found


def kind(pid):
    """Process kind from its Chromium command line: browser, renderer, gpu-process, utility:<service>..."""
    cmd = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    t = next((a.split("=", 1)[1] for a in cmd.split() if a.startswith("--type=")), "browser")
    sub = next((a.split("=", 1)[1] for a in cmd.split() if a.startswith("--utility-sub-type=")), "")
    return f"{t}:{sub.split('.')[0]}" if sub else t


def footprint(pids):
    kinds = {p: kind(p) for p in pids}
    with tempfile.NamedTemporaryFile(suffix=".json") as f:
        args = ["footprint", "-j", f.name, "--noCategories"]
        for p in pids:
            args += ["-p", str(p)]
        subprocess.run(args, capture_output=True, check=True)
        d = json.load(open(f.name))
    by_kind = {}
    for proc in d["processes"]:  # per-process footprints; shared memory may be counted in more than one
        k = kinds.get(proc["pid"], "?")
        by_kind[k] = by_kind.get(k, 0) + proc["auxiliary"]["phys_footprint"] / 2**20
    return d["total footprint"], len(d["processes"]), by_kind


def cdp(path, method="GET"):
    req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", method=method)
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)


def launch(exe, profile, urls):
    # mock keychain: our unsigned builds would otherwise block on a login keychain prompt; same flag for every browser
    args = [exe, f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check", "--use-mock-keychain",
            f"--remote-debugging-port={PORT}", *urls]
    return subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def quit_browser(proc):
    proc.send_signal(signal.SIGTERM)  # the browser process only; it shuts down its own children
    try:
        proc.wait(30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    time.sleep(3)


def one_run(exe, profile, urls, settle):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Beacon)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    Beacon.loaded = None
    t0 = time.monotonic()
    proc = launch(exe, profile, [f"http://127.0.0.1:{server.server_port}/"])
    try:
        while Beacon.loaded is None:
            if proc.poll() is not None or time.monotonic() - t0 > 60:
                raise RuntimeError("browser exited or did not load the local page in 60 s")
            time.sleep(0.01)
        launch_s = Beacon.loaded - t0
        for _ in range(100):  # DevTools endpoint can lag the first page
            try:
                cdp("/json/version"); break
            except OSError:
                time.sleep(0.1)
        ready = [t["id"] for t in cdp("/json/list") if t["type"] == "page"]
        for u in urls:
            cdp("/json/new?" + u, method="PUT")
        for t in ready:  # keep exactly the tab set
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/close/{t}", timeout=5).read()
        time.sleep(settle)
        pages = sum(1 for t in cdp("/json/list") if t["type"] == "page")
        total, nproc, by_kind = footprint(descendants(proc.pid))
        print("by process kind (MB): " + json.dumps({k: round(v) for k, v in sorted(by_kind.items(), key=lambda x: -x[1])}), file=sys.stderr)
        return {"launch_s": launch_s, "total_mb": total / 2**20, "pages": pages, "processes": nproc}
    finally:
        quit_browser(proc)
        server.shutdown()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("browser")
    ap.add_argument("--tabs", default=ROOT / "tabs.txt")
    ap.add_argument("--profile", help="default: $BROWSER_WORK/bench-profiles/<browser>")
    ap.add_argument("--runs", type=int, default=3)
    # 10 min: tabs sleep after 5 min hidden (#8), so 5 min would catch the transition
    ap.add_argument("--settle", type=int, default=600, help="seconds after opening the tabs (default 600)")
    ap.add_argument("--login", action="store_true")
    a = ap.parse_args()

    exe = BROWSERS.get(a.browser, a.browser)
    if not Path(exe).exists():
        sys.exit(f"browser not found: {exe}")
    name = a.browser if a.browser in BROWSERS else Path(exe).name
    profile = Path(a.profile or WORK / "bench-profiles" / name)
    profile.mkdir(parents=True, exist_ok=True)
    urls = tabs(a.tabs)

    if a.login:
        print(f"Sign in to every tab in {name}, then quit it (Cmd+Q).", file=sys.stderr)
        launch(exe, profile, urls).wait()
        return

    runs = []
    for i in range(a.runs):
        r = one_run(exe, profile, urls, a.settle)
        print(f"run {i + 1}: {json.dumps({k: round(v, 2) for k, v in r.items()})}", file=sys.stderr)
        runs.append(r)
    med = {k: statistics.median(r[k] for r in runs) for k in runs[0]}
    out = WORK / "measurements" / f"{date.today()}-{name}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({"browser": name, "version": version(exe), "tabs": urls, "runs": runs, "median": med}, indent=2))
    machine = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    ram = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) // 2**30
    per_tab = med["total_mb"] / max(med["pages"], 1)
    # columns of docs/medicoes.md; Speedometer, battery and "% of Brave" are filled by hand
    print(f"| {date.today():%d/%m/%Y} | {machine}, {ram} GB | {name} {version(exe)} | {med['total_mb']:,.0f} MB | "
          f"{per_tab:,.0f} MB ({med['pages']:.0f} abas) | {med['processes']:.0f} | — / {med['launch_s']:.2f} s | — | — | — |")
    print(f"saved {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
