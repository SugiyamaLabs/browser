#!/usr/bin/env python3
"""Real-site ad blocker test: the engine headless (no window, no focus), real network, a fresh profile
per mode, blocker on (level 2, the default) vs off (level 0, seeded in Local State).

Usage:
  tools/bloqueador_real.py [--app PATH] [--modes on,off] [--settle 60] [--skip-tabs] [--json OUT]

Per mode:
  1. YouTube video: ytInitialPlayerResponse has adPlacements/playerAds/adSlots? the <video> plays?
  2. Twitch live channel: does it play, any ad label on the player, requests to ad hosts.
  3. UOL: banner slots (#banner-*), the visible ones, which show an ad and which are empty space;
     iframes from ad hosts.
  4. The 20 URLs of tools/tabs.txt, one after the other in their own tab: time to the load event,
     requests, blocked, ad-host requests that loaded, JavaScript errors; after the last one,
     --settle seconds and the memory of every process (tools/measure.py footprint).
Requests come from Resource Timing of the main document: a blocked request also gets an entry, with
duration 0, so "blocked" is entries that took no time and "ad" counts ad-host requests that loaded.
Prints a summary and errors that show up only with the blocker on (possible breakage).
CDP over --remote-debugging-pipe: no port, no extra library. Headless memory is not the app's
(no window, every tab awake), and the dev build has DCHECKs: compare on vs off only.
"""
import argparse, fcntl, json, os, re, queue, shutil, subprocess, sys, tempfile, threading, time
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from measure import descendants, footprint, tabs, ROOT  # noqa: E402

DEFAULT_APP = Path.home() / "browser-work-4/ungoogled-chromium-macos/build/src/out/Dev/AgensBrowser.app/Contents/MacOS/AgensBrowser"
YOUTUBE = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
TWITCH = "https://www.twitch.tv/gaules"
UOL = "https://www.uol.com.br"
AD_HOSTS = ("doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google", "adnxs.com",
            "amazon-adsystem.com", "criteo", "taboola", "outbrain", "teads", "rubiconproject", "pubmatic",
            "tm.jsuol.com.br", "imasdk.googleapis.com", "ads.twitch.tv", "smartadserver", "scorecardresearch")


def is_ad(url):
    host = urlparse(url).hostname or ""
    return any(h in host or h in url for h in AD_HOSTS)


class Cdp:
    """Chrome DevTools Protocol over the pipe (fd 3 in, fd 4 out of the browser), flat sessions."""

    def __init__(self, app, profile, extra):
        to_browser_r, self.w = os.pipe()
        self.r, from_browser_w = os.pipe()

        def fds():  # via fds >= 10 first: a pipe end may already be 3 or 4
            a, b = fcntl.fcntl(to_browser_r, fcntl.F_DUPFD, 10), fcntl.fcntl(from_browser_w, fcntl.F_DUPFD, 10)
            os.dup2(a, 3)
            os.dup2(b, 4)
        self.proc = subprocess.Popen(
            [app, "--headless=new", f"--user-data-dir={profile}", "--remote-debugging-pipe", "--use-mock-keychain",
             "--no-first-run", "--mute-audio", "--autoplay-policy=no-user-gesture-required", "--window-size=1280,800",
             *extra], stdout=subprocess.DEVNULL, stderr=open(profile + ".log", "w"), preexec_fn=fds, close_fds=False)
        os.close(to_browser_r)
        os.close(from_browser_w)
        self.n, self.replies, self.events, self.lock = 0, {}, queue.Queue(), threading.Lock()
        self.cond = threading.Condition(self.lock)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        buf = b""
        while True:
            data = os.read(self.r, 1 << 20)
            if not data:
                return
            buf += data
            while b"\0" in buf:
                raw, buf = buf.split(b"\0", 1)
                msg = json.loads(raw)
                if "id" in msg:
                    with self.cond:
                        self.replies[msg["id"]] = msg
                        self.cond.notify_all()
                else:
                    self.events.put(msg)

    def call(self, method, session=None, timeout=60, **params):
        with self.lock:
            self.n += 1
            n = self.n
        msg = {"id": n, "method": method, "params": params}
        if session:
            msg["sessionId"] = session
        os.write(self.w, json.dumps(msg).encode() + b"\0")
        end = time.time() + timeout
        with self.cond:
            while n not in self.replies:
                if not self.cond.wait(max(0, end - time.time())):
                    return {"error": "timeout"}
            return self.replies.pop(n)

    def close(self):
        try:
            self.call("Browser.close", timeout=5)
            self.proc.wait(20)
        except Exception:
            self.proc.kill()


