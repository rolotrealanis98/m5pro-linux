# Decision memo: Rust rewrite of the BlueBubbles desktop client

Status: proposal for the owner, 2026-11-27. Nothing here was started. Basis: the client at `v2.1.6+desktop.96` (read in full for the API surface) and the BlueBubbles server master, v1.9.12 (`httpRoutes.ts`, `socketRoutes.ts`, `events.ts`, `authMiddleware.ts`, read-only).

## Recommendation

Do not rewrite now. Optimize the Flutter client first (phase 2: frame cadence, Impeller A/B, slim profile, fractional scale workaround) and decide again with numbers.

Reasons:
- The server API a desktop client needs is small (about 25 REST calls and 9 socket events for send/receive parity). The API is not the cost.
- The cost is everything around it: 148k lines of Dart (about 52k non-UI, about 92k UI), ObjectBox sync and caches, a 3k-line link-preview pipeline, media (mpv/ffmpeg), tapbacks/edit/unsend/effects/threads rendering, notifications, contacts, Find My, FaceTime join. Parity is a year of work for one person; an MVP is weeks.
- The Flutter problems measured so far (README, "Baseline") look fixable inside Flutter or its Linux runner: the runner is 3 small C++ files. The one structural limit is the GTK3 embedder: integer scale only (no `wp_fractional_scale`). That matters only if the owner runs a fractional Hyprland scale or mixed-DPI monitors.
- Upstream keeps shipping fixes. A rewrite forks away from every server feature the BlueBubbles team adds (new Private API calls, macOS-version gates: 43 version checks in the client).

Revisit the rewrite if, after phase 2, any of these hold: fractional scale is needed and cannot be worked around; idle RSS stays far above 300 MB or idle wakeups stay high; scrolling cannot reach the 120 Hz cadence on the GPU; the owner wants a client that is deliberately smaller than the upstream feature set for good.

## What a native client has to implement

All paths under `{origin}/api/v1`, every call carries `?guid=<server password>` (server also accepts `password` or `token`). Evidence: `lib/services/network/http_service.dart:67-75`, `socket_service.dart:303-325`.

### Auth and transport
- One shared secret (the server password), no per-device tokens. Socket.io handshake carries it in the query. Failed auth: 401, and the server throttles per IP (429 + `Retry-After`).
- Server URL entry (ngrok, Cloudflare tunnels, dynamic DNS, LAN) is just an origin; optional custom headers (ngrok skip-warning etc.). A 502 from a `trycloudflare` URL is retried once.
- TLS: accept a bad certificate only when the certificate host equals the configured server host (`http_overrides.dart:8-33`). Needs a custom rustls verifier.
- The server URL can change (tunnel restarts). The Flutter client discovers the new URL through Firebase RTDB/Firestore using the config from `GET /fcm/client` (`socket_service.dart:~545-600`). A Rust client needs either the same (Google OAuth + Firebase REST) or manual URL entry.
- Optional payload encryption (`encrypt_coms`): socket acks AES-decrypted with the password. REST is never encrypted.

### REST surface (minimum for read/send parity, about 25 calls)
`/ping`, `/server/info` (version, macOS, Private API flag; gate features on it), `/chat/query`, `/chat/count`, `/chat/:guid`, `/chat/:guid/message`, `/chat/new`, `/chat/:guid/read` and `/unread`, `/chat/:guid/typing`, `/message/text`, `/message/attachment` (multipart), `/message/multipart`, `/message/react` (tapbacks), `/message/query`, `/message/:guid`, `/message/count`, `/attachment/:guid/download`, `/contact` (GET, with avatars), `/handle/query`, `/handle/availability/imessage`.
Optional parity (the other roughly 40 used wrappers): edit and unsend, notify-anyway, scheduled messages, group rename/participants/icon, embedded media (rich links, Digital Touch), Live Photo video, FaceTime answer, Find My and iCloud, theme/settings backup, server admin (restart, update, stats, logs), handle audit.
Of about 79 wrappers, about 64 have call sites; the server defines about 95 routes.

### Socket.io events
Subscribed: `new-message`, `updated-message` (this is also how delivered and read receipts, edits and unsends arrive), `typing-indicator`, `chat-read-status-changed`, `group-name-change`, `participant-added`, `participant-removed`, `participant-left`, `incoming-facetime`, `ft-call-status-changed`, `imessage-aliases-removed`, `new-findmy-location`. Emitted: only the `get-fcm-client` heartbeat. Not subscribed though emitted by the server: `message-send-error`, group icon, scheduled, backup and update events.

### Push
None on desktop. Messages arrive only while the socket is connected; the client runs an incremental sync on every reconnect (30 s cooldown): by ROWID on server 1.6.0+, by timestamp before that. A Rust client keeps the same model (daemon with a tray icon and D-Bus notifications).

### Local state and sync
ObjectBox entities Chat, Message (about 40 fields), Attachment, Handle, ContactV2, plus themes. Becomes SQLite (rusqlite or sqlx). Needs the full sync (chat pages, then per-chat message pages), the incremental sync and handle sync, ordering by `originalROWID` and `dateCreated`, temp-GUID to real-GUID swap on send, thread tree rebuilt from `threadOriginatorGuid`.

