# BlueBubbles v2.1.6+desktop.96 - Linux desktop settings inventory and slim-profile plan

Repo: /Volumes/m5pro/bluebubbles/bluebubbles-app (read only). All paths are relative to it.
Target: one owner, Omarchy/Hyprland (Wayland), native-iMessage-like look. No Android/iOS/Windows/macOS needs.

Conventions
- "Default" = field initializer in `lib/database/global/settings.dart` (cited as `S:n`). I diffed these against the `Settings.fromMap` fallbacks (`settings.dart:781+`, used when a pref key is absent). They agree except `previewImageQuality` (initializer 0.75 at S:53, effective 1.0 from fromMap via key `imageQuality`).
- Line numbers marked "~" are approximate (from grep of a long list); others were read directly.
- Linux = whether the tile/feature is reachable on a Linux desktop build.
- Verdicts: KEEP / HIDE (gate the UI; stored value still exists) / CHANGE DEFAULT (to X).
- ACCOUNT = server- or account-level. Never touched by a preset (section 9).

---------------------------------------------------------------------------

## 0. Settings shell (what the owner sees)

The top-level list is built in one function: `lib/app/layouts/settings/widgets/search/settings_items_list.dart` `buildSettingItemList()` (line 42, ~840 lines). Every top-level tile is a `SearchableSettingItem`. This is the single best gating point for hiding whole panels; the settings search UI (`settings_page.dart:110-230`) only renders what the list returns, so hidden tiles also vanish from search.

| Tile (list line) | Opens | Linux | Verdict |
|---|---|---|---|
| Profile (55-85) | `pages/profile/profile_panel.dart` ("iMessage Profile") | yes | KEEP (account-level contents, see 9) |
| Connection & Server (96-175) | `pages/server/server_management_panel.dart` -> `connection_panel/*` (3 skin variants) | yes | KEEP, trim (section 2) |
| Scheduled Messages (inside Connection section, only if server supports) | `pages/scheduling/*` (3 skins) | yes | KEEP (iMessage has Send Later) |
| Message Reminders (inside Connection section) | gated `Platform.isAndroid \|\| isWindows` | NO | already hidden |
| Appearance Settings (~200) | `pages/theming/theming_panel.dart` | yes | KEEP, trim (section 3) |
| Media Settings (~245) | `pages/message_view/attachment_panel.dart` | yes | KEEP, trim |
| Notification Settings (~280) | `pages/system/notification_panel.dart` | yes | KEEP, trim |
| Chat List Settings (~315) | `pages/conversation_list/chat_list_panel.dart` | yes | KEEP, trim |
| Conversation Settings (~350) | `pages/message_view/conversation_panel.dart` | yes | KEEP, trim |
| Custom Groups (~395) | `pages/custom_groups/*` (3 skins) | yes | HIDE (BlueBubbles-only concept) |
| Desktop Settings (409-440) | `pages/desktop/desktop_panel.dart` | yes | KEEP, trim |
| More Settings (446-480) | `pages/misc/misc_panel.dart` ("Advanced") | yes | KEEP, heavily trim |
| Private API Features (~492) | `pages/advanced/private_api_panel.dart` | yes | KEEP (unlocks typing, read receipts, tapbacks, edit) |
| Redacted Mode (~514) | `pages/advanced/redacted_mode_panel.dart` | yes | HIDE (screenshot-demo feature) |
| Tasker Integration (~530) | gated `Platform.isAndroid` | NO | already hidden |
| Google Firebase (~555; "Notification Providers" on mobile) | `pages/advanced/firebase_panel.dart` | yes | KEEP, move under Server |
| Contacts Management (~594) | `pages/contacts/*` (3 skins) | yes (`!kIsWeb`) | KEEP |
| Storage Analyzer (~624) | `pages/storage/*` | yes | HIDE |
| Developer Tools (~648) | `pages/misc/troubleshoot_panel.dart` (+ logging, cache tuning, handle audit, soft-deleted chats) | yes | HIDE tile; reachable only with a dev flag |
| Backup & Restore (~690) | `pages/server/backup_restore_panel.dart` | yes | HIDE (restore overwrites the preset and prefs, see 9) |
| Leave Us a Review (~722) | external | pointless | HIDE |
| Make a Donation (~734) | gated `!kIsWeb && (isAndroid\|\|isWindows)` | NO | already hidden |
| Join Our Discord (~748) | external link | yes | HIDE |
| About & More (~761) | `pages/misc/about_panel.dart` (links, changelog, devs, Keyboard Shortcuts dialog at about_panel.dart:201-345) | yes | KEEP only Keyboard Shortcuts + version |
| Reset App (~793) | confirm dialog, wipes local data | yes | KEEP (local only) |
| App Version row (~826) | | yes | KEEP |

---------------------------------------------------------------------------

