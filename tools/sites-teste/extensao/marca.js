// Injected at document_start; once the page has set its own title, adds " +ext" to it.
document.addEventListener("DOMContentLoaded", () => { document.title += " +ext"; });
