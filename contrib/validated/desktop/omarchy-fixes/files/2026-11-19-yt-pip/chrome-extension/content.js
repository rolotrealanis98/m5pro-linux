// yt-pip content script for YouTube (the Omarchy YouTube web app and Chrome tabs).
// - Mini player button in the player's control bar: click = open/close picture-in-picture,
//   right-click = mini player settings (stored by the yt-pip helper via native messaging).
// - Alt+Shift+P toggles PiP (the yt-pip helper sends this key to hidden YouTube windows).
// YouTube enforces Trusted Types, so everything is built with DOM calls, never innerHTML.
(() => {
  if (window.__ytPipLoaded) return;
  window.__ytPipLoaded = true;

  const SVGNS = "http://www.w3.org/2000/svg";
  const PIP_PATH = "M19 11h-8v6h8v-6zm4 8V4.98C23 3.88 22.1 3 21 3H3c-1.1 0-2 .88-2 1.98V19c0 1.1.9 2 2 2h18c1.1 0 2-.9 2-2zm-2 .02H3V4.97h18v14.05z";

  function mainVideo() {
    const vids = [...document.querySelectorAll("video")].filter(v => v.readyState > 0);
    vids.sort((a, b) => (b.paused ? 0 : 1) - (a.paused ? 0 : 1) ||
      b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight);
    return vids[0] || document.querySelector("video.html5-main-video");
  }

  async function togglePip() {
    try {
      if (document.pictureInPictureElement) return await document.exitPictureInPicture();
      const v = mainVideo();
      if (!v) return;
      v.disablePictureInPicture = false;
      await v.requestPictureInPicture();
    } catch (e) {
      console.debug("[yt-pip]", e && e.message);
    }
  }

  window.addEventListener("keydown", e => {
    if (e.code === "KeyP" && e.altKey && e.shiftKey && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      e.stopImmediatePropagation();
      togglePip();
    }
  }, true);

  try {
    navigator.mediaSession.setActionHandler("enterpictureinpicture", () => {
      const v = mainVideo();
      if (v && !v.paused) v.requestPictureInPicture().catch(() => {});
    });
  } catch (e) {}

  // ---------------------------------------------------------------- helpers
  function el(tag, props, children) {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (k === "class") n.className = v;
      else if (k === "text") n.textContent = v;
      else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v);
    }
    for (const c of children || []) if (c) n.append(c);
    return n;
  }

  function native(payload) {
    return new Promise(resolve => {
      try {
        chrome.runtime.sendMessage({ type: "native", payload }, res => resolve(res || { error: "no reply" }));
      } catch (e) {
        resolve({ error: String(e) });
      }
    });
  }

  // ---------------------------------------------------------------- button
  function makeButton() {
    const svg = document.createElementNS(SVGNS, "svg");
    svg.setAttribute("viewBox", "-6 -6 36 36");
    svg.setAttribute("width", "100%");
    svg.setAttribute("height", "100%");
    const p = document.createElementNS(SVGNS, "path");
    p.setAttribute("d", PIP_PATH);
    p.setAttribute("fill", "#fff");
    svg.append(p);
    const b = el("button", {
      class: "ytp-button yt-pip-button",
      title: "Mini player (Alt+Shift+P) · right-click for settings",
      "aria-label": "Mini player",
      onclick: e => { e.stopPropagation(); togglePip(); },
      oncontextmenu: e => { e.preventDefault(); e.stopPropagation(); toggleSettings(); },
    }, [svg]);
    b.style.cssText = "display:inline-flex;align-items:center;justify-content:center;";
    return b;
  }

  function ensureButton() {
    const controls = document.querySelector("#movie_player .ytp-right-controls");
    if (!controls || controls.querySelector(".yt-pip-button")) return;
    const anchor = controls.querySelector(".ytp-settings-button") || controls.firstChild;
    controls.insertBefore(makeButton(), anchor);
  }

  // ---------------------------------------------------------------- settings panel
  const CSS = `
    :host { all: initial; }
    .panel { position: absolute; right: 12px; bottom: 64px; width: 320px; max-height: calc(100% - 90px); overflow-y: auto;
      background: rgba(28,28,28,.94); color: #eee; border-radius: 12px; padding: 14px 16px 12px;
      font: 13px/1.35 "YouTube Sans", Roboto, Arial, sans-serif; box-shadow: 0 8px 32px rgba(0,0,0,.45); z-index: 80;
      text-shadow: none; }
    h2 { margin: 0 0 2px; font-size: 15px; font-weight: 600; color: #fff; }
    .sub { color: #aaa; font-size: 12px; margin-bottom: 10px; }
    .sect { color: #aaa; font-size: 11px; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; margin: 14px 0 6px; }
    .row { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 6px 0; }
    .row .label { display: flex; flex-direction: column; }
    .row .hint { color: #999; font-size: 11.5px; }
    .switch { position: relative; width: 36px; height: 20px; border-radius: 10px; background: #555; cursor: pointer; flex: none;
      border: 0; padding: 0; transition: background .15s; }
    .switch::after { content: ""; position: absolute; top: 2px; left: 2px; width: 16px; height: 16px; border-radius: 50%;
      background: #fff; transition: transform .15s ease-out; }
    .switch.on { background: #f00; }
    .switch.on::after { transform: translateX(16px); }
    .seg { display: flex; flex-wrap: wrap; gap: 6px; }
    .seg button { background: rgba(255,255,255,.1); color: #eee; border: 0; border-radius: 8px; padding: 6px 10px; cursor: pointer;
      font: inherit; }
    .seg button:hover { background: rgba(255,255,255,.18); }
    .seg button.on { background: #fff; color: #111; }
    input[type=range] { width: 100%; accent-color: #f00; }
    .val { color: #aaa; font-size: 12px; }
    .err { color: #ff8a80; font-size: 12px; margin-top: 8px; }
    .foot { color: #888; font-size: 11.5px; margin-top: 12px; }
    .disabled { opacity: .45; pointer-events: none; }
  `;

  let host = null, root = null, state = null, open = false;

  function closeSettings() {
    open = false;
    if (host) host.remove();
    host = null;
  }

  async function toggleSettings() {
    if (open) return closeSettings();
    const player = document.querySelector("#movie_player");
    if (!player) return;
    open = true;
    host = el("div", { class: "yt-pip-settings-host" });
    host.style.cssText = "position:absolute;inset:0;pointer-events:none;z-index:80;";
    root = host.attachShadow({ mode: "open" });
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(CSS);
    root.adoptedStyleSheets = [sheet];
    player.append(host);
    for (const ev of ["click", "mousedown", "mouseup", "dblclick", "keydown", "wheel"])
      host.addEventListener(ev, e => e.stopPropagation());
    render({ loading: true });
    const res = await native({ cmd: "get" });
    if (open) render(res);
  }

  document.addEventListener("mousedown", e => {
    if (open && host && !e.composedPath().includes(host) &&
        !(e.target.closest && e.target.closest(".yt-pip-button"))) closeSettings();
  }, true);
  document.addEventListener("keydown", e => { if (open && e.key === "Escape") closeSettings(); }, true);

  async function set(key, value) {
    if (state && state.config) state.config[key] = value;  // optimistic
    render(state);
    const res = await native({ cmd: "set", key, value });
    if (open) render(res);
  }

  function sw(on, onToggle) {
    return el("button", { class: "switch" + (on ? " on" : ""), role: "switch", "aria-checked": String(!!on), onclick: onToggle });
  }
  function toggleRow(label, hint, on, onToggle, disabled) {
    const r = el("div", { class: "row" + (disabled ? " disabled" : "") }, [
      el("div", { class: "label" }, [el("span", { text: label }), hint ? el("span", { class: "hint", text: hint }) : null]),
      sw(on, onToggle),
    ]);
    return r;
  }
  function seg(options, value, onPick) {
    return el("div", { class: "seg" }, options.map(([v, label, title]) =>
      el("button", { class: String(v) === String(value) ? "on" : "", text: label, title: title || label, onclick: () => onPick(v) })));
  }
  function slider(min, max, step, value, onDone) {
    return el("input", { type: "range", min, max, step, value, onchange: e => onDone(Number(e.target.value)) });
  }

  function render(res) {
    if (!root) return;
    state = res;
    const panel = el("div", { class: "panel" });
    panel.style.pointerEvents = "auto";
    const st = (res && res.state) || {};
    const c = (res && res.config) || {};

    let sub = "Loading…";
    if (res && res.error) sub = "Can't reach the yt-pip helper";
    else if (!res.loading) sub = !c.enabled ? "Background helper is off"
      : !st.daemon ? "Background helper isn't running"
      : st.pipOpen ? "Mini player is open" : (st.playing ? "Playing" : "Ready");
    panel.append(el("h2", { text: "Mini player" }), el("div", { class: "sub", text: sub }));

    if (res && res.error) {
      panel.append(el("div", { class: "err", text: res.error }),
        el("div", { class: "foot", text: "The button and Alt+Shift+P still open the mini player. Settings need the yt-pip native host (see ~/.local/share/yt-pip/README.md)." }));
      return swap(panel);
    }
    if (res.loading) return swap(panel);

    panel.append(
      toggleRow("Run in the background", "Opens, closes and places the mini player for you", c.enabled, () => set("enabled", !c.enabled)),
      el("div", { class: "sect", text: "Behavior" }),
      toggleRow("Open automatically", "When you leave this video's workspace", c.auto, () => set("auto", !c.auto), !c.enabled),
      toggleRow("Close when I go back", "Only one that opened automatically", c.autoClose, () => set("autoClose", !c.autoClose), !c.enabled),
      el("div", { class: "sect", text: "Show on" }),
      seg([["follow", "Every workspace"], ["workspace", "One workspace"]], c.mode, v => set("mode", v)));
    if (c.mode === "workspace")
      panel.append(el("div", { class: "row" }, [seg([[0, "Where it opens"], [1, "1"], [2, "2"], [3, "3"], [4, "4"], [5, "5"], [6, "6"]],
        c.workspace, v => set("workspace", v))]));
    panel.append(
      el("div", { class: "sect", text: "Corner" }),
      seg([["top-left", "↖", "Top left"], ["top-right", "↗", "Top right"], ["bottom-left", "↙", "Bottom left"], ["bottom-right", "↘", "Bottom right"]],
        c.corner, v => set("corner", v)),
      el("div", { class: "sect", text: "Size" }),
      el("div", { class: "row" }, [slider(320, 1280, 40, c.width, v => set("width", v)), el("span", { class: "val", text: c.width + " px" })]),
      el("div", { class: "sect", text: "Opacity" }),
      el("div", { class: "row" }, [slider(40, 100, 5, Math.round((c.opacity || 1) * 100), v => set("opacity", v / 100)),
        el("span", { class: "val", text: Math.round((c.opacity || 1) * 100) + "%" })]),
      el("div", { class: "sect", text: "Videos from" }),
      seg([["app", "YouTube app"], ["all", "App + Chrome tabs"]], c.source, v => set("source", v)),
      el("div", { class: "foot", text: "Super+Alt+P opens or closes the mini player from anywhere." }));
    swap(panel);
  }
  function swap(panel) {
    const old = root.querySelector(".panel");
    if (old) panel.scrollTop = old.scrollTop, old.replaceWith(panel); else root.append(panel);
    const keep = old ? old.scrollTop : 0;
    panel.scrollTop = keep;
  }

  // YouTube re-renders its player on navigation; keep the button in place.
  new MutationObserver(() => ensureButton()).observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener("yt-navigate-finish", ensureButton);
  ensureButton();
})();
