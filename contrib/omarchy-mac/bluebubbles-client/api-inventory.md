# BlueBubbles desktop client: server API surface inventory

Source: `/Volumes/m5pro/bluebubbles/bluebubbles-app` at v2.1.6+desktop.96 (read-only). Paths below are relative to `lib/`.
Server cross-check: `BlueBubblesApp/bluebubbles-server` master (latest release v1.9.12, 2026-10-27), files `packages/server/src/server/api/http/api/v1/httpRoutes.ts`, `socketRoutes.ts`, `middleware/authMiddleware.ts`, `server/events.ts`, read via `gh api` (read-only). docs.bluebubbles.app only returned a 307 and was not read.

## 0. Size

| Area | Dart lines |
|---|---|
| `lib/` total (711 files incl. generated) | 148,146 |
| `app/` (UI: layouts, components, state, animations) | 91,666 |
| `services/` | 28,327 (of which `services/network/` 3,804 incl. `api/` 1,492; `services/backend/` 13,997; `services/ui/` 8,909; `isolates` 1,180) |
| `helpers/` | 10,807 (incl. URL-preview metadata pipeline) |
| `database/` | 9,945 (ObjectBox entities `io/` 3,949) |
| `generated/` (objectbox.g.dart) | 3,423 |
| `utils/` | 2,508 |
| `models/` | 720 |
| Non-UI core (services+database+helpers+models+utils, no generated) | about 52k |
| `app/layouts/settings` / `conversation_view` / `conversation_details` | 27k / 23k / 11k |

- Native Linux shell is tiny: `linux/` has `main.cc`, `my_application.cc`, `splash_screen.cc` plus plugin glue. No Dart tests dir at this tag.
- REST: 11 API wrapper classes. About 79 server-route wrappers defined in `services/network/api/*.dart`; about 64 have a call site outside the test stub `HttpService.testAPI` (`services/network/http_service.dart:268`). Plus 5 Google/Firebase URLs (not BB server). Socket.io: 14 subscribed event names, 1 emitted RPC.
- Server defines about 95 HTTP routes plus 30 legacy socket RPC commands; the client uses about two thirds of HTTP and 1 socket RPC.

## 1. Auth, URL handling, transport