### Features needing native plumbing
| Feature | Today | Rust equivalent |
|---|---|---|
| Notifications | `flutter_local_notifications` over D-Bus, buttons Mark Read and tapbacks, no inline reply on Linux | `notify-rust` or zbus (inline reply via the reply hint on mako/swaync is possible, better than today) |
| Tray | `tray_manager` (AppIndicator) | StatusNotifierItem via `ksni` or zbus |
| Contacts | server only (`GET /contact`) | same |
| Link previews | generated client-side (OG, Twitter, JSON-LD, oEmbed, site parsers, SSRF guard, cache) | `scraper` plus own pipeline, about 3k lines of Dart to port |
| Video and audio | `media_kit` (libmpv), ffmpeg thumbnails | libmpv binding or GStreamer; ffmpeg for thumbnails |
| Voice messages | `record` to AAC `.m4a` | PipeWire capture plus an AAC encoder (ffmpeg or fdk) |
| GIFs | Klipy (key in `.env`) | Klipy REST |
| Emoji | picker plus system font | system fontconfig through Pango: color emoji works out of the box |
| Drag and drop, paste | `desktop_drop`, `pasteboard` | GTK4 `DropTarget` and clipboard |
| Search | server-side message query plus local filtering | same |
| Private API features | gated on server `private_api` and client flag: tapbacks, replies, effects, subject, edit/unsend, outgoing typing | same calls, same gates |

## UI stack candidates for Omarchy and Hyprland

| Stack | Fit | Risks |
|---|---|---|
| GTK4 plus libadwaita through `gtk4-rs` (optionally `relm4` for the state model) | Best: native Wayland, fractional scale and HiDPI handled by GTK4, IME and accessibility, Pango color emoji, dark mode and accent through GTK settings and CSS, native-feeling text input. Omarchy already themes GTK. | Chat bubbles, long virtualized lists and an image/video timeline take custom widgets (`GtkListView` is good at this). libadwaita styling is opinionated; a Messages-like look is custom CSS. |
| iced | Pure Rust, GPU (wgpu), easy custom look | Weak text input and IME on Wayland, no native a11y, rich text and emoji layout are still rough, no native theme integration. |
| Slint | Declarative, small, Wayland, good scale support | Royalty-free licence terms apply; rich text editing and long lists are limited; custom everything. |
| egui | Fast to prototype | Immediate mode, poor IME, not a chat UI toolkit. Not recommended. |

Recommendation if a rewrite happens: `gtk4-rs` plus libadwaita, SQLite, `reqwest` plus `rust-socketio` (check that crate against the server's socket.io v4 handshake before committing; the fallback is `tokio-tungstenite` with a hand-written engine.io layer), `zbus` for D-Bus (notifications, tray, theme portal).

Omarchy theming: Omarchy changes themes with hooks (`~/.config/omarchy/hooks/theme-set.d/`, themes under `~/.config/omarchy/themes`). A GTK4 client would read the generated GTK CSS or the colors file and reload on the hook; a Flutter client needs a Dart-side hook (see SLIM-PROFILE.md, item C1). Both are small.

## Effort (one developer, evenings and weekends not counted, careful work)

| Milestone | Scope | Estimate |
|---|---|---|
| Spike | Connect, auth, chat list, one conversation read-only, socket events | 1-2 weeks |
| MVP (daily-driver for one owner) | Send text and attachments, receive live, tapbacks, read receipts and typing, notifications and tray, contacts and avatars, search, SQLite cache with sync, slim settings | 8-12 weeks |
| Near parity | Edit/unsend, replies and threads, effects, link previews, video and audio, voice messages, group management, scheduled sends, FaceTime join, Find My, backup | +6-9 months |
| Full parity with upstream | Plus tracking upstream's moving target | open-ended |

Rough comparison: the Flutter optimization plan (phase 2) is 1-3 weeks and keeps every feature.

## What would be lost

- Every feature not ported (Find My, FaceTime join, Custom Groups, themes studio, scheduled messages at first); the long tail of macOS-version gates.
- Upstream fixes and server features arrive for free today; after a rewrite they need porting by hand.
- Cross-platform use: irrelevant for the owner, relevant if this should ship in omarchy-mac-pkgs for others (a Linux-only GTK client is fine there; Flutter is already Linux-only for us).
- Risk: iMessage-specific rendering details (attributed body, balloons, stickers, reactions placement) are subtle and were worked out over years in the Dart code.

## What would be gained

- Native fractional scaling and HiDPI, native text input and IME, system emoji, GTK theming, lower RSS (a GTK4 and Rust client typically idles at tens of MB; this Flutter build idles around 500 MB, see README), lower idle wakeups, startup in tens of ms, true inline reply in notifications, packaging as a small native binary and a normal PKGBUILD without a Flutter toolchain (which is attractive for omarchy-mac-pkgs: the build needs Flutter 3.47.8 pinned from git today).

## Decision gates

1. After phase 2, compare the numbers in README with the targets: idle CPU under 1 percent, idle RSS under 300 MB, scroll at the panel's refresh rate with p99 under 12 ms, cold start to first frame under 1 s. If Flutter meets them: stay.
2. If not, spike the Rust client for 2 weeks (connect, list, read-only conversation) and measure the same numbers before committing to the MVP.

## Update after phase 2 (2026-11-28)
Everything in the Flutter optimization plan that could be done without the device is in: desktop-following scale and font, color emoji, image cache cap, slim profile, Omarchy theme, and `BB_DIAG` instrumentation. The decision gate stays the same and now has a one-command measurement (`tools/device-run.sh`, README "Device run"): upstream, upstream plus diagnostics, and our build, with startup marks, idle frames and wakeups, RSS, and build/raster times while scrolling. Open facts that bear on the decision: whether the 60 fps result is UI-thread or raster-bound, what keeps the idle app drawing, and whether our build starts slower than upstream (one run showed longer CPU settling; unconfirmed). No rewrite work was started.
