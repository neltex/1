# LiteDroid

**The lightest way to run Android apps on Windows.** Android apps open in their own
normal Windows windows — taskbar, Alt-Tab, Start menu, desktop shortcuts — from a
runtime that can go all the way down to **0 MB when you are not using it**.

Sideload any `.apk` by dragging it onto the window.

---

## Quick start

1. Double-click **`LiteDroid/Install LiteDroid.bat`** (asks for administrator once).
   It downloads a stripped Android 13 image (~554 MB), registers it with Windows,
   tunes it down and installs any `.apk` it finds next to the folder
   (`YacineTV_____V3.2.apk` is already there).
2. If it says a reboot is required, reboot and run it again.
3. Double-click **`LiteDroid/Start LiteDroid.bat`**. That is your manager: app list,
   install, open, kill, uninstall, shortcuts, live memory numbers.

From then on you never need LiteDroid open: Android apps live in the Start menu like
any other Windows program. LiteDroid is just the control panel.

---

## Why this is the fastest option on Windows

An Android app on Windows can be hosted in roughly three ways. LiteDroid picks the
only one that does not pay a tax on every frame:

| Approach | Idle RAM | How an app looks | Notes |
|---|---|---|---|
| **LiteDroid (this)** | **~0 MB idle, ~0.7–0.9 GB with one app open** | Real Windows window (taskbar, Alt-Tab, snap) | Windows' own Hyper-V based runtime, de-Amazoned, de-Googled in the ultra-light profile |
| BlueStacks / MuMu / LDPlayer | ~1.5–2.5 GB always | App inside the emulator's own launcher window | Bundled store, ads, telemetry, background services |
| Android Studio AVD / QEMU + Android-x86 | 2–4 GB | Full Android desktop inside a window | Great for developers, heavy for one app |

Three things make the difference:

1. **It is a Windows subsystem, not a virtual PC.** There is no second desktop, no
   guest launcher, no display server of its own — each Android app is handed a real
   Win32 window by the host.
2. **No CPU translation for your app.** `YacineTV_____V3.2.apk` ships native
   `lib/x86_64` libraries, so on an x86-64 PC it runs at native speed. (Apps that
   only ship ARM code still run, through the ARM translation layer, just slower.)
3. **It is stripped.** The ultra-light profile removes the Amazon Appstore and
   Google Play Services entirely, switches off telemetry/print/setup helper
   packages, cuts the RAM budget and vCPU count, and turns off animations. The VM
   also shuts down completely when nothing is running, instead of squatting in the
   background all day.

---

## Using it

**Install apps**

- Drag one or more `.apk` files onto the LiteDroid window, or
- Drag them onto `Install APK.bat`, or
- `powershell -File LiteDroid\LiteDroid.ps1 -Apk "C:\path\app.apk"`, or
- Click *Install APK…* in the window.

Installs are streamed, permissions are granted up front (`-g`), and a single APK is
launched in its own window right after installing.

**Make an app feel permanent**

Select it → **Shortcut**. You get a desktop shortcut that behaves like any other
program: double-click, pin to taskbar, add to Start.

**Get memory back**

- Close the app windows — once the last app closes, Windows tears the Android VM
  down and you are back to 0 MB.
- **Hibernate all** force-stops every Android app immediately.
- *Settings* lets you raise/lower RAM (2–6 GB) and vCPU count; the changes apply at
  the next runtime boot.

**Command line**

```powershell
.\LiteDroid.ps1 -Apk app.apk     # install (and open) an APK
.\LiteDroid.ps1 -Tune            # re-apply the performance profile
.\LiteDroid.ps1 -Hibernate       # stop every Android app
.\LiteDroid.ps1 -Diag            # capability report: virtualization, features, adb, VM size
.\LiteDroid.ps1 -SelfTest        # unit tests for the engine (pure logic, no side effects)
```

---

## Requirements

| | |
|---|---|
| Windows | 11 (any build 22000+) — or Windows 10 22H2 build 19045.2311+ (19041.264+ works with the patched image) |
| CPU | x86-64 or ARM64 with virtualization enabled in BIOS/UEFI (VT-x / AMD-V) |
| RAM | 8 GB recommended (it will run on 6 GB: the VM gets 2 GB) |
| Disk | ~8 GB free on `C:` (NTFS), plus room for your apps |
| Windows features | *Virtual Machine Platform* + *Windows Hypervisor Platform* — Setup enables them for you |
| Admin | only for the one-time install; daily use needs none |

`LiteDroid.ps1 -Diag` tells you exactly which of these is missing on your machine
before you download anything.

---

## Reality check

- The Android runtime underneath is **Windows Subsystem for Android**, which
  Microsoft discontinued on 5 March 2025. LiteDroid installs the maintained
  community build ([WSABuilds](https://github.com/MustardChef/WSABuilds)), which is
  repackaged from Microsoft's signed binaries. It works, it is updated, but it is
  not a Microsoft-supported product. If Windows ever blocks it outright, no
  thin wrapper can fix that.
- The ultra-light profile has **no Google Play Services**. Simple apps (video,
  IPTV, utilities) are fine — YacineTV uses them only for ads/analytics, which
  simply fail quietly. If an app refuses to start without them, reinstall once with
  `Install LiteDroid.bat -Profile balanced -Replace` (adds ~200 MB, keeps Play
  Store + services, still no Amazon Appstore).
- Two Android runtimes cannot share the machine: if BlueStacks/MuMu/an AVD is
  running, stop it first. Same if you use Hyper-V/VirtualBox/WSL2 heavily under
  memory pressure.
- Phone-only apps that assume a touchscreen, SMS or a camera will be awkward.
  That is the app, not the runtime.

See `LiteDroid/docs/TROUBLESHOOTING.md` for the failure modes worth knowing, and
`LiteDroid/docs/HOW-IT-WORKS.md` for the internals.

## What is in the box

```
LiteDroid/
  Install LiteDroid.bat    one-time installer (self-elevating)
  Start LiteDroid.bat      opens the manage window
  Install APK.bat          drag APKs onto this to install them
  LiteDroid.ps1            entry point + CLI verbs
  Setup.ps1                download / register / tune pipeline
  lib/Core.ps1             engine: preflight, adb, WSA, apps, tuning
  lib/Ui.ps1               WinForms front-end
  config/default.json      reference for C:\LiteDroid\config.json
  docs/                    how it works, troubleshooting
```

Nothing to install, nothing to compile: it is PowerShell 5.1 + WinForms, both of
which already exist on any Windows 10/11 machine. Logs land in
`C:\LiteDroid\logs\`.
