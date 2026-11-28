# Slim profile (approved 2026-11-27; implemented in patches 0002, 0006, 0008 and 0009)

Goal: feel like a native iMessage client on Omarchy: few settings, iOS skin, theme and notifications that fit the desktop. Full evidence, with file and line for every option: `settings-inventory.md` (about 120 options across 11 screens).

## Mechanism (no upstream code deleted)

1. Build-time gate: `lib/helpers/slim_profile.dart` with `const bool kSlim = bool.fromEnvironment('BB_SLIM')` (`flutter build linux --dart-define=BB_SLIM=true`) and `SlimProfile.show(id)`. Each hidden tile gets `&& SlimProfile.show('id')` added to its existing condition. The build is const, so release builds tree-shake the hidden branches; a normal build is byte-for-byte upstream behaviour, which keeps rebasing on new tags cheap.
2. Config-time preset: a `slimDefaults` map merged under the stored prefs in `Settings.getSettings()` (`lib/database/global/settings.dart:324`), seeding only absent keys, so the owner can still change anything left visible. Optional `~/.config/bluebubbles/slim.json` (allowlisted keys only) lets Omarchy change defaults without a rebuild.
3. Rule: the preset is an allowlist of UI preference keys. It never touches server or account state (server address, auth key, custom headers, FCM data, sync cursors, profile name and photo, "Start Chats Using", Backup and Restore) and never goes through the backup/restore path (`Settings.updateFromMap(..., includeAll: true)`).

## What to hide (about 40 tiles, stored values stay)

Top level: Custom Groups, Redacted Mode, Storage Analyzer, Developer Tools, Backup and Restore, Leave a Review, Discord, most of About (keep Keyboard Shortcuts and version).
Desktop panel: startup entry toggles (use `exec-once = bluebubbles minimized` in Hyprland), minimize-to-tray, custom notification sound and volume, notification action editor.
Appearance: Theme Studio, avatar scale, skin picker (lock to iOS), colorful avatars and bubbles, custom avatar colors, advanced and per-chat theme editors, the "Use Linux Accent Color" tile (dead on Linux today).
Chat list and conversation: sync indicator, filtered list, unarchive-on-new-message, dividers, dense tiles, header-creator and filter-chip options, chat-name placeholder, avatars in DMs, option order editors, send/receive sounds, keyboard behaviours, scroll and send-delay tuning, group-icon sync action.
Advanced: high performance mode, scroll multiplier, API timeout, cancel-queued, group avatar count, cache purge, log level, wifi-only download, concurrent downloads, fullscreen arrow direction.
Server page: QR code, statistics, server logs, localhost and IPv6 detection. Keep the recovery actions (re-configure, manual sync, fetch URL, custom headers, restart iMessage/Private API).

## Defaults to change

| Setting | From | To | Why |
|---|---|---|---|
| `titleBarStyle` | custom | hidden on Wayland non-GNOME | Hyprland draws no decorations; the Flutter-drawn min/max/close buttons overlap the conversation header and minimize does nothing (see GLITCHES.md) |
| `statusIndicatorsOnChats` | false | true | Messages shows delivery state in the list |
| `filterUnknownSenders` | false | true | Messages "Filter Unknown Senders" |
| `showDeliveryTimestamps` | false | true | Messages shows Delivered/Read time |
| `selectedActionIndices` | Mark Read, Love, Like | Mark Read | native toast; tapbacks from a toast are rarely wanted |
| `previewImageQuality` | 0.75 init / 1.0 effective mismatch | 1.0 explicit | removes a latent inconsistency |
| `replaceEmoticonsWithEmoji` | false | true | typing :) |
| Private API options (only when the server reports Private API) | false | typing indicators, auto mark-read, edit on Up arrow true | iMessage behaviour |
| Theme | System light/dark only | follow Omarchy palette | see below |

Kept as is: iOS skin, system theme mode, `closeToTray` true (but only if a StatusNotifier host exists, otherwise a hidden window cannot be recovered: needs a check), link previews for contacts only, Enter sends and Shift+Enter newlines.

## Code changes the preset alone cannot do

- C1 Omarchy palette: colors come from `ThemeStruct` rows, not GTK. Hook point `ThemesService.getStructsFromData` (`lib/services/ui/theme/themes_service.dart:683`), which today applies an accent only on Windows; extend to read an Omarchy colors file (and apply before `runApp`, `main.dart:239`, to avoid a wrong-colored first frame). Re-read on the Omarchy `theme-set.d` hook (signal or a file watch).
- C2 Notification polish for Linux (`desktop_notification.dart:393-404`): category, desktop-entry, urgency; inline reply is not available on Linux today (Windows branch only).
- C3 Keybindings (`main.dart:362-395`): keep Ctrl (Super belongs to Hyprland), collapse the three sync aliases to one, keep Ctrl+N and Ctrl+F, add Ctrl+W to hide to tray.
- C4 Platform-aware titlebar default and the tray-host check above.

## Effort

Gate and preset: 2-3 days (mostly mechanical, about 40 gate points in 8 files). C1: 1-2 days. C2-C4: 1-2 days. Each as its own commit on `m5pro/client`, upstreamable independently only where useful to BlueBubbles (C2, C4, the Impeller opt-in); the slim profile itself is ours.

## Implemented (phase 2)
- `BB_SLIM` compile-time flag (`lib/helpers/ui/slim_profile.dart`), turned on by `build.sh` for the branch. A normal build is unchanged.
- Hiding is by exact title in `SettingsTile`, `SettingsSwitch` and `SettingsOptions` (about 45 titles) plus 7 top-level entries (Custom Groups, Redacted Mode, Storage Analyzer, Developer Tools, Backup and Restore, review, Discord). Section headers left empty disappear. Tile plus slider pairs (image quality, notification volume, scroll speed, API timeout, avatar scale) are not hidden because the slider has no title; they stay visible.
- Seeded defaults for keys never saved: `statusIndicatorsOnChats`, `filterUnknownSenders`, `showDeliveryTimestamps` true; `selectedActionIndices` [0] (Mark Read); `previewImageQuality` 1.0; `replaceEmoticonsWithEmoji` true. Account, server and Private API sending options (typing indicators, auto mark-read, edit on Up) are deliberately not seeded.
- Outside the flag, for every build of the branch: titlebar hidden by default, start on the chat list, Omarchy theme following, desktop font and scale (patches 0002 to 0008), each with a Desktop Settings control.
- Not done: C2 notification polish, C3 keybinding cleanup, the tray-host check. Skin stays whatever is saved (the owner's is the iOS skin default; the picker is hidden).
