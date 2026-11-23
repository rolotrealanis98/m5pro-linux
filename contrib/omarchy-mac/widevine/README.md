# widevine

Protected video (Widevine DRM) in the browser on the J716s. Gap-map row `desktop.drm-video`.

- Scope: `generic` (any aarch64 Linux, 16K or 4K pages). Status: **staged, written offline, not run on the Mac.** What was
  checked here (2026-11-17, on the Studio): Google's service, the signed CDM download, its ELF layout and the install/uninstall
  logic against a scratch dir. Not checked: loading in the Mac's Chrome, and any service.
- Upstream target: none needed for Google Chrome (Google ships the CDM). Omarchy: its aarch64 `widevine` package does not exist
  (the 2026-11-17 extras run could not install it); a Chromium-on-ARM Omarchy would take `install.sh`'s approach (component
  CRX into the user data dir) instead of an Asahi-style patched package. Asahi's `widevine-installer` is the reference, not a dependency.

## What changed in 2026 (the research result)

- **Google Chrome for Linux arm64 exists** (Debian/RPM repos at dl.google.com since about 2026-07-27; the Mac runs
  `google-chrome-stable 157.0.8103.78`, from `dl.google.com/linux/chrome/deb/.../binary-arm64`). Its `.deb` bundles
  `/opt/google/chrome/WidevineCdm/` with the **native `linux_arm64` CDM** (`4.10.3112.0`, 20,041,928 bytes; same file the
  component updater serves). I extracted both and read the ELF headers: all `PT_LOAD` segments are **64K-aligned**, no RWX
  segment, only `GLIBC_2.17` symbol versions (no `DT_RELR` tag, no outline-atomics helpers). So it loads on 16K pages with
  stock glibc: **no patching, no Lacros image, no Asahi fixup**. The old route (`widevine-installer`: download the ChromeOS
  Lacros 120 image, `widevine_fixup.py` pads segments, adds `GLIBC_ABI_DT_RELR` and two atomics stubs; its own header says new
  Widevine does not need it) is obsolete for this CDM.
- Google's component update service still serves the same CDM for `linux`/`arm64` (app `oimompecagnajdejgnnjijobebaeigek`,
  CRX3, publisher-signed, sha256 in the HTTPS answer). That is what `install.sh` downloads when a browser has none.
- Security level: Linux has no hardware CDM, so this is Widevine **L3** (software, "Software Secure"). No browser on Linux
  reaches L1, including on Apple hardware; do not expect 4K or HDR from any service.

## Per browser on the Mac

