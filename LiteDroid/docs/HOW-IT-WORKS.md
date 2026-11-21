# How LiteDroid works

LiteDroid is a thin, opinionated control layer over Windows' own Android runtime
(Windows Subsystem for Android, WSA) plus a hardening pass that removes everything
it does not need. This document explains each moving part so you can debug or
extend it.

## 1. What actually runs

```
Your APK
   |
   v
Android 13 (AOSP, x86-64)  <-- runs as a Hyper-V VM, no guest desktop
   |
   v
WsaClient.exe  -- gives every Android activity a real Win32 window
   |
   v
Windows: taskbar, Alt-Tab, Start menu, snap, notifications
```

There is no emulator launcher, no fake phone skin, no second display server.
`WsaClient.exe /launch wsa://<package>` is the host protocol that opens one app in
one window — LiteDroid uses exactly that, which is why an app opened through
LiteDroid and an app opened from the Start menu are the same object.

## 2. Install pipeline (`Setup.ps1`)

1. **Preflight** — `Get-LdPreflight` reads the Windows build from the registry,
   CPU architecture, `Win32_Processor.VirtualizationFirmwareEnabled`,
   `Win32_ComputerSystem.HypervisorPresent`, free disk, and (when elevated) the
   state of the two optional features. Hard blockers stop setup before any
   download.
2. **Features** — `VirtualMachinePlatform` and `HypervisorPlatform` are enabled
   with `Enable-WindowsOptionalFeature -NoRestart`. If Windows says a restart is
   needed, setup stops, tells you, and re-runs cleanly afterwards.
3. **Toolchain** — two small downloads: `7zr.exe` (600 KB standalone extractor,
   used only to unpack the image) and Google's `platform-tools` zip (for `adb`).
   Nothing is installed system-wide.
4. **Image selection** — the GitHub API is queried for the newest WSABuilds
   release matching *(OS, architecture, profile)*, filtering out Magisk builds and
   anything with the Amazon Appstore:

   | Profile | Asset | Why |
   |---|---|---|
   | `ultralight` | `…-NoGApps-NoAmazon.7z` (~554 MB) | smallest runtime, no Google services, no store |
   | `balanced` | `…-GApps-13.0-NoAmazon.7z` (~747 MB) | keeps Play Services + Play Store |

   If the API is unreachable, set `WsaAssetUrl` in `C:\LiteDroid\config.json` to a
   direct `.7z` link; setup will use it.
5. **Register** — the archive is extracted to `C:\LiteDroid\wsa` (this folder must
   stay, it *is* the installation) and registered with
   `Add-AppxPackage -Register …\AppxManifest.xml`. The desktop VCLibs runtime is
   installed first, because the manifest depends on it.
6. **Budget** — `C:\Users\<you>\AppData\Local\Packages\
   MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe\LocalState\
   settings.json` is merged (never overwritten) with:

   ```json
   {
     "memoryMB": 2560,
     "numberOfCores": 2,
     "gpuOptions": { "enableGPU": true },
     "debugging": { "localConnect": true }
   }
   ```

   `memoryMB` / `numberOfCores` / `enableGPU` are the VM budget, read at boot.
   `debugging.localConnect` is what allows `adb` in; without it LiteDroid could not
   install or inspect anything.
7. **First boot** — the runtime is woken by launching Android Settings, then
   `adb connect 127.0.0.1:58526` is polled for up to 150 s. If a first boot
   regenerated `settings.json` and lost the values, setup re-applies them and
   restarts once.

## 3. Daily use (`lib/Core.ps1`)

- **App list** — two sources, merged: `adb shell pm list packages -3` (truth) and
  the Start-menu `.lnk` files whose target is `WsaClient.exe` (friendly names, real
  icons from `LocalState\<package>.png`). The `.lnk` arguments contain
  `wsa://<package>`, which is how each shortcut is mapped back to a package.
- **Install** — `adb -s 127.0.0.1:58526 install -r -g <apk>`. The package list is
  diffed before/after to learn the package name of the APK just installed (no
  `aapt` needed), which is what lets a single dropped APK launch itself.
- **Memory** - `vmmemWSA`'s working set is the real footprint of the runtime;
  per-app numbers come from one `dumpsys meminfo` call parsed into
  package → PSS, refreshed every ~40 s in the background.
- **adb isolation** — LiteDroid runs its own adb server on **port 5038** and always
  targets `127.0.0.1:58526`. It will not disturb Android Studio, `scrcpy`,
  `bluestacks`, or any other tool using the default 5037.

## 4. The performance profile

Applied by `Invoke-LdTuning`:

| Tweak | Effect | Safe? |
|---|---|---|
| `window_animation_scale` / `transition_animation_scale` / `animator_duration_scale` = 0 | Removes 100–300 ms of animation from every screen transition | Yes, purely cosmetic |
| `wm size` / `wm density` (optional 720p) | Smaller render surface = less GPU/CPU per frame; noticeable on weak iGPUs | Yes, reversible (`native` resets) |
| `settings put global cached_apps_freezer enabled` | Background apps get frozen and hand RAM back instead of being re-created | Yes, Android 13 default-adjacent |
| Disabling 10 unused system packages (print spooler, print recommendation service, setup/telemetry helpers, global search) | Fewer resident processes | Yes, none is used by normal apps |
| VM teardown when idle | The single biggest win: 0 MB instead of ~1.5 GB | Yes, that is how WSA is designed |

Deliberately **not** done: disabling Defender, disabling Windows services, editing
the Android system partition, or anything requiring root. Those are the "tricks"
that make emulators fragile.

## 5. Files

```
C:\LiteDroid\
  config.json     your settings (edit freely, or use the Settings dialog)
  wsa\            the registered runtime - do not delete or move
  tools\          7zr.exe, platform-tools\adb.exe
  downloads\      the image archive (safe to delete after install)
  logs\           one log per day, same text the UI shows
```