class Tab:
    """One target with its events: requests, blocked ones, JS errors, load time."""

    def __init__(self, cdp, by_session):
        self.cdp = cdp
        target = cdp.call("Target.createTarget", url="about:blank")["result"]["targetId"]
        self.target = target
        self.session = cdp.call("Target.attachToTarget", targetId=target, flatten=True)["result"]["sessionId"]
        self.requests, self.blocked, self.ad_requests, self.ad_hosts, self.errors = 0, 0, 0, [], []
        self.loaded, self.crashed = None, False
        by_session[self.session] = self
        self.by_session = by_session
        # No Network domain: in the dev build (DCHECKs on) its cookie reporting hits a DCHECK on some
        # ad cookies (network_handler.cc BuildCookie) and the browser quits.
        for domain in ("Page", "Runtime", "Log", "Inspector"):
            cdp.call(f"{domain}.enable", self.session)

    def on(self, msg):
        m, p = msg["method"], msg.get("params", {})
        if m == "Inspector.targetCrashed":  # the dev build has DCHECKs: one in Blink kills the renderer
            self.crashed = True
        elif m == "Runtime.exceptionThrown":
            d = p["exceptionDetails"]
            self.errors.append(((d.get("exception") or {}).get("description") or d.get("text", "")).split("\n")[0][:160])
        elif m == "Runtime.consoleAPICalled" and p.get("type") == "error":
            self.errors.append(" ".join(str(a.get("value", a.get("description", ""))) for a in p.get("args", []))[:160])
        elif m == "Page.loadEventFired" and self.loaded is None:
            self.loaded = time.time()

    def eval(self, js, timeout=30):
        pump(self.cdp, self.by_session, time.time() + 0.1)
        if self.crashed:
            return None
        r = self.cdp.call("Runtime.evaluate", self.session, timeout, expression=js, returnByValue=True, awaitPromise=True)
        if "exceptionDetails" in (r.get("result") or {}) or "error" in r:
            print(f"  eval failed: {json.dumps(r)[:300]}", file=sys.stderr)
        return ((r.get("result") or {}).get("result") or {}).get("value")

    def close(self):
        self.cdp.call("Target.closeTarget", targetId=self.target)


def pump(cdp, by_session, until):
    while time.time() < until:
        try:
            msg = cdp.events.get(timeout=max(0.05, min(0.5, until - time.time())))
        except queue.Empty:
            continue
        tab = by_session.get(msg.get("sessionId"))
        if tab:
            tab.on(msg)


def open_and_wait(cdp, by_session, url, cap=30):
    tab = Tab(cdp, by_session)
    t0 = time.time()
    cdp.call("Page.navigate", tab.session, url=url)
    end = t0 + cap
    while tab.loaded is None and time.time() < end:
        pump(cdp, by_session, min(end, time.time() + 0.5))
    tab.load_s = round(tab.loaded - t0, 2) if tab.loaded else None
    return tab


def count_requests(tab):
    """Requests the document made (Resource Timing) and the ones to ad hosts that loaded. A blocked
    request also gets an entry, with duration 0 (the profile is fresh, so nothing comes from cache)."""
    entries = tab.eval("performance.getEntriesByType('resource').map(e => [e.name, e.duration])") or []
    loaded = [u for u, d in entries if d > 0]
    tab.requests, tab.blocked = len(entries), len(entries) - len(loaded)
    tab.ad_requests = sum(map(is_ad, loaded))
    tab.ad_hosts = sorted({urlparse(u).hostname for u in loaded if is_ad(u)})


def normalize(error):
    """An error without the ids and numbers that change from load to load."""
    return re.sub(r"\b[0-9A-Z]{20,}\b|\d+", "#", error)


YT_JS = r"""(async () => {
  const r = window.ytInitialPlayerResponse || {};
  const v = document.querySelector('video');
  const t0 = v ? v.currentTime : null;
  await new Promise(f => setTimeout(f, 5000));
  const p = document.querySelector('#movie_player');
  return {has_player_response: !!window.ytInitialPlayerResponse,
          adPlacements: Array.isArray(r.adPlacements) ? r.adPlacements.length : 0,
          playerAds: Array.isArray(r.playerAds) ? r.playerAds.length : 0,
          adSlots: Array.isArray(r.adSlots) ? r.adSlots.length : 0,
          video: !!v, ready_state: v ? v.readyState : null, paused: v ? v.paused : null,
          advanced_s: v ? +(v.currentTime - t0).toFixed(1) : null,
          ad_showing: !!(p && p.classList.contains('ad-showing')),
          player_initialised: !!(p && p.getPlayerState)};
})()"""

TWITCH_JS = r"""(async () => {
  const v = document.querySelector('video');
  const t0 = v ? v.currentTime : null;
  await new Promise(f => setTimeout(f, 5000));
  const q = s => !!document.querySelector(s);
  return {video: !!v, ready_state: v ? v.readyState : null, paused: v ? v.paused : null,
          advanced_s: v ? +(v.currentTime - t0).toFixed(1) : null,
          offline: q('[data-a-target="player-overlay-content-gate"], .channel-status-info--offline, [data-a-target="player-state-offline"]'),
          ad_label: q('[data-a-target="video-ad-label"], [data-a-target="video-ad-countdown"], [data-test-selector="ad-banner-default-text"]')};
})()"""

