# Troubleshooting

Start here, in this order:

```powershell
powershell -File LiteDroid\LiteDroid.ps1 -Diag       # what the machine can do
notepad C:\LiteDroid\logs\litedroid-<today>.log      # what actually happened
```

`-Diag` prints Windows build, architecture, CPU threads, RAM, free disk,
virtualization flags, feature states, whether the runtime is installed, whether
adb is reachable and the VM's current footprint. Nine out of ten problems are
visible there.

---

## Setup refused to run

**"CPU virtualization is disabled in BIOS/UEFI"**
Reboot into firmware setup and enable *Intel VT-x* / *Intel Virtualization
Technology* or *AMD-V / SVM*. On many laptops it is hidden until you disable
"Hyper-V" or enable "Virtual Machine Mode" there. `-Diag` shows
`firmware=False hypervisor=False` in that state.

**"Windows build is too old"**
Windows 10 needs 22H2 (19045.2311+). Older 19041/19042 builds need KB5014032 and
KB5022834 first. Windows 11 needs 22000.526+.

**"Less than 8 GB free"** — the runtime plus one app needs roughly 4–5 GB; setup
wants 8 GB so it does not fill your disk mid-extract.

**"The runtime is already installed with a different profile"**
Switch profiles on purpose: `Install LiteDroid.bat -Profile balanced -Replace`
(or `-Profile ultralight`). `-Replace` removes the old registration and re-registers
from a freshly extracted image.

---

## Setup stopped and said "reboot required"

Expected on a machine that never ran Hyper-V. Reboot, run
`Install LiteDroid.bat` again — downloading is skipped, everything resumes at
feature check.

---

## `Add-AppxPackage` / registration failures

**`0x80073CF3` — package dependency not found**
The desktop VCLibs runtime is missing. Setup pre-installs it, but if you skipped
that: `Add-AppxPackage https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx`
then re-run setup.

**`0x80073D01` / `0x80073CF9` — deployment blocked**
Usually a pending reboot, or Controlled Folder Access / antivirus holding the
extracted files. Reboot, then retry; if it persists, temporarily allow
`C:\LiteDroid\wsa` in your antivirus and re-run.

**"Cannot delete/move the runtime folder"**
`C:\LiteDroid\wsa` is a registered *unpackaged* app: Windows serves the binaries
straight from it. Moving or deleting it breaks the registration. Use
`-Replace` if you want a clean reinstall.

---

## The runtime is installed but LiteDroid says "asleep" or "adb never connected"

adb is what LiteDroid uses to install and inspect apps. It needs the developer
switch, which lives in `settings.json`:

```powershell
$p = "$env:LOCALAPPDATA\Packages\MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe\LocalState\settings.json"
Get-Content $p
```

`"debugging": { "localConnect": true }` must be there. If it is missing, re-run
`Install LiteDroid.bat` (it rewrites the file), or open **Windows Subsystem for
Android** from the Start menu → *Advanced settings* → *Developer mode* on.

Then verify by hand:

```powershell
C:\LiteDroid\tools\platform-tools\adb.exe -P 5038 connect 127.0.0.1:58526
C:\LiteDroid\tools\platform-tools\adb.exe -P 5038 devices
```

---

## An app crashes on launch, or shows a blank window

Most likely it hard-requires **Google Play Services**, which the `ultralight`
profile intentionally does not include. Reinstall with the balanced profile:

```
Install LiteDroid.bat -Profile balanced -Replace
```

YacineTV is not one of these: it only uses Play Services for ads/analytics, so on
the ultra-light profile it runs and the ads simply do not load.

Other app-level causes worth trying: *Settings → Render surface → native*
(some apps mis-measure at 720p), and installing with
`"GrantPermissions": true` (default) so runtime permission dialogs do not block
first-run screens.

---

## Graphics glitches, black window, or very slow rendering

- **Nvidia + hybrid graphics laptops**: WSA sometimes binds to the wrong GPU.
  Windows Settings → System → Display → Graphics → *Windows Subsystem for Android*
  → set the GPU explicitly (power-saving iGPU is usually the stable choice).
- **Intel HD 530 and older**: known to glitch or fail to start; there is no fix on
  the WSA side.
- Try *Settings → Render surface → 720p*: cutting the render surface is the
  cheapest big win on weak iGPUs.

---

## It is using more memory than promised

- Numbers in the window are real (`vmmemWSA` working set + per-app PSS from
  Android), not estimates. A single video app can legitimately hold 300–500 MB on
  its own.
- The VM only drops to 0 MB once **all** Android apps are closed. Click
  **Hibernate all** if you want that immediately.
- If RAM stays allocated with no apps open, something inside Android is still
  running: open Windows Subsystem for Android → *System* → set *Subsystem
  resources* to **As needed** (not *Continuous*).
- Lowering `MemoryMB` in Settings only takes effect at the next runtime boot.
- If a build ignores the budget in `settings.json` entirely (Setup prints
  *"settings.json has no memoryMB key yet"*), set it the official way: Start →
  **Windows Subsystem for Android** → *System* → *Memory and performance* →
  Custom. LiteDroid reads and displays whatever the runtime reports, so both paths
  end up in the same place.

---

## Another emulator / VM is in the way

Only one hypervisor-based Android runtime can hold the virtualization stack at a
time. Stop BlueStacks, MuMu, LDPlayer, Android Studio AVDs and heavy WSL2/VirtualBox
workloads, then start the app again.

---

## Uninstall

```powershell
# 1. remove the runtime registration
Get-AppxPackage MicrosoftCorporationII.WindowsSubsystemForAndroid | Remove-AppxPackage

# 2. remove the files, logs and settings
Remove-Item C:\LiteDroid -Recurse -Force
```

Optional: turn the two Windows features back off in *Turn Windows features on or
off* if nothing else on the machine needs them.