- Single shared secret, the server password, stored as `settings.guidAuthKey`. Sent as query param `guid` on every REST call: `HttpService.buildQueryParams` (`services/network/http_service.dart:67-75`) injects `params['guid']`. Socket.io sends it as handshake query `{"guid": password}` (`services/network/socket_service.dart:303`, `password` getter at :174). Server accepts `guid`, `password` or `token` query param (`authMiddleware.ts`); no header-based auth, no per-device tokens.
- Server also throttles failed auth per client IP (429 + `Retry-After`) and returns 401 on bad password. Client: bad password on socket shows up as an unexplained kick, so `_checkAuth()` pings over HTTP and treats 401 as "Incorrect password" (`socket_service.dart:605-627`).
- Server URL: `settings.serverAddress`, `HttpService.origin` (`http_service.dart:54-59`) takes the URI origin; `apiRoot = origin + "/api/v1"`. `originOverride` replaces it with a LAN address (see local discovery).
- `sanitizeServerAddress` (`helpers/network/network_helpers.dart:9-25`): strips quotes, defaults scheme to `https` for `ngrok.io`, `trycloudflare.com`, `zrok.io`, else `http`. `isValidServerAddress` (:27) accepts http/https with non-empty host.
- Custom headers: `settings.customHeaders` (editable in `app/layouts/settings/dialogs/custom_headers_dialog.dart`) applied as Dio default headers and as socket extra headers (`http_service.dart:107-116`, `socket_service.dart:305`). Auto-added: `ngrok-skip-browser-warning: true` for ngrok, `skip_zrok_interstitial: true` for zrok (:112-115). Metadata (link preview) client deliberately does NOT carry them (`helpers/network/metadata/network/metadata_http_client.dart:73-80`).
- Tunnel specifics: on a 502 from a `trycloudflare` URL, any request is retried once (`runApiGuarded`, :80-103). ngrok / Cloudflare / dynamic DNS are just URLs; no tunnel logic beyond headers + this retry.
- TLS: Dio uses `IOHttpClientAdapter` with `badCertificateCallback = shouldAcceptCertificate` (`http_overrides.dart:8-33`): accept a bad cert only if the cert host equals the configured server host (exact match, or one-label wildcard). Same callback for the socket via `WebsocketAdapter` (`websocket_adapter.dart`). Android also loads user-installed CAs (`user_certificates.dart`); not relevant on Linux. Rust equivalent: rustls with a custom verifier pinned to the configured host.
- Timeouts: connect/receive/send = `settings.apiTimeout` (default set in settings); downloads and uploads multiply receive/send by 12 (e.g. `attachment_api.dart:35-40`, `message_api.dart:206-209`).
- Error envelope: server returns `{status, message, data, error:{type,message}}`; `ApiInterceptor` (`http_service.dart:~252-322`) converts non-2xx JSON failures into resolved `Response` objects and synthesizes an envelope for timeouts/plain-text errors. Success is `statusCode == 200` only (`returnSuccessOrError`, :105-111).
- Payload encryption: optional `encrypt_coms` on the server. Socket acks with `encrypted:true` are AES-decrypted (CryptoJS-style passphrase = password) in `SocketService.sendMessage` (`socket_service.dart:676-690`). REST responses are never encrypted. The desktop client only ever uses sendMessage for the heartbeat (`get-fcm-client`, :665); the encrypted path is effectively dead for current traffic but the server still has the feature.
- Local network discovery (`helpers/network/network_tasks.dart`): optional `localhostPort`; on wifi/ethernet it calls `GET /server/info`, reads `local_ipv4s`/`local_ipv6s`, probes `https` then `http` with `GET /ping` (expects body containing `pong`), else falls back to a /24 port scan with `network_tools`. Result becomes `originOverride`.
- Dynamic server URL (important for desktop): when the socket keeps failing, `SocketService._runUrlDiscovery` (`socket_service.dart:~545-600`) calls `fdb.fetchNewUrl()` (`services/network/firebase/firebase_database_service.dart:68-120`). On desktop this uses the pure-Dart `firebase_dart` package against the user's own Firebase project (config obtained once from `GET /fcm/client`): Realtime DB `config/serverUrl` or Firestore `server/config.serverUrl`. This is how ngrok/Cloudflare quick-tunnel URL changes are followed. Initial setup can also use Google OAuth (desktop: embedded webview via `desktop_webview_auth` fork, redirect `http://localhost:8641/oauth/callback`, `helpers/ui/oauth_helpers.dart:~100-210`) to list Firebase projects and read the URL (see section 2 "Google/Firebase").
- Setup flow on desktop: manual URL + password entry (`app/layouts/setup/pages/sync/server_credentials.dart`, `dialogs/manual_entry_dialog.dart:48`) or Google sign-in; QR scan is mobile only. Setup verifies with `GET /ping`, `GET /server/info`, `GET /fcm/client`.
- Server version gating: `GET /server/info` -> `os_version`, `server_version`, `private_api`, `detected_icloud`, `local_ipv4s`, `local_ipv6s`, `proxy_service` (`services/backend/settings/settings_service.dart:134-187`). Version code = `major*100 + minor*21 + patch`. 43 call sites test `ServerDetails.supports*` / `isMin*` (`models/server_details.dart`): >=42 contacts API/stats/private-api status, >=63 subject lines, >=84 PAPI send, >=142 improved sync, >=148 edit/unsend, >=205 scheduled messages, >=207 handle sync, >=208 PAPI attachment send, >=226 group chat mgmt + rowId sync, >=268 create group chat; macOS gates `isMinBigSur` (19 uses), `isMinVentura` (13 uses, e.g. `ddScan`), Monterey, Sonoma, Sequoia.

## 2. REST endpoints (all under `{origin}/api/v1`, all with `?guid=<password>`)

Notation: file:line is the call in `services/network/api/`. "Used" = has a non-test call site in the app (grep of `HttpSvc.<api>.<method>`). Server column: S = route exists in server master; differences in notes.

### Server info / stats / mac
| Method Path | Purpose | Where | Used |
|---|---|---|---|
| GET `/ping` | liveness, auth check, LAN probe (also `customUrl/api/v1/ping`) | server_api.dart:15 | yes (6 sites + socket auth check) |
| GET `/server/info` | version, macOS, local IPs, private_api, icloud; cached 1 min client-side | server_api.dart:51-75 | yes |
| GET `/server/restart/soft` | restart services | :77 | yes |
| GET `/server/restart/hard` | restart app | :89 | no call site |
| GET `/server/update/check`, POST `/server/update/install` | server update | :101, :113 | yes |
| GET `/server/statistics/totals`, `/media`, `/media/chat` | counts (stats page, v>=42) | :125, :139 | yes |
| GET `/server/logs?count=` | server logs | :151 | yes |
| GET `/` | landing page (test only) | :163 | no |
| POST `/mac/lock` | lock the Mac | :27 | no call site |
| POST `/mac/imessage/restart` | restart Messages.app | :39 | yes |
| Server-only, unused by client | `GET /server/alert`, `POST /server/alert/read`, webhooks (`/webhook` GET/POST, `/webhook/:id` DELETE), `GET /` UI routes, theme: (see backup) | httpRoutes.ts | n/a |