## 1. Desktop Settings (`pages/desktop/desktop_panel.dart`)

| Setting (pref key) | File:line | Default | Linux | Verdict / reason |
|---|---|---|---|---|
| Launch on Startup (`launchAtStartup`) | desktop_panel.dart:58-72; S:207; writes `~/.config/autostart/<app>.desktop` (`lib/database/io/launch_at_startup.dart:47-56`; Flatpak uses the Background portal, ~line 20-35) | false | yes | HIDE. On Hyprland use `exec-once` / uwsm; the .desktop file is ignored unless an XDG autostart runner exists. Start with the `minimized` CLI arg (main.dart: `arguments.firstOrNull == "minimized"` at ~25 and ~108). |
| Show Startup Entry | desktop_panel.dart:73-90 | n/a | yes | HIDE with the above |
| Launch on Startup Minimized (`launchAtStartupMinimized`) | desktop_panel.dart:91-118; S:208 | false | yes | HIDE (use the `minimized` arg) |
| TitleBar Style (`titleBarStyle` native/custom/hidden) | desktop_panel.dart:121-166; S:247; applied main.dart:84-90 and ~152-159; read titlebar_wrapper.dart:28-31, ui_helpers.dart:556 | `custom` | yes | CHANGE DEFAULT to `hidden`, HIDE the picker. Hyprland draws no decorations; `custom` adds in-app min/max/close (titlebar_wrapper.dart:71-105); `native` makes GTK a header bar (linux/my_application.cc:82-111, used on Wayland). `hidden` is the most Messages-like. Caveat: no drag area, fine on a tiler. |
| Minimize to Tray (`minimizeToTray`) | desktop_panel.dart:179-205 (only shown for `custom`); S:209; used titlebar_wrapper.dart:78-79 | false | only with `custom` | HIDE (Hyprland has no minimize) |
| Close to Tray (`closeToTray`) | desktop_panel.dart:212-228; S:210; `setPreventClose` main.dart:~143; `onWindowClose` main.dart:318-326 (hide vs `exit(0)`) | **true** | yes (tray_manager, needs a StatusNotifier host such as Waybar `tray`) | HIDE toggle, keep true. If no tray host exists the hidden window cannot be recovered: make the default conditional on a tray host, else exit on close. |
| Windows Taskbar Badge (`windowsTaskbarBadge`) | desktop_panel.dart:234-250; S:219 | true | NO | already hidden |
| Desktop Notifications (`desktopNotifications`) | desktop_panel.dart:251-262; S:216; checked at notifications_service.dart:409 | true | yes | KEEP (master switch) |
| Add/Change Notification Sound (`desktopNotificationSoundPath`) | desktop_panel.dart:263-330; S:218; played by `playDesktopNotificationSound` notifications_service.dart:640-655 (media_kit) | null | yes | HIDE. When null Linux uses the freedesktop sound-theme event `message-new-instant` (desktop_notification.dart:402), the native behavior. Setting a path silences that (notifications_service.dart:523). |
| Notification Sound Volume (`desktopNotificationSoundVolume`) | desktop_panel.dart:335-360; S:217 | 100 | yes | HIDE (custom sound only) |
| Notification Actions (`selectedActionIndices`, `actionList`) | desktop_panel.dart:368-480; S:226-235 (Windows `[0,1,2,3]`, else `[0,1,2]`); used notifications_service.dart:474 | Mark Read, Love, Like | yes (3 buttons; display depends on the notification daemon) | HIDE; CHANGE DEFAULT to `[0]` (Mark Read). Tapbacks need Private API and most Hyprland daemons render few buttons. |
| Show Reply Field (`showReplyField`) | desktop_panel.dart:388-420 (Windows gate); S:225 | true | NO: `replyInput` is only used in the Windows branch (desktop_notification.dart:360-363); the Linux details (393-404) have no input | already hidden; no inline reply on Linux notifications |

---------------------------------------------------------------------------

## 2. Server / connection (`pages/server/**`) - ACCOUNT, handle with care

Tiles in `pages/server/connection_panel/connection_panel_helpers.dart`: QR Code (261), iMessage Statistics (294), Re-configure with BlueBubbles Server (335), Manually Sync Messages (397), Configure Custom Headers (444), Sign in with Google (499), Fetch Latest URL (515), Detect Localhost Address (529; port 544; `localhostPort` S:123), Use IPv6 (588; `useLocalIpv6` S:124), Fetch Server Logs (625), Restart iMessage (671), Restart Private API & Services (716), Restart BlueBubbles Server (767), Check for Server Updates (821). Also `server_management_panel.dart`, `oauth_panel.dart`, `imessage_stats/*`.

