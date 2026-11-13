// On /janela: asks the background to create the windows, then shows its answer in the title.
chrome.runtime.sendMessage(location.origin).then(r => { document.title = "janela " + r; });