### Chats
| Method Path | Purpose | Where |
|---|---|---|
| POST `/chat/query` body `{with:[participants,lastmessage,sms,archived], offset, limit, sort}` | chat list / full sync | chat_api.dart:14-35 |
| GET `/chat/:guid/message?with=&sort=&before=&after=&offset=&limit=` | page of messages in a chat (full sync, scroll back) | :37-58 |
| GET `/chat/:guid?with=participants` | one chat | :135 |
| GET `/chat/count` | chat count | :119 |
| POST `/chat/new` `{addresses, message, service, method: private-api|apple-script}` | create chat (needs initial message) | :101 |
| PUT `/chat/:guid` `{displayName}` | rename group | :87 |
| POST `/chat/:guid/participant/{add|remove}` `{address}` | add/remove participant | :61 |
| POST `/chat/:guid/leave` | leave group | :74 |
| POST `/chat/:guid/read`, `/unread` | mark read/unread (PAPI) | :147, :159 |
| POST/DELETE `/chat/:guid/typing` | send typing indicator start/stop (PAPI) | :171, :183 |
| GET/POST/DELETE `/chat/:guid/icon` | group icon bytes / multipart upload field `icon` / remove | :195, :217, :244 |
| DELETE `/chat/:guid`, DELETE `/chat/:guid/:messageGuid` | delete chat / delete message | :256, :268 (no app call sites) |
| Server-only: `/chat/:guid/share/contact[/status]`, `DELETE/POST /chat/:guid/participant` | unused | |

### Messages (sending, reactions, edit/unsend, threads, effects, scheduled)
| Method Path | Purpose | Where |
|---|---|---|
| POST `/message/text` JSON `{chatGuid, tempGuid, message, method, [effectId, subject, selectedMessageGuid, partIndex, ddScan]}` | send text. `method` = `private-api` or `apple-script`; the PAPI fields (effect, subject, reply-to `selectedMessageGuid`+`partIndex`) only added when `enablePrivateAPI && privateAPISend`; `ddScan` only when macOS>=Ventura | message_api.dart:118-162 |
| POST `/message/attachment` multipart `{attachment(file), chatGuid, tempGuid, name, method, [effectId, subject, selectedMessageGuid, partIndex, isAudioMessage]}` | send file/voice message (PAPI fields only when `privateAPIAttachmentSend`) | :164-216 |
| POST `/message/multipart` JSON `{chatGuid, tempGuid, effectId, subject, selectedMessageGuid, partIndex, parts:[...], ddScan}` | multi-part messages (text+attachment mixes, mentions) | :221-258 |
| POST `/message/react` `{chatGuid, selectedMessageText, selectedMessageGuid, reaction, partIndex}` | tapback (love, like, dislike, laugh, emphasize, question and `-` prefixed removals) | :260-281 |
| POST `/message/:guid/unsend` `{partIndex}` ; POST `/message/:guid/edit` `{editedMessage, backwardsCompatibilityMessage, partIndex}` | unsend / edit (server>=1.2.6, macOS 13+) | :286, :299 |
| POST `/message/:guid/notify` | "notify anyway" for Focus-silenced messages | :322 |
| POST `/message/query` `{with:[chat,attachment,handle,chat.participants,attachment.metadata,attributedBody,messageSummaryInfo,payloadData], where:[{statement,args}], sort, before, after, chatGuid, offset, limit, convertAttachments}` | main message fetch (incremental sync, row-id `where`) | :42-79 |
| GET `/message/:guid?with=` | single message | :81 |
| GET `/message/count[/updated|/me]?after=&before=` | counts; `/updated` and `/me` are server routes the client never hits except via test | :14-40 |
| GET `/message/:guid/embedded-media` | bytes of rich-link / Digital Touch / handwritten balloon media | :93 |
| Scheduled: GET/POST `/message/schedule`, PUT/DELETE `/message/schedule/:id` | body `{type:"send-message", payload:{chatGuid,message,method}, scheduledFor(ms), schedule:{...}}` | :334-408 |
| Server-only: `GET /message/schedule/:id` | unused | |