| Item | Verdict |
|---|---|
| Server address / GUID auth key / custom headers (`serverAddress` S:43, `guidAuthKey` S:42, `customHeaders` S:44) | KEEP, never preset. Connection status tile (`ConnectionServerTile`) stays. |
| Re-configure, Manually Sync, Fetch Latest URL, Sign in with Google, Custom Headers | KEEP (needed to recover a broken connection), group under one "Server" page |
| Detect Localhost, Use IPv6 | HIDE |
| iMessage Statistics, QR Code, Fetch Server Logs | HIDE |
| Restart iMessage / Private API / Server, Check for updates | KEEP. They act on the server, ACCOUNT; never auto-trigger. |
| `apiTimeout` (S:119, 30000 ms; Misc panel 238) | keep default, HIDE tile |
| Firebase panel (`pages/advanced/firebase_panel.dart`): Open Firebase Console (62), Use Firebase `enableFcm` (103, gated `!kIsDesktop && !kIsWeb` so hidden on Linux), Status (118), Load Configurations from Server (135), from Google (253), Re-register Device (264), Clear Configurations (340) | KEEP on Linux (desktop gets background push via `firebase_dart`, pubspec.yaml:66) but put under "Server". ACCOUNT-level; never preset. |
| UnifiedPush (`enableUnifiedPush` S:169, `endpointUnifiedPush` S:170) | Android only; no UI on Linux |

---------------------------------------------------------------------------

## 3. Appearance (`pages/theming/theming_panel.dart`, `theme_studio/*`, `advanced/*`, `avatar/*`)

| Setting | File:line | Default | Linux | Verdict / reason |
|---|---|---|---|---|
| App Theme (Light/Dark/System), AdaptiveTheme | theming_panel.dart:68-80; main.dart:330-335 (`initial: savedThemeMode ?? system`) | System | yes | KEEP System (follows the OS color scheme, section 10) |
| Theme Studio | theming_panel.dart:83-95; `theme_studio/*` | n/a | yes | HIDE |
| Avatar Scale (`avatarScale`) | theming_panel.dart:106-118; S:116 | 1.0 | yes | HIDE |
| App Skin (`skin` iOS/Material/Samsung) | theming_panel.dart:126-146; S:194 | **iOS** | yes | Keep iOS, HIDE picker. 247 refs in 89 files use `Skins.*`, so never delete skins, only lock the value. iOS skin is closest to Messages.app. |
| Tablet Mode (`tabletMode`) | theming_panel.dart:147-161 (`!kIsDesktop`) | true | NO | already hidden |
| Immersive Mode, Refresh Rate, Display | theming_panel.dart:162, 485-520 (`!kIsDesktop`) | | NO | already hidden |
| Window Effect + opacity sliders | theming_panel.dart:194-314 (`kIsDesktop && Platform.isWindows`); `lib/utils/window_effects.dart:~92` `setEffect` returns unless Windows; S:213-215 | disabled | NO | already hidden. (`Window.initialize()` from flutter_acrylic still runs on Linux, main.dart:~146; no blur from here. Use compositor `windowrule` for blur/opacity.) |
| Use Linux Accent Color (`useDesktopAccent`) | theming_panel.dart:320-333; S:250 | false | tile shows but is **dead on Linux**: accent is applied only by `getStructsFromData` = `Platform.isWindows ? _applyWindowsAccent : passthrough` (themes_service.dart:683-685). The only Linux effect is the group-avatar background (ui_helpers.dart:714-716). | HIDE now; make real per section 10 |
| Material You (+ variants) | theming_panel.dart:335-370 (`!kIsWeb && !kIsDesktop && monetPalette != null`) | | NO | already hidden. Presets are still seeded (themes_service.dart:57-70, 459-500). |
| Colors from Media (`colorsFromMedia`) | theming_panel.dart:372-428 (`!kIsDesktop`); S:108 | false | NO | already hidden |
| Colorful Avatars (`colorfulAvatars`) | theming_panel.dart:430-445 (iOS skin); S:80 | false | yes | keep false (Messages uses gray); HIDE tile |
| Colorful Bubbles (`colorfulBubbles`) | theming_panel.dart:447-456; S:81 | false | yes | keep false; HIDE tile |
| Custom Avatar Colors / Custom Avatars | theming_panel.dart:458-482; `avatar/*` | | yes | HIDE |
| Download iOS Emoji Font | theming_panel.dart:521-650 | not downloaded | yes | KEEP optional (Apple-style emoji; third-party font download) |
| Advanced theming editor, per-chat themes | `advanced/*`, `widgets/content/advanced_theming_tile.dart`, `dialogs/create_new_theme_dialog.dart`, `dialogs/old_themes_dialog.dart` | | yes | HIDE |

---------------------------------------------------------------------------

## 4. Notifications (`pages/system/notification_panel.dart`; tabs: Global, Chat)

