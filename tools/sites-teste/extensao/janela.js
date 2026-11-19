// Test only: chrome.windows.create when /janela asks (a popup, then a normal window, each on /other).
// Answers "popup:<type>:<tabs> normal:<type>:<tabs>" with what each call resolved to.
// On /janela?nativo: sends "ping" to each test native host (embutido.sh writes their manifests)
// and answers "<host>:<reply or error>" for each.
const NATIVE_HOSTS = ["com.agens.gate_echo", "com.agens.gate_forbidden", "com.agens.gate_missing"];
function askNative(host) {
  return new Promise(resolve => {
    const port = chrome.runtime.connectNative(host);
    port.onMessage.addListener(m => { resolve(`${host}:${m.echo}`); port.disconnect(); });
    port.onDisconnect.addListener(() => resolve(`${host}:${chrome.runtime.lastError?.message || "closed"}`));
    port.postMessage({echo: "pong"});
  });
}
chrome.runtime.onMessage.addListener((origin, sender, reply) => {
  (async () => {
    if (origin && origin.nativo) {
      const out = [];
      for (const host of NATIVE_HOSTS) out.push(await askNative(host));
      reply(out.join(" | "));
      return;
    }
    const out = [];
    for (const type of ["popup", "normal"]) {
      try {
        const w = await chrome.windows.create({url: `${origin}/other?from=${type}`, type, focused: true});
        out.push(`${type}:${w.type}:${(w.tabs || []).length}`);
      } catch (e) {
        out.push(`${type}:error`);
      }
    }
    reply(out.join(" "));
  })();
  return true;
});