Threads: replies use `selectedMessageGuid`+`partIndex` on send; thread tree is rebuilt locally from `threadOriginatorGuid`/`threadOriginatorPart` on received messages (`database/io/message.dart:60-61`, `services/ui/message/messages_service.dart:1584`). Search: no server search call; search is local ObjectBox (no `/message/search` use). Message `where` clauses are only used by sync (`buildRowIdWhereArgs`).

### Attachments
| Method Path | Purpose | Where |
|---|---|---|
| GET `/attachment/:guid/download?original=` | stream to file (`ResponseType.stream`, written to `<path>.part` then renamed) or bytes | attachment_api.dart:25-70; `services/network/downloads_service.dart:274-300` |
| GET `/attachment/:guid/live` | live-photo video part | :74 |
| GET `/attachment/:guid`, `/attachment/:guid/blurhash`, `/attachment/count` | metadata / blurhash / count | :11, :96, :118 (no app call sites; blurhash computed locally if needed) |
| Server-only: `POST /attachment/upload`, `GET /attachment/:guid/download/force` | unused | |
Uploads happen through `/message/attachment` (multipart), not `/attachment/upload`. Server converts HEIC/CAF/etc. when `convertAttachments` / download defaults apply; client plays/shows what comes back.

### Contacts / handles
| Method Path | Purpose | Where |
|---|---|---|
| GET `/contact?extraProperties=avatar` | all server (Mac Contacts + iCloud) contacts with base64 avatars; the ONLY contacts source on desktop | contact_api.dart:10 -> `services/backend/actions/contact_v2_actions.dart:122` |
| POST `/contact` body = list of contact maps | upload device contacts to server | :36 -> contact_v2_actions.dart:723 (mobile origin) |
| POST `/contact/query` `{addresses}` | per-address lookup | :23 (no app call site) |
| POST `/handle/query` `{with, address, offset, limit}` | handle sync (v>=1.5.2) | handle_api.dart:26 |
| GET `/handle/count`, `/handle/:guid`, `/handle/:address/focus` | count / one handle (handle audit panel) / Focus status | :10, :45, :57 |
| GET `/handle/availability/imessage?address=` | is address on iMessage (new chat UI, picks iMessage vs SMS) | :69 |
| GET `/handle/availability/facetime` | unused | :81 |

### FaceTime
| POST `/facetime/answer/:call_uuid` | answer incoming call; server returns a link opened in browser | facetime_api.dart:11 (used) |
| POST `/facetime/leave/:call_uuid` | leave | :24 (unused) |
| Server-only `POST /facetime/session` | create FT link, unused | |

### iCloud / Find My
GET `/icloud/findmy/devices`, POST `/icloud/findmy/devices/refresh`, GET `/icloud/findmy/friends`, POST `/icloud/findmy/friends/refresh`, GET `/icloud/account`, GET `/icloud/contact`, POST `/icloud/account/alias` (`icloud_api.dart:11-90`, all used by the Find My page `app/layouts/findmy/findmy_controller.dart` and profile settings). Live updates via socket `new-findmy-location`.

### Backup / settings sync
GET/POST/DELETE `/backup/theme` and `/backup/settings` (body `{name, data}`; delete takes `{name}`) `backup_api.dart:10-84`, used by backup/restore and theming panels. Settings backups are JSON of client settings, stored on server. Server events `settings-backup-*`/`theme-backup-*` exist but client does not subscribe.

### FCM (not push on desktop, see section 4)
`GET /fcm/client` (Firebase project config for URL discovery, `fcm_api.dart:23`; used on desktop) and `POST /fcm/device` (`fcm_api.dart:10`; only reached when a push token exists, i.e. mobile).

### Non-BB-server HTTP
- `https://firebase.googleapis.com/v1beta1/projects`, `https://www.googleapis.com/oauth2/v1/userinfo`, `https://{rtdb}.firebaseio.com/config.json`, Firestore `.../documents/server/config` and a `PATCH .../server/commands?updateMask.fieldPaths=nextRestart` (`services/network/api/firebase_api.dart:9-55`): Google-account-based server URL lookup and "restart" nudge.
- `https://github.com/BlueBubblesApp/bluebubbles-fonts/releases/latest/download/AppleColorEmoji.ttf` (`http_service.dart:194`): optional Apple emoji font.
- Klipy GIF search (section 7), arbitrary websites for link previews (own Dio client), GitHub API (`github` package, update check).

