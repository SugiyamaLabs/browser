// The badge every tab shows, set once the extension is in (and again when the worker starts).
function badge() {
  chrome.action.setBadgeText({text: "7"});
  chrome.action.setBadgeBackgroundColor({color: "#D93025"});
}
chrome.runtime.onInstalled.addListener(badge);
chrome.runtime.onStartup.addListener(badge);