| Setting | File:line | Default | Linux | Verdict |
|---|---|---|---|---|
| Send Notifications on Chat List (`notifyOnChatList`) | 56-66 (`!kIsDesktop`); S:106 | false | NO | already hidden |
| Notify for Reactions (`notifyReactions`) | 84-93; S:107 | true | yes | KEEP |
| Text Detection (`globalTextDetection`) | 95-135; S:109 | "" | yes | HIDE |
| Hide Message Text (`hideTextPreviews`) | 141-150; S:55 | false | yes | KEEP (iMessage "Show Previews") |
| Notify When Incremental Sync Complete (`showIncrementalSync`) | 152-161; S:64 | false | yes | HIDE |
| Quick Reaction from Notifications / type | 163-205 (`!kIsDesktop`); S:182-183 | | NO | already hidden |
| Chat tab (per-chat mute) | 336 `ChatList`, 370-470 | | yes | KEEP (iMessage "Hide Alerts") |

---------------------------------------------------------------------------

## 5. Chat list (`pages/conversation_list/chat_list_panel.dart`)

| Setting | Line | Default | Linux | Verdict |
|---|---|---|---|---|
| Show Sync Indicator (`showSyncIndicator`) | 42; S:88 | true | yes | keep true, HIDE |
| Message Status Indicators (`statusIndicatorsOnChats`) | 55; S:118 | false | yes | CHANGE DEFAULT true; KEEP tile |
| Filtered Chat List (`filteredChatList`) | 73; S:101 | false | yes | HIDE |
| Filter Unknown Senders (`filterUnknownSenders`) | 86; S:110 | false | yes | CHANGE DEFAULT true; KEEP tile |
| Unarchive On New Message (`unarchiveOnNewMessage`) | 100; S:140 | false | yes | HIDE |
| Hide Dividers (`hideDividers`) | 117; S:82 | false | yes | HIDE |
| Dense Conversation Tiles (`denseChatTiles`) | 128; S:86 | false | yes | HIDE |
| Pin Configuration, mobile rows/cols | 135-220 (`!kIsDesktop`); S:199-202 | | NO | already hidden |
| Pin Rows / Pins Per Row (desktop, iOS skin) | 223-402; `pinRowsPortrait` 3, `pinColumnsLandscape` 4 | 3 / 4 | yes | KEEP |
| Pinned Order | 404-416 | | yes | KEEP |
| Swipe actions (`swipableConversationTiles`, `materialRightAction`, `materialLeftAction`) | 418-470 (`!kIsDesktop && !iOS`); S:99,186-187 | | NO on iOS skin | already hidden |
| Move Chat Creator to Header (`moveChatCreatorToHeader`) | 484; S:92 | false | yes | HIDE |
| Show Filters in Header (`showFiltersInHeader`) | 497; S:93 | false | yes | HIDE |
| Show Custom Group Filters (`showCustomGroupFilterChips`) | 510; S:94 | false | yes | HIDE |
| Camera FAB (`cameraFAB`) | 516-525 (`!kIsDesktop`); S:95 | | NO | already hidden |

---------------------------------------------------------------------------

## 6. Conversation (`pages/message_view/conversation_panel.dart`)

| Setting | Line | Default | Linux | Verdict |
|---|---|---|---|---|
| Show Delivery Timestamps (`showDeliveryTimestamps`) | 76; S:100 | false | yes | CHANGE DEFAULT true (Messages shows Delivered/Read time); KEEP tile |
| Show Chat Name as Placeholder (`recipientAsPlaceholder`) | 86; S:90 | false | yes | HIDE |
| Show Avatars in DM Chats (`alwaysShowAvatars`) | 98; S:105 | false | yes | HIDE (Messages hides them in DMs) |
| Smart Suggestions (`smartReply`) | 105 (`!kIsDesktop`) | false | NO | already hidden |
| Show Replies To Previous Message (`repliesToPrevious`) | 124; S:122 | false | yes | KEEP |
| Link preview policy (`linkPreviewPolicy`) | 165; S:63 | contactsOnly | yes | KEEP (privacy-correct) |
| Message Options Order (`detailsMenuActions`) | 184; `message_options_order_panel.dart`; S:238; enum `conversation_view/widgets/message/popup/details_menu_action.dart:10` | all | yes | HIDE |
| Text Field Buttons (`textFieldButtons`: Gif, Emoji, Location) | 198; `text_field_buttons_panel.dart`; S:233; Linux support table `conversation_view/widgets/text_field/buttons/text_field_button.dart:20-24` (Gif yes, Emoji yes, Location NO) | Gif, Emoji | yes | HIDE panel; CHANGE DEFAULT `[Emoji]` (GIF picker is a network third party, not iMessage-native) |
| Sync Group Chat Icons | 206-238 | | yes | HIDE (action) |
| Store Last Read Message (`scrollToLastUnread`) | 246; S:141 | false | yes | HIDE |
| Hide Names in Reaction Details (`hideNamesForReactions`) | 258; S:144 | false | yes | HIDE |
| Send / Receive Sound (`sendSoundPath`, `receiveSoundPath`, `soundVolume`) | 266-440; S:125-127 | null / 100 | yes | HIDE |
| Auto-open Keyboard, Swipe open/close keyboard, Hide Keyboard on Scroll, Open Keyboard on STB (`autoOpenKeyboard` S:54, `swipeToCloseKeyboard` S:96, `swipeToOpenKeyboard` S:97, `hideKeyboardOnScroll` S:91, `openKeyboardOnSTB` S:98) | 452-509 (`!kIsDesktop`) | | NO | already hidden |
| Double-Click Message for Details (`doubleTapForDetails`) | 520; S:85 | false | yes | keep false (conflicts with Quick Tapback; right-click opens the menu) |
| Send Message with Enter (`sendWithReturn`) | 534 (`!kIsDesktop`); S:84 | false | NO | already hidden. Desktop Enter = send, Shift+Enter = newline is hard-wired (`keyboard_shortcut_handler.dart:36-41, 88-92`; `text_field_component.dart:285`) |
| Scroll To Bottom When Sending (`scrollToBottomOnSend`) | 544; S:137 | true | yes | HIDE |