### Discrepancies vs server source
- Server `GET /ping` returns `{message:"Ping received!", data:"pong"}`; the client's dormant test stub (`http_service.dart:~271`) expects `message=="pong"`. Real code only does `.toString().contains('pong')` (`network_tasks.dart:~245`), so it works. The stub is stale.
- Client `chat.modifyParticipant` uses `/participant/{add|remove}` (POST); server also exposes the newer `POST/DELETE /chat/:guid/participant` form; both exist. Safe to implement either; the compat pair is the one to keep.
- Message counts: server has `count`, `count/updated`, `count/me`; client only ever uses `count` with `after`/`before`.
- Server routes the client never calls: alerts, webhooks, `attachment/upload`, `attachment/:guid/download/force`, `chat/:guid/share/contact`, `message/schedule/:id` GET, `facetime/session`, `handle/availability/facetime`.
- Client wrappers with no call site: `lockMac`, `hardRestart`, `landingPage`, `attachment.fetch/downloadBlurhash/getCount`, `chat.delete/deleteMessage`, `contact.query`, `faceTime.leave`, `handleFaceTimeState`.
- Server-side chat GUID rewriting (prefix `any;`/`iMessage;`/`SMS;` for macOS Tahoe) is applied in socket middleware (`socketRoutes.ts:~103-118`) and `ChatGuidMiddleware` on HTTP; the client sends whatever GUID it stored.

## 3. Socket.io (socket_io_client 3.x, `services/network/socket_service.dart`)

- Connection: URL = `serverAddress` origin, default namespace, transports `['websocket','polling']`, `forceNew`, auto-connect off, query `guid`, extra headers = custom headers, unlimited reconnection with 1 s base delay capped at 60 s (`:303-325`). Heartbeat: emit `get-fcm-client` with ack every interval; N missed -> rebuild (`:644-672`). Connectivity changes and URL discovery rebuild the socket (`:200-260`, `:530-600`).
- Subscribed events (`:350-376`), dispatched to `ActionHandler.handleEvent` (`services/backend/action_handler.dart:83-175`):

| Event | Payload (as consumed) | Handling |
|---|---|---|
| `new-message` | full message JSON: message fields + `chats[]` (first used) + `attachments[]` + `tempGuid` (echo of our send) | `ServerPayload.fromJson`; own sends without tempGuid wait 500 ms for the paired `updated-message`; then `IncomingMsgHandler` (dedupe ring of 100 guids, out-of-order buffer 10 s, chat hydration, ObjectBox write, notification) |
| `updated-message` | same shape; carries delivered/read dates, edits, unsend (`dateEdited`/`dateDeleted`), GUID swap temp -> real | merged into existing message |
| `typing-indicator` | `{guid: chatGuid, display: bool}` | toggles indicator in open chat controller |
| `chat-read-status-changed` | `{chatGuid, read: bool}` | sets chat unread state locally (`:134-141`) |
| `group-name-change`, `participant-added`, `participant-removed`, `participant-left` | `{chats:[chat]}` | refetch chat via `GET /chat/:guid` and update (desktop/web only, `:351-358`) |
| `incoming-facetime` | JSON string `{caller}` (legacy) | notification |
| `ft-call-status-changed` | `{status_id, uuid, handle:{address}, address, is_audio}`; status 4 = incoming, 6 = ended | FaceTime overlay/notification with Answer (HTTP `/facetime/answer`) |
| `imessage-aliases-removed` | `{aliases:[...]}` | notification |
| `new-findmy-location` | location payload | re-broadcast on local `EventDispatcher` for Find My page |
- Not subscribed though the server emits them: `message-send-error`, `group-icon-changed` / `group-icon-removed`, `scheduled-message-*`, `settings-backup-*`, `theme-backup-*`, `server-update*`, `new-server`, `hello-world` (`server/events.ts`). Group icon and scheduled-message changes therefore only refresh on next sync/open.
- Emitted by client: only `get-fcm-client` (heartbeat, `:665`). The 30 legacy socket commands in `socketRoutes.ts` (`get-chats`, `send-message`, etc.) are unused by this client; all RPC is REST.
- Read receipts: delivery/read come as `updated-message` (dateRead/dateDelivered), not a dedicated event. `chat-read-status-changed` only reflects chat-level unread toggles.

## 4. Push and notifications on desktop

