// Test only: chrome.windows.create when /janela asks (a popup, then a normal window, each on /other).
// Answers "popup:<type>:<tabs> normal:<type>:<tabs>" with what each call resolved to.
chrome.runtime.onMessage.addListener((origin, sender, reply) => {
  (async () => {
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