---------------------------------------------------------------------------

## 7. Attachments & media (`pages/message_view/attachment_panel.dart`)

| Setting | Line | Default | Linux | Verdict |
|---|---|---|---|---|
| Auto-download Attachments (`autoDownload`) | 38; S:47 | true | yes | KEEP |
| Only Auto-download on WiFi (`onlyWifiDownload`) | 51; S:48 | false | no network-type signal on desktop | HIDE |
| Max Concurrent Downloads (`maxConcurrentDownloads`) | 60; S:49 | 2 | yes | HIDE |
| Image Preview Quality (`previewImageQuality`) | 96-110; S:53 | 0.75 init / 1.0 effective | yes | HIDE; set 1.0 explicitly in the preset |
| Auto-save, Save Media Location, Save Documents Location, Ask Where to Save | 78-200 (`!kIsDesktop`); S:50-52,117 | | NO | already hidden |
| Mute in Attachment Preview / Fullscreen (`startVideosMuted`, `startVideosMutedFullscreen`) | 216, 227; S:102-103 | true / true | yes | KEEP |
| Arrow Key Direction (`fullscreenViewerSwipeDir`) | 245-262; S:196 | RIGHT | yes | HIDE |

---------------------------------------------------------------------------

## 8. More Settings (`pages/misc/misc_panel.dart`, titled "Advanced") and Private API

| Setting | Line | Default | Linux | Verdict |
|---|---|---|---|---|
| Secure App / Security Level (`shouldSecure`, `securityLevel`) | 36-145 (gate `!kIsWeb && !(kIsDesktop && !Platform.isWindows)`); S:190-191 | false | NO | already hidden; `SecureApplication` is bypassed on Linux (main.dart:402-406) |
| Incognito Keyboard | 147 (`!kIsDesktop`); S:192 | | NO | already hidden |
| High Performance Mode (`highPerfMode`) | 176; S:65 | false | yes | HIDE |
| Reduce Motion (`reduceMotion`) | 187-195 (`kIsDesktop`); S:66 | false | yes | KEEP |
| Scroll Speed Multiplier (`scrollVelocity`) | 206; S:83 | 1.0 | yes | HIDE |
| API Timeout (`apiTimeout`) | 238; S:119 | 30000 | yes | HIDE |
| Cancel Queued Messages on Failure (`cancelQueuedMessages`) | 289; S:121 | false | yes | HIDE |
| Replace Emoticons with Emoji (`replaceEmoticonsWithEmoji`) | 314; S:145 | false | yes | KEEP; consider default true |
| Enable Spellcheck / Language (`spellcheck`, `spellcheckLanguage`) | 330, 351 (`kIsDesktop \|\| kIsWeb`); S:211-212 | true / "auto" | yes | KEEP |
| Send Delay (`sendDelay`) | 362; S:89 | 0 | yes | HIDE |
| 24 Hour Format (`use24HrFormat`) | 395; S:104 | false | yes | KEEP |
| Allow Upside-Down Rotation | 404-424 (`Platform.isAndroid`); S:120 | | NO | already hidden |
| Maximum Group Avatar Count (`maxAvatarsInGroupWidget`) | 428; S:204 | 4 | yes | HIDE |
| Log level (`logLevel`) | logging panels; S:222 | info | yes | HIDE with Developer Tools |
| Cache purge (`cachePurgeBackgroundLevel` S:73 "light", `cachePurgeMemoryPressureLevel` S:76 "moderate", `cachePurgeExcludedCaches` S:79) | `pages/misc/cache_tuning_panel.dart` | | yes | HIDE |
| Contact sync (`syncContactsAutomatically` S:128, `contactSyncAccountName` S:132, `contactSyncAccountType` S:136) | Android contacts | | NO | leave false |
| No Linux UI: `keepAppAlive` S:139, `sendEventsToTasker` S:138, `lastReviewRequestTimestamp` S:159, `enableFcm` S:175 (default true) | | | | do not touch |