- FCM/push: none on desktop. `CloudMessagingService._registerDevice` returns early for `kIsWeb || kIsDesktop` without sending a token (`services/network/firebase/cloud_messaging_service.dart:85-90`); `firebase/CLAUDE.md` says "Desktop uses the direct WebSocket connection and does not use Firebase". UnifiedPush and FCM native paths are mobile-only (`services/ui/unifiedpush.dart`, `java_dart_interop/*`). Desktop therefore only gets messages while the socket is up, and catches up through incremental sync on reconnect (`NetworkTasks.onConnect` -> `SyncSvc.startIncrementalSync`, `helpers/network/network_tasks.dart:~32-44`). No background daemon on desktop: closing to tray keeps the process (and socket) alive; quitting loses delivery. Firebase is still used on desktop for URL discovery via `firebase_dart` (section 1).
- Generation: purely client-side from `new-message`. `IncomingMessageHandler` -> `NotificationsService.createNotification / tryCreateNewMessageNotification` (`services/backend/notifications/notifications_service.dart:211-310`) -> `showDesktopNotif` (:408) which debounces 300 ms per chat, coalesces lines, builds title/avatar, then `DesktopNotifications.showMessage` (`desktop_notification.dart:334-405`).
- Plugin: `flutter_local_notifications` 22 (Windows backend is a forked `flutter_local_notifications_windows`; Linux backend is the stock D-Bus implementation). `LinuxInitializationSettings(defaultActionName: 'Open')` (`notifications_service.dart:105`).
- Linux actions: `LinuxNotificationAction` buttons from user-selected list: "Mark Read" and tapback emojis (tapbacks only when Private API is on, :463-474). Click payload `dm:<base64 json {c: chatGuid, m: messageGuid, a: [actions]}>` encoded in the action key so it survives process restarts (`desktop_notification.dart:21-84`). Icon = sender/group avatar file path; sound = theme sound `message-new-instant` or custom file via `playDesktopNotificationSound`.
- Reply from notification: the reply text field (`showReplyField` setting) exists only in the Windows toast branch (`WindowsTextInput`, `desktop_notification.dart:378`). The Linux branch (:393-405) defines no input, so there is no inline reply on Linux. Handler logic exists for `reply`: `_handleDesktopMessageInteraction` queues an `OutgoingMessage` (`notifications_service.dart:576-598`), `mark-read` -> `chat.toggleHasUnreadAsync(false)` (also hits `POST /chat/:guid/read`), tapback -> `OutgoingReaction` -> `/message/react`, default -> open chat + focus window.
- Linux gaps flagged in code: `activeIds()` returns `[]` (no plugin API) (`desktop_notification.dart:279`), no scheduled reminders on Linux (Windows only, :409). FaceTime: persistent notification with Answer/Decline, or overlay window when app not alive (`action_handler.dart:55-64`).
- Other notification kinds: failed-to-send, aliases-removed, FaceTime, reminders (`createReminder`, :164).

## 5. Local persistence (ObjectBox 5.x, `database/`)

- Store: `<appDocDir>/objectbox` (`database/database.dart:121,149`), DB schema `Database.version = 10`, migrations in `database/migrations/` (chat latest-message, message<->handle relation). `generated/objectbox.g.dart` is committed.
- Entities (`database/io/`): `Chat` (907 lines), `Message` (1034), `Attachment` (401), `Handle` (382), `ContactV2` (291, with embedded `ContactPhone`/`ContactEmail`), `CustomGroup` (46), `FCMData` (98; Firebase project config from `GET /fcm/client`), `ThemeStruct` (483), `ThemeObject` (151), `ThemeEntry` (52). Non-DB DTOs in `database/global/` (Settings, AttributedBody, MessageSummaryInfo, PayloadData, ScheduledMessage, FindMy*).
- Message fields cached (`database/io/message.dart:20-110`): `originalROWID` (server ROWID), unique indexed `guid`, text/subject/country, dateCreated (indexed)/Read/Delivered/Edited/Deleted/Played, isFromMe, itemType, groupTitle, groupActionType, balloonBundleId, associatedMessageGuid/Part/Type (tapbacks), expressiveSendStyleId, threadOriginatorGuid/Part, `attributedBody[]`, `messageSummaryInfo[]`, `payloadData`, `hasDdResults`, `wasDeliveredQuietly`, `didNotifyRecipient`, error code, ToOne `handle`, ToOne `chat`, ToMany `dbAttachments` (backlink), cached link `metadata`.
- Also cached: attachment files on disk under app dir (`attachment.path`, downloaded lazily, `.part` temp), contact avatars (`ContactsSvcV2._saveContactAvatar`), video thumbnails (ffmpeg), settings in a custom shared-preferences store (`services/backend/settings/desktop_shared_preferences_store.dart`), server details in prefs.
- Sync (`services/backend/sync/`, 1,667 lines):
  - Full sync (initial/resync, `full_sync_manager.dart`): `GET /chat/count`; `POST /chat/query` in pages; for each chat `GET /chat/:guid/message` batches (`with=attachment,handle,...`, sort DESC) until a stop-point (messages-per-chat limit or `after` date).
  - Incremental (`incremental_sync_manager.dart`, `sync_service.dart`): triggered on every socket (re)connect, 30 s cooldown (`sync_service.dart:29`). Picks strategy by server version: >=1.6.0 and a saved `startRowId`: `POST /message/query` with a ROWID `where` (`buildRowIdWhereArgs`), reads `metadata.total`, then pages by `offset`; 1.2.0-1.6.0: `GET /message/count?after=` then `POST /message/query` with `after/before` timestamps; <1.2.0: count*2 workaround. Tracks `lastSyncedRowId` and `lastSyncedTimestamp`, persists `settings.lastIncrementalSync` plus resume markers. Group name/photo events inferred from message `itemType`/`groupActionType`; chats lacking participants refetched with `GET /chat/:guid?with=participants` (`:335`).
  - Handle sync (`handle_sync_manager.dart`): `GET /handle/count`, `POST /handle/query` pages (v>=1.5.2).
  - Chat sync (`chat_sync_manager.dart`): chat list only.