UOL_JS = r"""(() => {
  const hosts = %s;
  const vis = e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
    return r.width > 1 && r.height > 1 && s.display !== 'none' && s.visibility !== 'hidden'; };
  const slots = [...document.querySelectorAll('[id^="banner-"]')];
  const visible = slots.filter(vis);
  const filled = visible.filter(s => [...s.querySelectorAll('iframe, img, video')].some(vis));
  const ad_iframes = [...document.querySelectorAll('iframe')].filter(f =>
    hosts.some(h => (f.src || '').includes(h)) || (f.id || '').startsWith('google_ads_iframe'));
  return {slots: slots.length, slots_visible: visible.length, slots_with_ad: filled.length,
          slots_empty_space: visible.filter(s => !filled.includes(s) && s.getBoundingClientRect().height >= 40).length,
          ad_iframes: ad_iframes.length, ad_iframes_visible: ad_iframes.filter(vis).length,
          links: document.links.length};
})()""" % json.dumps(list(AD_HOSTS))


def run_mode(app, mode, settle, skip_tabs, tab_file):
    profile = tempfile.mkdtemp(prefix=f"agens-ad-{mode}.", dir="/tmp")
    if mode == "off":
        json.dump({"agens": {"adblock": {"level": 0}}}, open(f"{profile}/Local State", "w"))
    cdp = Cdp(app, profile, [])
    by_session = {}
    out = {"mode": mode}
    try:
        time.sleep(6)  # the lists are indexed in the first ~2 s of a fresh profile
        for name, url, js, wait in (("youtube", YOUTUBE, YT_JS, 8), ("twitch", TWITCH, TWITCH_JS, 12), ("uol", UOL, UOL_JS, 8)):
            tab = open_and_wait(cdp, by_session, url)
            pump(cdp, by_session, time.time() + wait)
            res = tab.eval(js) or tab.eval(js) or {}  # once more: the first page after start sometimes answers nothing
            pump(cdp, by_session, time.time() + 0.5)
            count_requests(tab)
            res.update(renderer_crashed=tab.crashed, load_s=tab.load_s, requests=tab.requests, blocked=tab.blocked, ad_requests=tab.ad_requests, ad_hosts=tab.ad_hosts,
                       js_errors=len(tab.errors))
            out[name] = res
            print(f"[{mode}] {name}: {json.dumps(res)}", flush=True)
            tab.close()
        if not skip_tabs:
            rows = []
            for url in tabs(tab_file):
                tab = open_and_wait(cdp, by_session, url)
                pump(cdp, by_session, time.time() + 2)
                count_requests(tab)
                rows.append({"url": url, "load_s": tab.load_s, "requests": tab.requests, "blocked": tab.blocked, "ad_requests": tab.ad_requests, "crashed": tab.crashed,
                             "errors": sorted({normalize(e) for e in tab.errors})})
                print(f"[{mode}] {tab.load_s}s requests={tab.requests:3d} blocked={tab.blocked:3d} ad={tab.ad_requests:2d}{' CRASHED' if tab.crashed else ''} errors={len(set(tab.errors)):2d} {url}", flush=True)
            pump(cdp, by_session, time.time() + settle)
            total, nproc, by_kind = footprint(descendants(cdp.proc.pid))
            out["tabs"] = rows
            out["memory"] = {"total_mb": round(total / 2**20), "processes": nproc,
                             "by_kind_mb": {k: round(v) for k, v in by_kind.items()}}
            print(f"[{mode}] memory after {settle}s: {json.dumps(out['memory'])}", flush=True)
    finally:
        cdp.close()
        shutil.rmtree(profile, ignore_errors=True)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", default=str(DEFAULT_APP))
    ap.add_argument("--modes", default="on,off")
    ap.add_argument("--settle", type=int, default=60)
    ap.add_argument("--skip-tabs", action="store_true")
    ap.add_argument("--tabs", default=ROOT / "tabs.txt")
    ap.add_argument("--json")
    a = ap.parse_args()
    assert is_ad("https://googleads.g.doubleclick.net/x") and not is_ad("https://www.youtube.com/watch")
    assert normalize("request 01M7JYA3KDNHBXMTEW020W6122. x 12") == normalize("request 01M7JYA9VHKKQJFX5CCJEXQEPH. x 3")
    results = {m: run_mode(a.app, m, a.settle, a.skip_tabs, a.tabs) for m in a.modes.split(",")}
    if a.json:
        json.dump(results, open(a.json, "w"), indent=1)
    if "on" in results and "off" in results and "tabs" in results["on"]:
        print("\nload time (s), on / off, and errors only with the blocker on:")
        for on, off in zip(results["on"]["tabs"], results["off"]["tabs"]):
            only_on = sorted(set(on["errors"]) - set(off["errors"]))
            print(f"  {on['load_s']} / {off['load_s']}  {on['url']}" + (f"\n    only on: {only_on}" if only_on else ""))


if __name__ == "__main__":
    main()
