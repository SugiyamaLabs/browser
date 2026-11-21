// On /janela: asks the background to create the windows (on /janela?nativo, to try the native
// messaging test hosts), then shows its answer in the title.
const nativo = location.search.includes("nativo");
chrome.runtime.sendMessage(nativo ? {nativo: true} : location.origin)
  .then(r => { document.title = (nativo ? "nativo " : "janela ") + r; });