- ObjectBox work runs in a global isolate (`services/isolates/global_isolate.dart`, `services/backend/interfaces/*` + `actions/*` pattern: UI -> interface -> isolate action) to keep the UI thread free; `originOverride` is synced to isolates (`network_tasks.dart:~170-205`). A Rust rewrite would replace this with ordinary async tasks.

## 6. Contacts source on desktop

- Server-provided only. `ContactServiceV2._canAccessContacts` returns `SettingsSvc.getServerDetails().supportsContactsApi` on desktop/web (`services/ui/contact_service_v2.dart:60-67`); `requestContactPermission` returns false on desktop. `syncContactsToHandles` on `kIsDesktop` calls `GET /contact?extraProperties=avatar` (`contact_v2_actions.dart:119-122`): per contact `id`, `displayName`, `firstName`, `lastName`, `emails[{address,label}]`, `phoneNumbers[{address,label}]`, `avatar` (base64). Avatars are saved to disk; contacts are matched to `Handle`s by normalized phone (`dlibphonenumber`) / email and stored as `ContactV2` rows.
- `flutter_contacts` and Google/Android account filters are mobile only (`pubspec.yaml:flutter_contacts # mobile only`). No local vCard import on desktop in this path; `vcf_dart` is a dependency (used for share/export of vCards from messages), not a contacts source. Server contacts come from the Mac's Contacts / iCloud (server side). Uploading contacts to the server (`POST /contact`) exists but is driven from mobile.
- Contacts refresh: on setup, on reconnect via sync, and manually in settings.

## 7. Other features needing native plumbing (desktop/Linux)