Private API (`pages/advanced/private_api_panel.dart`), ACCOUNT-adjacent (needs the server helper): `enablePrivateAPI` S:151 (tile 154) false; `privateSendTypingIndicators` S:152 (179); `privateMarkChatAsRead` S:153 (206); `privateManualMarkAsRead` S:154 (232); `enableQuickTapback` S:178 (248) + `quickTapbackType` S:179 (274); `editLastSentMessageOnUpArrow` S:158 (296); `privateSubjectLine` S:155 (324); `privateAPISend` S:156 (349); `privateAPIAttachmentSend` S:157 (374). `serverPrivateAPI` S:150 is a server-reported flag.
Verdict: KEEP the panel. CHANGE DEFAULT (only when the server reports Private API): typing indicators true, auto mark-read true, edit-on-up-arrow true, subject line false.

Redacted Mode (`redactedMode` S:162, `hideAttachments` 163, `hideContactInfo` 164, `generateFakeAvatars` 165, `hideMessageContent` 166): HIDE, default false.
Profile panel: "User Profile Name" (profile_panel.dart:93; `userName` S:142 "You"), photo (`userAvatarPath` S:143), "Start Chats Using" (397, iMessage account alias; ACCOUNT). KEEP, never preset.

---------------------------------------------------------------------------

## 9. Server- or account-level state a client preset must NEVER write

From `Settings.deviceLocalKeys` (settings.dart:~338-353) plus server-linked items:
- `serverAddress`, `guidAuthKey`, `iCloudAccount`, `customHeaders`, `finishedSetup`, `reachedConversationList`
- `firstFcmRegisterDate`, FCM data (`saveFCMData`, settings_service.dart:131), `enableFcm`, `enableUnifiedPush`, `endpointUnifiedPush`
- `lastIncrementalSync`, `lastIncrementalSyncRowId` (sync cursors; resetting forces a re-sync)
- `localhostPort`, `useLocalIpv6`, `apiTimeout` (connection behavior)
- `serverPrivateAPI` and the server version fields in `PrefsSvc.server`
- Profile: `userName`, `userAvatarPath`, "Start Chats Using"
- Server actions: Restart iMessage / Private API / Server, Check for Updates, Manually Sync
- Backup & Restore: saves/loads the whole settings map via the server (`backup_restore_actions.dart`); a restore overwrites the preset
- Device-local paths: `sendSoundPath`, `receiveSoundPath`, `desktopNotificationSoundPath`, `colorsFromMedia`
Rule: the preset is an allowlist of UI-preference keys, never a denylist, and must not go through `Settings.updateFromMap(..., includeAll: true)` (settings.dart:509, the backup/restore path).

---------------------------------------------------------------------------

## 10. How the theme is chosen; can it follow the system / Omarchy

- Mode: `AdaptiveTheme` (main.dart:330-335), `initial: savedThemeMode ?? AdaptiveThemeMode.system`. `didChangePlatformBrightness` (main.dart:~654-666) re-applies and emits `theme-update`. So light/dark follows whatever brightness signal Flutter's Linux embedder reads (GTK/portal color-scheme; Omarchy flips it). I did not run it to confirm live switching.
- Colors do not come from GTK. Themes are `ThemeStruct` rows (ObjectBox) selected by name through `PrefsSvc.theme`. Defaults: Bright White / OLED Dark (themes_service.dart:459-472; fallbacks 692, 705), plus Nord, Music Theme and generated Material You presets. Read at main.dart:239-240 (first frame) and `_loadTheme` (themes_service.dart:668-672).
- Dynamic color: `ThemesService.init` (57-67) and `initDynamicColorsDeferred` (78-82, Linux, post-splash) call `DynamicColorPlugin.getCorePalette()/getAccentColor()` (`dynamic_color` 1.8.1). Whether these return anything under Hyprland is unverified; expect null. `desktopAccentColor` is only consumed when `useDesktopAccent` AND `Platform.isWindows` (themes_service.dart:683, 725-727).
- No existing hook for a colors file, GTK CSS or Omarchy theme: no `system_theme`/`gsettings`/`colors.toml` in `lib/`.
- Cleanest hook: `ThemesService.getStructsFromData(light, dark)` (themes_service.dart:683-685) is the choke point for `_loadTheme` (668) and `changeTheme` (713). Make the `Platform.isWindows` branch also fire on Linux when slim is on and feed it the Omarchy accent (`~/.config/omarchy/current/theme/colors.toml` or a JSON the Omarchy theme hook writes). `_applyWindowsAccent` (725-796) already turns one accent into a full M3 palette through `CorePalette` and `harmonizeWith`, so this is a small change. For live updates, watch the file and call the same path as `refreshDesktopAccent` (570-574). Leave `BubbleColors` (iMessage blue/green, defined in the theme extensions, e.g. themes_service.dart:~108) alone.
- Apply the override also before `runApp` (main.dart:239-250) to avoid a first-frame flash of the wrong palette.