| Browser | Package | Widevine | Action |
|---|---|---|---|
| **Google Chrome 157** (the Mac's, `chrome-gpu-ab`, `avd-video`) | Google's arm64 deb (or an AUR repack of it) | bundled in `/opt/google/chrome/WidevineCdm` + component updater (`chrome://components`) | none: `install.sh --check`; the script installs only if the bundled CDM is missing or does not load |
| Chromium (Arch Linux ARM `chromium`) | pacman | Arch builds support an external CDM; no component updater CDM on most builds | `install.sh --browser chromium` puts the signed CDM in `~/.config/chromium/WidevineCdm/<ver>/` and writes `latest-component-updated-widevine-cdm` (the same mechanism Chrome uses). Unverified on the Mac (not installed there) |
| Firefox | pacman | Mozilla's GMP feed has no linux-aarch64 Widevine as far as known (unverified) | `install.sh --browser firefox`: CDM under `~/.local/share/m5pro-widevine/`, `MOZ_GMP_PATH` via `~/.config/environment.d/`, `user.js` prefs as Asahi's `gmpwidevine.js`. Unverified |

The default browser is auto-detected (`xdg-settings`, then `/opt/google/chrome`); `--browser` overrides. The Omarchy extras
`widevine` pacman entry (`omarchy-extras.sh`) never applied on aarch64 and is not needed.

## What works per service (expected, L3; verify with the test below)

Sourced from secondary coverage, not the services' own docs (neither Netflix nor Disney publish exact L3 tables); the attended test
below records the real numbers.

| Service | Expected on Linux Chrome L3 | Note |
|---|---|---|
| Netflix | plays; 720p, some reports 1080p | check Netflix's playback-info overlay (Ctrl+Alt+Shift+D); no 4K/HDR |
| Disney+ | plays; 720p | the cap is consistently reported for desktop browsers |
| Spotify web player | plays (Widevine for encrypted audio) | needs the CDM only; no resolution issue |
| Apple TV web | Widevine in Chrome; expected up to 1080p, unverified | Safari/FairPlay 4K is macOS only |
| YouTube Premium | ordinary YouTube is not DRM; purchased/rented films use Widevine, L3 tier | "downloads" are an app/mobile feature, not desktop web |
| Prime Video, Max | plays at SD to 720p on L3 (unverified) | |

Video decode (AVD VA-API, `../avd-video`) and the CDM are separate. Protected streams are decoded in the browser's media
pipeline; whether hardware decode applies to encrypted frames on this stack is **not known**: with L3 the clear frames come back
to the renderer, so expect it may fall back to software. Record CPU in the test.

## Licence

Widevine is Google's proprietary CDM under its own licence (the `LICENSE` shipped in the CRX; `install.sh` prints it). It must not
be redistributed, so **no CDM bytes are in this repository and none may be added**; each install downloads from Google. The
Asahi installer's "interoperability only, not supported by Google" notice applies to the old Lacros route; the route here uses
the CDM Google itself ships for linux_arm64.

## install.sh

    bash install.sh --check [--online]        read-only: page size, browser, bundled and in-use CDM, ELF 16K check, dlopen
    bash install.sh                           install only if no working CDM is in use (idempotent; --force reinstalls)
    bash install.sh --probe                   non-interactive: headless browser (throwaway profile) requests com.widevine.alpha via EME; exit 0 = granted
    bash install.sh --uninstall               remove what the script installed (restores a previous pointer)

Runs as the desktop user (it refuses root). Needs `python3` and `openssl`. `widevine_tool.py` does the work: it asks
`update.googleapis.com` for the linux/arm64 Widevine component, downloads the CRX3 over HTTPS from Google's mirrors, and
requires (1) the exact size, (2) the sha256 from the service answer, (3) the CRX3 **publisher signature verified with openssl
against the public key whose derived id is the Widevine component id**, (4) manifest name and version match, (5) an AArch64 ELF
with 16K-compatible `PT_LOAD` alignment and no RWX segment, (6) a real `dlopen` by the system loader. Anything failing aborts
before touching the profile. Nothing is installed system-wide; the browser's own updater later supersedes the pointer file.

## Is "CDM present" complete? (2026-11-23 review)

- File side: yes for Google Chrome. The bundled 4.10.3112.0 `linux_arm64` CDM has 64K-aligned segments (re-fetched and re-verified
  from Google's service on the Studio: CRX3 signature ok, sha256 `7d50bcc5...ed43`, 4 PT_LOAD at 0x10000, GLIBC_2.17 only). The
  Asahi 16K fixup (segment padding, `GLIBC_ABI_DT_RELR`, atomics stubs) is not needed; page size is irrelevant at 64K alignment.
- No flags needed: Chrome registers the bundled CDM itself (`WidevineCdm/manifest.json` beside the binary) and its component updater
  keeps it current. `--enable-features` is only a Chromium-from-pacman question (that build has no bundled CDM; `install.sh --browser chromium`).
- Not proven: that EME actually grants the key system on this Mac, and that services play. `--probe` covers the first without the
  owner; the second is the attended 2-minute test (`/Volumes/m5pro/bench/requests/widevine-1.md`).
- Chrome launched with the owner's custom flags (`~/.config/chrome-flags.conf`): none of the GPU A/B flags affect EME, but note that
  `--disable-features=...` lists containing `WidevineCdm`/`MediaFoundation`-style entries would.

## Attended test (5 minutes, owner at the Mac, Chrome closed first)

1. `bash install.sh --check --online` : expect "bundled CDM loads", `page size 16384`, version equals Google's.
   If it says no CDM: `bash install.sh`, then restart Chrome.
2. Open Chrome, `chrome://components` : "Widevine Content Decryption Module" shows a version (`4.10.x`); click "Check for
   update". `chrome://version` shows the Widevine line too.
3. `https://bitmovin.com/demos/drm` (Widevine tab): must play. Failure reasons that matter: "No supported key system" = CDM not
   loaded; a license error = network/account side.
4. Spotify web (`open.spotify.com`), any track: plays (no "Playback of protected content is not enabled").
5. Netflix title: plays; Ctrl+Alt+Shift+D, note the playing resolution. Disney+ the same. In `top` note Chrome's CPU.
6. If a page fails, `chrome://media-internals` (player events, key system `com.widevine.alpha`) and
   `journalctl --user -b | grep -i -E "widevine|cdm"` are the evidence; attach them and the `--check` output.

Remove: `bash install.sh --uninstall` (a no-op for the bundled Chrome CDM).

## Risks and unknowns

- Written offline: the Chrome-on-the-Mac result is unverified until the attended test runs.
- A 16K problem would show as `dlopen` failing in `--check`; the ELF headers say it will not.
- Service-side blocking (a service refusing this platform's attestation) is outside our control and cannot be tested offline.
