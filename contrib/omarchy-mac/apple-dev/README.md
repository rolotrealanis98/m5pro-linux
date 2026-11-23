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

## 2026-11-23 (afternoon): a large CocoaPods workspace builds on the Mac (xtool 2.0 beta, CocoaPods, Interface Builder cache)

Goal: build a large iOS CocoaPods workspace (Objective-C++ audio units, Core Data, xibs/storyboards, asset catalogs, SwiftPM
binary dependencies) on the J716s. Result: it builds for iOS arm64 (clean 52 s on 18 cores, incremental 20 s). No signing, no
device install, nothing uploaded. All changes are in rolo's home; no root change, no pacman change, nothing under /etc.

| Path | What | Undo |
|---|---|---|
| `~/.local/share/gem/ruby/3.4.0/` | CocoaPods 1.17.0 (`gem install --user-install`) and the `erb` gem. Ruby 3.4 on Arch cannot `require 'erb'` without it (the distro package `ruby-erb` also fixes that; not installed) | `gem uninstall -a cocoapods erb`, or `rm -r ~/.local/share/gem` |
| `~/Tools/xtool2-src/` | xtool 2.0.0-beta.1 (tag, commit f1f42aa) with a 2-line patch: `@Flag var generatePreEncryptHashes = false` in `Sources/XToolSupport/EmulatedTools+Codesign.swift` (swift-build passes that flag for static/codeless frameworks; the beta rejects it). Built with `swift build -c release --product xtool` under Swift 6.4.3 in 3 min 48 s | `rm -r ~/Tools/xtool2-src` |
| `~/.local/bin/xtool2` | 2-line wrapper that execs the binary above. omarchy-apple-dev's `xtool` (1.x pin) is untouched | `rm` it |
| `~/.config/xtool/darwin.xtoolsdk/` (3.4 GB) | xtool 2's own slim Darwin SDK, built from `~/xcode-apple-sdk-src` (`xtool2 sdk install --slim`, 38 s), plus Linux stand-ins and shims in its `toolset/bin` (see below) | `rm -r ~/.config/xtool/darwin.xtoolsdk` |
| `~/Tools/<workspace>-linux/` | `setup-sdk.sh` (SDK + stand-ins + shims in one script), `build.sh`, `failed.py` (build-log reader) | `rm -r` it |
| `~/ibcache/` | the Interface Builder replay cache and its shim (see below) | `rm -r` it |
| `~/Tools/xtool-demo/` | xtool's own Xcode-project example (smoke test, builds in 4 s) | `rm -r` it |
| `~/<workspace>-linux/` (5.6 GB with build output) | the workspace and its build output | `rm -r` it |

**Hazard, already hit once:** `xtool2 sdk install` first *migrates* a pre-existing `~/.swiftpm/swift-sdks/darwin.artifactbundle` (the
one omarchy-apple-dev registers for xtool 1.x) into `~/.config/xtool/darwin.xtoolsdk` and then deletes it. That removed
omarchy's `darwin` SDK (`swift sdk list` came back empty). Restored by re-running its installer step:
`cd ~/Tools/omarchy-apple-dev && SDK_SRC=~/xcode-apple-sdk-src PATH=/usr/lib/swift/usr/bin:/usr/bin:$PATH ./install-toolchain.sh --mode full --user-only` (41 s,
from the cache in `~/.cache/xtool`). After that both coexist: xtool 1.x uses the `swift sdk` registry, xtool2 uses `~/.config/xtool/darwin.xtoolsdk`
(it only migrates when its own folder is missing). Never run `xtool2 sdk install` again while only the legacy SDK exists. `~/ios-dev/HelloOmarchy` builds again (4 s).

What `setup-sdk.sh` puts in `~/.config/xtool/darwin.xtoolsdk/toolset/bin/` (first on the build tasks' PATH, not on the system PATH):

- omarchy-apple-dev's `actool` (renamed `actool.real` behind a shim that answers `--print-asset-tag-combinations`, which swift-build 6.4 calls and the stand-in lacks), `momc` (with a 3-line fix: a non-numeric Integer default such as "NO" means 0), `xcstringstool`, and `ibtool` (the Linux stand-in cannot compile this workspace's xibs; it is `ibtool.real` behind the replay shim).
- `lipo` -> `/usr/bin/llvm-lipo` (LLVM 23; the Swift toolchain ships none), `ld` -> a wrapper that execs `ld64.lld` (swift-build links the stub for static frameworks with plain `clang`, which otherwise falls back to GNU ld), `bitcode_strip` -> xtool's tool emulator (the 2.0 beta SDK builder forgets it), no-op `sentry-cli` and `modules-verifier`.
- In the SDK folder: `Platforms/iPhoneOS.platform/Developer/Info.plist` gets `STRINGS_FILE_INPUT_ENCODING=utf-8`; the Swift back-deployment libraries (`libswiftCompatibility*.a`) are symlinked into `iPhoneOS27.2.sdk/usr/lib/swift/iphoneos/` **and** `.../usr/lib/swift/usr/lib/swift/iphoneos/`. The second path exists because swift-bin is rooted at `/usr/lib/swift`, so swift-build's `-L<toolchain>/usr/lib/swift/iphoneos` becomes that path under `-syslibroot`. A target below iOS 17 fails to link without them.

`~/ibcache`: the replay shim for Interface Builder. Apple's `ibtool` exists only on macOS; the Mac Studio compiles every xib and
storyboard once (7 s) and ships the outputs here. The shim (installed as `ibtool` in the folder above) looks each invocation up by
key = sha256(input file content + ibtool flags + mode) and falls back to the Linux stand-in on a miss (`IB_STRICT=1` makes a miss an error).
A full build had 94 hits and 0 misses (`~/ibcache/shim.log`). Refresh after xib changes: run `ib-cache-fill.py` on a Mac and copy `cache/` over.

Versions and timings (this Mac): Swift 6.4.3 (AUR) against an iOS 27.2 SDK from Xcode 27.2 (Swift 6.4.2): no errors from the skew.
`pod install` 47 s (first run, CDN) and byte-identical to a Mac's output. Clean build 52 s, no-op rebuild 13 s, one-line Swift change 20 s, all
`nice -n 10` on 18 cores. Build host filesystem is ext4 (case-sensitive): no include-case problems.