---------------------------------------------------------------------------

## 11. Notifications on Linux (how it works)

- Plugin: `flutter_local_notifications` ^22.0.1 (pubspec.yaml:80). The Linux backend speaks `org.freedesktop.Notifications` over D-Bus, so Mako / Dunst / SwayNC render them. Wrapper `lib/services/backend/notifications/desktop_notification.dart` (`DesktopNotifications`); orchestration in `notifications_service.dart`. Init: `LinuxInitializationSettings(defaultActionName: 'Open')` (notifications_service.dart:~101).
- Message toast (`showMessage`, desktop_notification.dart:333-407; Linux branch 393-404): avatar icon (`FilePathLinuxIcon`), action buttons, sound `ThemeLinuxSound('message-new-instant')`, `suppressSound` when a custom sound path is set. No category, no explicit urgency, no inline reply. Calls (FaceTime) use critical urgency and never expire (497-508).
- Grouping: per-chat id ranges (`groupBase`/`_nextGroupId`, 124-148); a new message cancels and re-shows that chat's toast (notifications_service.dart:~515-540); stacked messages are summarized ("+N earlier messages").
- Click-through: payload encodes the chat GUID (`DesktopMessageData`), handled by `handleResponse` (~238-262) and replayed after startup (`_pendingInteractions`, 202-215). Linux cannot list active notifications (line 279 returns `[]`) and cannot schedule (so reminders are off).
- Native-feel gaps (small edits in the Linux details): set category and desktop-entry (`app.bluebubbles.BlueBubbles`), set urgency explicitly, default actions to Mark Read only.
- Background delivery: socket.io + `firebase_dart`; the tray keeps the process alive when the window is closed.

---------------------------------------------------------------------------

## 12. Existing keybindings (Linux)

Global, `lib/main.dart:362-395` (`shortcuts:`); Actions map at ~675-690:
- Ctrl+, Settings
- Alt+N, Ctrl+N (desktop) New chat
- Ctrl+F Search
- Alt+R, Ctrl+R (desktop) Reply to most recent message
- Alt+G, Ctrl+G, Ctrl+Shift+R Incremental sync (three aliases)
- Ctrl+Shift+1..6 (bound as `! @ # $ % ^`, lines 376-387) quick reaction on most recent message
- Ctrl+Down / Ctrl+Tab next chat; Ctrl+Up / Ctrl+Shift+Tab previous chat
- Ctrl+I chat details
- Esc go back / close
Text field (`keyboard_shortcut_handler.dart`): Enter sends, Shift+Enter newline (36-41, 88-92); Up arrow edits the last sent message when the box is empty and `editLastSentMessageOnUpArrow` + Private API (46-60); Tab switches subject/body when `privateSubjectLine` (76-86). `text_field_component.dart:464` Ctrl+V paste intent (Linux image-paste special case at ~562). Autocomplete uses Esc/Tab/Enter/Up/Down (585-588). The in-app list is `about_panel.dart:201-345`.
Slim suggestion: keep Ctrl (Super is owned by Hyprland); collapse the sync aliases to one; keep Ctrl+N, Ctrl+F; consider Ctrl+W to hide to tray.

---------------------------------------------------------------------------

## 13. Other desktop features (non-settings)

- Window size/position persisted via `PrefsSvc.desktop` (main.dart:~166-195, `DesktopWindowListener` 276-327); on Wayland only size is restored (`isWaylandSession`, main.dart:263). Min size 300x300.
- Tray: `initSystemTray` (main.dart:710-726; menu Show/Hide App, Close App at 728-736). Left click shows the window.
- Native splash: `linux/splash_screen.cc` + `bluebubbles/splash` channel.
- Google sign-in webview: `desktop_webview_auth` (WebKitGTK, pubspec.yaml:47), only for Firebase config.
- Layout dirs (`lib/app/layouts/`): camera (not on desktop), chat_creator, chat_selector_view, contact_selector_view, conversation_details, conversation_list, conversation_view, findmy (location permission skipped on Linux, findmy_controller.dart:208), fullscreen_media, handle_selector_view, setup, startup, settings.
- Drag and drop: `desktop_drop` (pubspec.yaml:42, patched). Share on Linux: `lib/utils/share.dart:18-70`. Location-send button: not on Linux (`location_button.dart:20`).
- Messages-adjacent, keep: FindMy, FaceTime join notice, Scheduled messages. Hide: Custom Groups, iMessage Stats, Storage Analyzer.

