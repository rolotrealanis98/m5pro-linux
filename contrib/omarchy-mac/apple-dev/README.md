# apple-dev

iOS and macOS app development from Omarchy on the J716s: [omarchy-apple-dev](https://github.com/joshuaswarren/omarchy-apple-dev)
(xtool, Swift 6.4, the Darwin SDK, Linux stand-ins for actool, ibtool, momc and xcstringstool).

- Scope: `generic` (aarch64). Status: installed 2026-11-23; a SwiftUI app builds for iOS (`xtool dev build`, 3.9 s). Device
  install, sign-in and lldb are not tried yet (they need the owner and the iPhone). Upstream: omacom/omarchy#14255 (the Install >
  Development > iOS menu entry, open).

## What is on the Mac

| Path | What | Undo |
|---|---|---|
| `pkg:swift-bin` 6.4.3 | AUR, built with makepkg as rolo, installed with `pacman -U` (`~/aur/swift-bin/`) | `pacman -R swift-bin` |
| `/etc/pacman.conf` `IgnorePkg = swift-bin` | Swift must match the Xcode SDK (6.4 = Xcode 27); an update would break every build | delete the line |
| `pkg:usbmuxd`, `pkg:libimobiledevice`, `pkg:zip`, `pkg:poppler`, `pkg:libheif`, `pkg:inotify-tools`, `pkg:libxml2-legacy`, `pkg:patchelf` | what the installer's pacman step needs | `pacman -R` the ones nothing else needs |
| `/usr/lib/swift/usr/share/pm/SwiftBuild_*/{CopyStringsFile,CoreBuildSystem,NativeBuildSystem}.xcspec` | strings encoding defaults (utf-8 in, binary out): CopyStrings cannot re-encode outside Darwin. Originals kept as `*.orig-m5pro`. A `swift-bin` reinstall undoes it: rerun the patch (install-toolchain.sh's `install_darwin_tools`) | copy the `.orig-m5pro` files back |
| `~/Tools/omarchy-apple-dev/` | the project checkout | `rm -r` it |
| `~/xcode-apple-sdk-src/` (3.2 GB) | Route B: the SDK pieces of the Mac Studio's Xcode 27.2 (27B52) | `rm -r` it after the SDK is cached |
| `~/.swiftpm/swift-sdks/darwin.artifactbundle`, `~/.cache/xtool/` | the registered Darwin SDK (iOS 27.2, Simulator 27.2, macOS 27.2) and its cache | `swift sdk remove darwin`, `rm -r ~/.cache/xtool` |
| `~/.local/bin/xtool`, `~/.local/lib/omarchy-apple-dev/` | xtool (commit 7cc56c39) and the installer's helpers | `rm` them |
| `~/ios-dev/HelloOmarchy/` | the smoke-test app | `rm -r` it |

Fixed on the way: `~/.local/lib` was owned by root (created by an earlier root install on 2026-11-19); now rolo.

## Install (how it was done; the installer's own sudo steps replaced)

```sh
# root: system packages and Swift (the installer's `sudo pacman` and `yay` need a terminal)
OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -S --needed usbmuxd zip base-devel git libimobiledevice openssl poppler libheif inotify-tools rsync libxml2-legacy patchelf
# rolo: git clone https://aur.archlinux.org/swift-bin.git ~/aur/swift-bin && cd ~/aur/swift-bin && makepkg -f
pacman -U ~rolo/aur/swift-bin/swift-bin-6.4.3-1-aarch64.pkg.tar.xz   # then IgnorePkg = swift-bin
# Studio -> Mac: the Route B SDK pieces of /Applications/Xcode.app (list in install-toolchain.sh, step 5)
# rolo:
git clone https://github.com/joshuaswarren/omarchy-apple-dev ~/Tools/omarchy-apple-dev
SDK_SRC=~/xcode-apple-sdk-src PATH=/usr/lib/swift/usr/bin:/usr/bin:$PATH ~/Tools/omarchy-apple-dev/install-toolchain.sh --mode full --user-only
# root: the three .xcspec defaults (see the table)
```

## Next (owner, about 10 minutes)

`xtool auth` (an App Store Connect API key is more reliable than Apple ID + 2FA), plug the iPhone (Developer Mode on), trust,
`cd ~/ios-dev/HelloOmarchy && xtool dev` (build, sign, install, launch). Free account: trust the developer profile on the phone.