| Feature | Implementation | Notes for Rust |
|---|---|---|
| System tray | `tray_manager` (`main.dart:47,599-650,711-740`): icon, menu Show/Hide/Close; Linux uses AppIndicator; icon path logic for Flatpak (`app.bluebubbles.BlueBubbles` icon name), Snap, plain | StatusNotifierItem / libappindicator |
| Window state/titlebar | `window_manager`, `bitsdojo_window`, `flutter_acrylic`, `screen_retriever`; `DesktopWindowListener` (`main.dart:267`), close-to-tray, launch at startup (`launch_at_startup`), custom titlebar `app/wrappers/titlebar_wrapper.dart`; Windows taskbar progress only on Windows | |
| Link previews | Generated CLIENT-side: own Dio pipeline in `helpers/network/metadata/` (OG, Twitter, JSON-LD, oEmbed, microdata, site parsers for Amazon/Apple Maps/Reddit/YouTube; SSRF guard, concurrency limiter, cache `Message.metadata`). Server also supplies iMessage rich-link payloads in `payloadData` (and `GET /message/:guid/embedded-media`) when the sender's iPhone produced a preview. The server does NOT fetch URL metadata | meaningful chunk to port (~3k lines) or drop in favor of payloadData |
| Emoji | `emoji_picker_flutter`, `unicode_emojis`; optional Apple Color Emoji font downloaded from GitHub releases (`http_service.dart:194`); `dice_bear` avatars | |
| GIF picker | Klipy (`klipy_flutter`, key from `.env`/`dotenv` `KLIPY_API_KEY`, `app/layouts/conversation_view/widgets/text_field/text_field_icon_bar.dart:19`); chosen GIF downloaded via `HttpSvc.downloadFromUrl` (:227) then sent as an attachment | third-party API key must be supplied |
| Voice messages | `record` plugin to `.m4a` AAC, bitrate 192k (`text_field_suffix.dart:242-247`) with `audio_waveforms` for waveform; sent via `/message/attachment` with `isAudioMessage=true` (PAPI) | needs pipewire/ALSA capture + AAC encoder (ffmpeg or fdk) |
| Location / Find My | `geolocator` for own position, `flutter_map` OSM tiles, Find My via REST + `new-findmy-location` (`app/layouts/findmy/`) ; location sharing messages are vCards/`.loc.vcf` attachments | |
| Attachment viewer / video | `media_kit` + `media_kit_video` + `media_kit_libs_video` (libmpv) (`app/layouts/fullscreen_media/fullscreen_video.dart`, `message/attachment/video_player.dart`); images `photo_view`; PDFs via `pdf`/`printing`; Live Photos via `/attachment/:guid/live`; thumbnails via `ffmpeg_kit_flutter_new_min` or system `ffmpeg` on arm64 (`services/ui/attachments_service.dart:456-510`) | needs libmpv (or gstreamer) and ffmpeg |
| Drag and drop, paste | `desktop_drop` (fork), `pasteboard` (`conversation_view/pages/handlers/drop_zone_manager.dart`, `text_field/handlers/clipboard_paste_handler.dart`) | |
| Private API gated features | Require server `private_api` true + client `enablePrivateAPI`: tapbacks (`/message/react`), reply-to-message, effects (`effectId`), subject lines, send via PAPI `method`, edit/unsend, typing indicators out (`/chat/:guid/typing`), mark read/unread, group rename/participants/icon/leave, chat create via PAPI, notify anyway, scheduled messages w/ PAPI method, `isAudioMessage`, mentions (multipart). Gates in `models/server_details.dart` and `Settings` (`privateAPISend`, `privateAPIAttachmentSend`, `enablePrivateAPI`), enforced client-side in `message_api.dart:118-216` and many UI sites |
| macOS-version-gated | `ddScan` (Ventura), edit/unsend (macOS 13+), Sonoma/Sequoia checks in reactions/stickers UI | |
| Auth/OAuth | `google_sign_in` (mobile/web), webview OAuth with `desktop_webview_auth` fork on desktop, localhost redirect `:8641` | optional if Rust client uses manual URL entry |
| Misc plugins | `local_auth` (app lock), `url_launcher`, `share_plus` (limited on Linux), `app_links`, `network_tools` LAN scan, `connectivity_plus`, `permission_handler` (mobile), `secure_application` (not Linux) | |
| Linux packaging | Flatpak/Snap detection (`isFlatpak`, `isSnap`), `linux/build.sh`, webkit2gtk-4.1 for OAuth webview | |

## 8. Minimal viable surface for a Rust rewrite (derived from the above)

Hard requirements for read/send parity on a desktop client:
- Auth: `guid` query param, `/ping`, `/server/info`, custom headers, TLS exception for self-signed server host, socket.io with `guid` handshake and `forceNew`.
- REST (about 25): ping, server/info, chat/query, chat/:guid/message, chat/:guid, chat/count, chat/new, chat/:guid/read|unread, message/text, message/attachment, message/multipart, message/react, message/query, message/:guid, message/count, attachment/:guid/download, handle/query|count, contact?extraProperties=avatar, handle/availability/imessage, fcm/client (only if replicating Firebase URL discovery).
- Socket events: new-message, updated-message, typing-indicator, chat-read-status-changed, participant/group-name events, ft-call-status-changed, imessage-aliases-removed, plus `get-fcm-client` heartbeat. Optional: new-findmy-location.
- Everything else is optional parity: edit/unsend, notify, scheduled, group management/icons, FaceTime answer, Find My, iCloud account/alias, backup/theme sync, server admin (restart/update/stats/logs).
- Heavy non-API work: ObjectBox schema (Chat/Message/Attachment/Handle/ContactV2) -> SQLite; sync algorithms (rowId + timestamp + legacy); notification actions on D-Bus; link-preview pipeline; media (mpv/ffmpeg); AAC voice recording; Klipy API key.