---------------------------------------------------------------------------

## 14. Recommended mechanism: SlimProfile (no upstream code deleted)

Two additive layers.

### A. Build-time UI gate
Add `lib/helpers/slim_profile.dart`:
```dart
const bool kSlim = bool.fromEnvironment('BB_SLIM'); // flutter build linux --dart-define=BB_SLIM=true
class SlimProfile {
  static bool get on => kSlim;
  static bool show(String id) => !kSlim || _kept.contains(id); // allowlist of kept tiles
  static const _kept = <String>{/* ids */};
}
```
Being `const`, release builds tree-shake hidden branches. Gate points (add `&& SlimProfile.show('id')` to existing conditions; remove nothing):
1. `settings_items_list.dart` `buildSettingItemList` - wrap the top-level `SearchableSettingItem`s for Custom Groups, Redacted Mode, Storage Analyzer, Developer Tools, Backup & Restore, Review, Discord. Hides the entry and its search hits.
2. `desktop_panel.dart` - startup block (58-118), titlebar block (121-166), tray toggles (179-228), sound/volume/actions (263-480).
3. `theming_panel.dart` - Theme Studio 83-95, avatar scale 106, skin 126-146, accent 320-333, colorful 430-456, custom avatars 458-482.
4. `chat_list_panel.dart`, `conversation_panel.dart`, `attachment_panel.dart`, `misc_panel.dart`, `notification_panel.dart` - per tile as tabled (most already sit inside `if (!kIsWeb ...)` gates; extend them).
5. `about_panel.dart:201-345` - keep Keyboard Shortcuts + version only.
6. `connection_panel_helpers.dart` - tiles at 261, 294, 529-590, 625.
Non-settings: shortcut map `main.dart:362-395` (drop duplicate aliases when slim), Linux details `desktop_notification.dart:393-404`, `text_field_button.dart:20-24` (`_buttonPlatformSupport`; hide Gif when slim).

### B. Config-time preset (seed defaults, user can still change visible tiles)
- Defaults load in `Settings.getSettings()` (settings.dart:324-335): prefs go through `Settings.fromMap` (781+); a fresh install returns `Settings()` (line 333). Add a `slimDefaults` map and use `Settings.fromMap({...slimDefaults, ...items})` (and `Settings.fromMap(slimDefaults)` for the empty case), invoked from `SettingsService.init` (settings_service.dart:50) behind `SlimProfile.on`. Existing stored values win, so it only seeds absent keys.
- Optional external override: if `~/.config/bluebubbles/slim.json` exists, merge it (allowlist-filtered) before `getSettings()`, so Omarchy can change defaults without a rebuild. The prefs file is `shared_preferences.json` under `FilesystemSvc.appDocDir` (`desktop_shared_preferences_store.dart:146`), keys prefixed `flutter.`; do not edit it by hand (cross-isolate lock, atomic writes, `.bak`).
- Locked, never shown: skin = iOS, theme mode = system, closeToTray = true, titleBarStyle = hidden.

Proposed preset (allowlist)
```
skin: 0 (iOS)   theme: system   titleBarStyle: hidden   closeToTray: true   minimizeToTray: false
launchAtStartup: false   (autostart via Hyprland exec-once, `bluebubbles minimized`)
desktopNotifications: true   desktopNotificationSoundPath: null   selectedActionIndices: [0]
notifyReactions: true   hideTextPreviews: false
statusIndicatorsOnChats: true   filterUnknownSenders: true   showDeliveryTimestamps: true
colorfulAvatars: false   colorfulBubbles: false   denseChatTiles: false   hideDividers: false
textFieldButtons: [Emoji]   previewImageQuality: 1.0   autoDownload: true
startVideosMuted: true   reduceMotion: false   spellcheck: true   replaceEmoticonsWithEmoji: true
doubleTapForDetails: false   linkPreviewPolicy: contactsOnly
# only when serverPrivateAPI == true:
enablePrivateAPI: true   privateSendTypingIndicators: true   privateMarkChatAsRead: true   editLastSentMessageOnUpArrow: true
```

### C. Items needing real code, not just gates
1. Omarchy/GTK palette: `themes_service.dart:683` plus the first-frame path at `main.dart:239`.
2. Titlebar default: make it platform-aware (Wayland and not GNOME -> `hidden`) instead of the global `custom` at S:247 / fromMap (~line 918).
3. Check for a tray host before defaulting `closeToTray` (else the hidden window is unrecoverable).
4. Linux notification polish in `desktop_notification.dart:393-404`.
5. Set `previewImageQuality` explicitly (initializer/fromMap mismatch).
