const HOST = "io.rolo.ytpip";

// Settings panel <-> the yt-pip native host (reads/writes ~/.config/yt-pip/config.json).
chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (!msg || msg.type !== "native") return;
  chrome.runtime.sendNativeMessage(HOST, msg.payload, res => {
    reply(chrome.runtime.lastError ? { error: chrome.runtime.lastError.message } : res);
  });
  return true;
});

// Toolbar button (regular Chrome windows): toggle PiP in the clicked tab.
chrome.action.onClicked.addListener(tab => {
  if (!tab.id) return;
  chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: async () => {
      if (document.pictureInPictureElement) return document.exitPictureInPicture();
      const v = [...document.querySelectorAll("video")].find(v => v.readyState > 0);
      if (v) { v.disablePictureInPicture = false; await v.requestPictureInPicture(); }
    },
  }).catch(() => {});
});
