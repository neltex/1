<#
    LiteDroid - Core engine
    ------------------------
    No user interface lives in this file. Everything here can be called from the
    GUI (lib/Ui.ps1), from Setup.ps1, or straight from a console:

        . .\lib\Core.ps1
        Initialize-LiteDroid
        Get-LdPreflight | Format-List

    Target runtime: Windows PowerShell 5.1 (ships with Windows 10/11).
    Keep this file free of PowerShell 7-only syntax (no ??, no ?: ternary,
    no -AsHashtable) so it runs on a stock Windows install with zero downloads.
#>

$script:LD = @{
    Name      = 'LiteDroid'
    Version   = '1.0.0'
    Root      = 'C:\LiteDroid'
    AdbPort   = 5038
    WsaPort   = 58526
    WsaPfn    = 'MicrosoftCorporationII.WindowsSubsystemForAndroid_8wekyb3d8bbwe'
    WsaName   = 'MicrosoftCorporationII.WindowsSubsystemForAndroid'
    LogFile   = $null
    LogSink   = $null
    Config    = $null
    LogTail   = $null
}

# Android packages that are safe to switch off in every profile. They are either
# unused plumbing (print services, setup helpers) or telemetry. Anything that can
# break an app on purpose is NOT in this list.
$script:LDBloat = @(
    'com.google.android.printservice.recommendation',
    'com.android.printspooler',
    'com.android.bips',
    'com.google.android.apps.restore',
    'com.google.android.partnersetup',
    'com.google.android.onetimeinitializer',
    'com.google.android.feedback',
    'com.google.android.googlequicksearchbox',
    'com.android.bookmarkprovider',
    'com.android.traceur'
)

$script:LDDefaults = @{
    Profile             = 'ultralight'
    MemoryMB            = 0        # 0 = size it from host RAM
    Cores               = 0        # 0 = size it from host CPU
    EnableGpu           = $true
    DisableAnimations   = $true
    ScreenMode          = 'native' # native | 720p | 1080p
    DisableBloat        = $true
    GrantPermissions    = $true
    CachedAppsFreezer   = $true
    RestrictBackground  = $false
    AutoTuneOnLaunch    = $true
    AdbPort             = 5038
    WsaAssetUrl         = ''       # pinned fallback download, optional
    DownloadConnections = 8        # parallel connections for the 530 MB image
}

#region logging

function Write-LdLog {
    <#
        Central logger. Writes to the console, to %Root%\logs\litedroid-YYYYMMDD.log
        and to any sink registered by the GUI (so the window can show a live log).
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERR','STEP')][string]$Level = 'INFO'
    )

    $stamp = Get-Date -Format 'HH:mm:ss'
    $line  = '[{0}] {1,-4} {2}' -f $stamp, $Level, $Message

    switch ($Level) {
        'ERR'  { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'OK'   { Write-Host $line -ForegroundColor Green }
        'STEP' { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }

    if ($script:LD.LogFile) {
        try { Add-Content -LiteralPath $script:LD.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
    }

    if ($script:LD.LogSink) {
        try { & $script:LD.LogSink $line $Level } catch { }
    }
}

function Register-LdLogSink {
    param([scriptblock]$Sink)
    $script:LD.LogSink = $Sink
}

#endregion

#region bootstrap / config

function Initialize-LiteDroid {
    param([string]$Root = 'C:\LiteDroid')

    if ($Root) { $script:LD.Root = $Root }

    foreach ($sub in @('', 'logs', 'downloads', 'tools', 'wsa')) {
        $dir = $script:LD.Root
        if ($sub) { $dir = Join-Path $script:LD.Root $sub }
        if (-not (Test-Path -LiteralPath $dir)) {
            try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
        }
    }

    $script:LD.LogFile = Join-Path $script:LD.Root ('logs\litedroid-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

    $cfg = @{}
    foreach ($k in $script:LDDefaults.Keys) { $cfg[$k] = $script:LDDefaults[$k] }

    $cfgFile = Join-Path $script:LD.Root 'config.json'
    if (-not (Test-Path -LiteralPath $cfgFile)) {
        try {
            $json = $cfg | ConvertTo-Json -Depth 8
            [System.IO.File]::WriteAllText($cfgFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    if (Test-Path -LiteralPath $cfgFile) {
        try {
            $raw = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8
            if ($raw -and $raw.Trim().Length -gt 0) {
                $parsed = $raw | ConvertFrom-Json
                foreach ($p in $parsed.PSObject.Properties) {
                    if ($cfg.ContainsKey($p.Name)) { $cfg[$p.Name] = $p.Value }
                }
            }
        } catch {
            Write-LdLog "config.json unreadable, using defaults ($($_.Exception.Message))" WARN
        }
    }

    $script:LD.AdbPort = [int]$cfg['AdbPort']
    $script:LD.Config = $cfg
    return $cfg
}

function Get-LdConfig {
    if (-not $script:LD.Config) { Initialize-LiteDroid | Out-Null }
    return $script:LD.Config
}

function Save-LdConfig {
    param([hashtable]$Config)
    if (-not $Config) { $Config = Get-LdConfig }
    $path = Join-Path $script:LD.Root 'config.json'
    $json = $Config | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:LD.Config = $Config
}

#endregion

#region pure helpers (deterministic, easy to self-test)

function Format-LdSize {
    param([double]$Megabytes)
    if ($Megabytes -le 0) { return '0 MB' }
    if ($Megabytes -lt 1024) { return ('{0:0} MB' -f $Megabytes) }
    return ('{0:0.0} GB' -f ($Megabytes / 1024))
}

function Format-LdKBytes {
    param([double]$Kilobytes)
    return (Format-LdSize ($Kilobytes / 1024))
}

function Resolve-LdMemoryMb {
    <#
        How much RAM to hand the Android VM. Deliberately conservative: the whole
        point of LiteDroid is to leave the rest of Windows alone.
    #>
    param([double]$HostRamGb)

    if ($HostRamGb -lt 7)    { return 2048 }
    if ($HostRamGb -lt 10)   { return 2560 }
    if ($HostRamGb -lt 14)   { return 3072 }
    if ($HostRamGb -lt 20)   { return 4096 }
    return 5120
}

function Resolve-LdCores {
    <#
        vCPUs for the VM: half of the logical cores, clamped to 2..4.
        More than 4 buys nothing for phone apps and costs scheduling latency.
    #>
    param([int]$LogicalCores)

    $half = [int][math]::Floor($LogicalCores / 2)
    if ($half -lt 2) { return 2 }
    if ($half -gt 4) { return 4 }
    return $half
}

function ConvertFrom-LdMeminfo {
    <#
        Parses `adb shell dumpsys meminfo` text into a name -> KB map.
        Input lines look like:  "  182,331K: com.yacine.tv (pid 4321)"
    #>
    param([string[]]$Lines)

    $map = @{}
    foreach ($l in $Lines) {
        $m = [regex]::Match($l, '^\s*([\d,]+)K:\s+(\S+)\s+\(pid\s+\d+')
        if ($m.Success) {
            $kb = [double]($m.Groups[1].Value -replace ',', '')
            $name = $m.Groups[2].Value
            if (-not $map.ContainsKey($name)) { $map[$name] = $kb }
        }
    }
    return $map
}

function Get-LdApkCandidates {
    <#
        Finds *.apk files sitting next to the app (or one folder up, where people
        usually leave their downloads). Used by the first-run wizard.
    #>
    param([string[]]$Directories, [int]$Max = 25)

    $found = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($d in $Directories) {
        if (-not $d) { continue }
        if (-not (Test-Path -LiteralPath $d)) { continue }
        try {
            $files = Get-ChildItem -LiteralPath $d -Filter '*.apk' -File -ErrorAction Stop |
                     Sort-Object Length -Descending
        } catch { continue }
        foreach ($f in $files) {
            $key = $f.FullName.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$found.Add([pscustomobject]@{
                Path    = $f.FullName
                Name    = $f.BaseName
                SizeMB  = [math]::Round($f.Length / 1MB, 1)
            })
            if ($found.Count -ge $Max) { return $found }
        }
    }
    return $found
}

#endregion

#region hosts / preflight

function Test-LdAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-LdPreflight {
    <#
        Everything LiteDroid needs to know about this machine, in one object.
        Never throws: unknown values come back as $null with a note in .Notes.
    #>
    $r = [pscustomobject]@{
        IsWindows       = $true
        IsAdmin         = $false
        Build           = 0
        Edition         = ''
        IsWin11         = $false
        Arch            = ''
        LogicalCores    = 0
        HostRamGb       = 0
        FreeDiskGb      = 0
        CpuName         = ''
        HypervisorOn    = $null
        VirtFirmware    = $null
        FeatureVmp      = 'Unknown'
        FeatureWhp      = 'Unknown'
        WsaInstalled    = $false
        WsaLocation     = ''
        WsaPackageFull  = ''
        Blockers        = @()
        Warnings        = @()
    }

    if (-not ($env:OS -eq 'Windows_NT')) {
        $r.IsWindows = $false
        $r.Blockers += 'LiteDroid only runs on Windows.'
        return $r
    }

    $r.IsAdmin = Test-LdAdmin
    $r.Arch = $env:PROCESSOR_ARCHITECTURE

    try {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $r.Build = [int]$cv.CurrentBuildNumber
        if ($cv.PSObject.Properties.Name -contains 'DisplayVersion') { $r.Edition = [string]$cv.DisplayVersion }
    } catch {
        $r.Build = [Environment]::OSVersion.Version.Build
    }
    $r.IsWin11 = ($r.Build -ge 22000)

    try { $r.LogicalCores = [Environment]::ProcessorCount } catch { $r.LogicalCores = 0 }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $r.HostRamGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        if ($null -ne $cs.HypervisorPresent) { $r.HypervisorOn = [bool]$cs.HypervisorPresent }
    } catch { }

    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $r.CpuName = [string]$cpu.Name
        if ($null -ne $cpu.VirtualizationFirmwareEnabled) {
            $r.VirtFirmware = [bool]$cpu.VirtualizationFirmwareEnabled
        }
    } catch { }

    try {
        $d = Get-PSDrive -Name ($env:SystemDrive.Substring(0,1)) -ErrorAction Stop
        $r.FreeDiskGb = [math]::Round($d.Free / 1GB, 1)
    } catch { }

    if ($r.IsAdmin) {
        foreach ($feat in @('VirtualMachinePlatform', 'HypervisorPlatform')) {
            $state = 'Unknown'
            try {
                $f = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction Stop
                $state = [string]$f.State
            } catch { }
            if ($feat -eq 'VirtualMachinePlatform') { $r.FeatureVmp = $state }
            else { $r.FeatureWhp = $state }
        }
    }

    try {
        $pkg = Get-AppxPackage -Name $script:LD.WsaName -ErrorAction Stop | Select-Object -First 1
        if ($pkg) {
            $r.WsaInstalled = $true
            $r.WsaLocation = [string]$pkg.InstallLocation
            $r.WsaPackageFull = [string]$pkg.PackageFullName
        }
    } catch { }

    # --- blockers / warnings -------------------------------------------------
    if ($r.Arch -ne 'AMD64' -and $r.Arch -ne 'ARM64') {
        $r.Blockers += "Unsupported CPU architecture: $($r.Arch). x64 or ARM64 is required."
    }
    # Windows 10 build map: 19041 = 2004/20H2, 19043 = 21H1, 19044 = 21H2,
    # 19045 = 22H2. The patched Windows 10 image supports 19041.264 and newer,
    # so only pre-20H1 builds are a real blocker; 21H2 is a supported-but-older
    # path that wants two cumulative updates first.
    if ($r.IsWin11 -eq $false -and $r.Build -lt 19041) {
        $r.Blockers += ("Windows build {0} is too old (2004/19041 is the minimum). Run Windows Update, or install the 22H2 enablement package (KB5015684)." -f $r.Build)
    } elseif ($r.IsWin11 -eq $false -and $r.Build -lt 19045) {
        $r.Warnings += ("Windows 10 build {0} is older than 22H2 (19045). LiteDroid's patched Windows 10 image supports 19041+, so this usually works, but install KB5014032 then KB5022834 (or simply let Windows Update finish) for the best chance." -f $r.Build)
    }
    if ($r.VirtFirmware -eq $false -and $r.HypervisorOn -eq $false) {
        $r.Blockers += 'CPU virtualization is disabled in BIOS/UEFI. Enable VT-x (Intel) or SVM/AMD-V (AMD), then reboot.'
    }
    if ($r.HostRamGb -gt 0 -and $r.HostRamGb -lt 7) {
        $r.Warnings += ("Only {0} GB of RAM detected. LiteDroid will use 2 GB for Android; expect the rest of Windows to be tight." -f $r.HostRamGb)
    }
    if ($r.FreeDiskGb -gt 0 -and $r.FreeDiskGb -lt 8) {
        $r.Blockers += ("{0} GB free on {1}: at least 8 GB is needed for the runtime plus apps." -f $r.FreeDiskGb, $env:SystemDrive)
    }
    if ($r.IsAdmin -and $r.FeatureVmp -eq 'Disabled') {
        $r.Warnings += 'Windows feature "Virtual Machine Platform" is off - Setup will enable it (needs a reboot).'
    }
    if ($r.IsAdmin -and $r.FeatureWhp -eq 'Disabled') {
        $r.Warnings += 'Windows feature "Windows Hypervisor Platform" is off - Setup will enable it (needs a reboot).'
    }
    return $r
}

#endregion

#region adb

function Get-LdAdbExe {
    if ($script:LD.AdbExe -and (Test-Path -LiteralPath $script:LD.AdbExe)) { return $script:LD.AdbExe }
    $candidates = @(
        (Join-Path $script:LD.Root 'tools\platform-tools\adb.exe')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { $script:LD.AdbExe = $c; return $c }
    }
    return $null
}

function Invoke-LdAdb {
    <#
        Runs adb on LiteDroid's own server port (5038 by default) so we never
        fight with Android Studio / scrcpy / BlueStacks over port 5037.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSec = 60,
        [switch]$AllowFail,
        [switch]$Quiet
    )

    $adb = Get-LdAdbExe
    if (-not $adb) {
        if ($AllowFail) { return [pscustomobject]@{ ExitCode = -1; Text = 'adb not installed' } }
        throw 'adb.exe was not found. Run Setup first.'
    }

    $full = @('-P', [string]$script:LD.AdbPort) + $Arguments

    # NOTE: ProcessStartInfo.ArgumentList does not exist on .NET Framework, so the
    # command line is quoted by hand. adb parses with the standard CRT rules, for
    # which wrapping an argument that contains spaces in double quotes is enough.
    $quoted = New-Object System.Collections.ArrayList
    foreach ($a in $full) {
        $s = [string]$a
        if ($s.Length -eq 0) {
            [void]$quoted.Add('""')
        } elseif ($s -match '[\s"]') {
            [void]$quoted.Add('"' + ($s -replace '"', '\"') + '"')
        } else {
            [void]$quoted.Add($s)
        }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $adb
    $psi.Arguments = ($quoted -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    # Read asynchronously so a big dump (dumpsys, install progress) cannot
    # deadlock on a full pipe buffer while we wait for the process to exit.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        if ($AllowFail) { return [pscustomobject]@{ ExitCode = -2; Text = 'timeout' } }
        throw "adb timed out after $TimeoutSec seconds: adb $($Arguments -join ' ')"
    }
    $code = $proc.ExitCode
    $stdout = ''
    $stderr = ''
    try { $stdout = $outTask.GetAwaiter().GetResult() } catch { }
    try { $stderr = $errTask.GetAwaiter().GetResult() } catch { }
    $text = (($stdout + "`n" + $stderr) -replace "`r", '').Trim()

    if (-not $Quiet -and $text) {
        # adb is chatty; keep the log useful but not a wall of text
        $short = $text
        if ($short.Length -gt 400) { $short = $short.Substring(0, 400) + '...' }
        Write-LdLog ("adb $($Arguments[0]): $short") INFO
    }

    if ($code -ne 0 -and -not $AllowFail) {
        throw ("adb failed (exit {0}): {1}" -f $code, $text)
    }

    return [pscustomobject]@{ ExitCode = $code; Text = $text }
}

function Test-LdAdbDevice {
    $res = Invoke-LdAdb -Arguments @('devices') -AllowFail -Quiet
    if (-not $res) { return $false }
    $target = '127.0.0.1:' + $script:LD.WsaPort
    foreach ($l in ($res.Text -split "`n")) {
        if ($l -match [regex]::Escape($target) -and $l -match '\sdevice\s*$') { return $true }
    }
    return $false
}

function Test-LdWsaPortExcluded {
    # Windows/Hyper-V may reserve a range containing WSA's fixed adb port.
    # Never remove reservations automatically: doing so could break other VMs.
    try {
        $ranges = & netsh.exe int ipv4 show excludedportrange protocol=tcp 2>$null
        foreach ($line in $ranges) {
            if ($line -match '^\s*(\d+)\s+(\d+)\s*(?:\*.*)?$') {
                if ($script:LD.WsaPort -ge [int]$Matches[1] -and $script:LD.WsaPort -le [int]$Matches[2]) {
                    return $true
                }
            }
        }
    } catch { }
    return $false
}

function Connect-LdAdb {
    param([int]$TimeoutSec = 90)

    $target = '127.0.0.1:' + $script:LD.WsaPort
    if (-not (Get-LdAdbExe)) {
        Write-LdLog 'adb.exe is missing. Run START HERE.bat to restore Android platform-tools; waiting will not help.' ERR
        return $false
    }
    if (Test-LdWsaPortExcluded) {
        Write-LdLog 'Windows reserves TCP port 58526 for another service/Hyper-V range; WSA may be unable to open adb. Do not remove Windows port reservations blindly.' WARN
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-LdLog "Waiting for the Android runtime to accept adb on $target ..." STEP

    while ((Get-Date) -lt $deadline) {
        Invoke-LdAdb -Arguments @('connect', $target) -AllowFail -Quiet | Out-Null
        Start-Sleep -Milliseconds 1500
        if (Test-LdAdbDevice) {
            Write-LdLog 'adb connected.' OK
            return $true
        }
    }
    Write-LdLog 'adb did not connect. This does not mean the APK is bad. Check whether Android itself opened and whether the port-reservation warning appeared above.' WARN
    return $false
}

#endregion

#region WSA lifecycle

function Get-LdWsaPackage {
    try {
        return (Get-AppxPackage -Name $script:LD.WsaName -ErrorAction Stop | Select-Object -First 1)
    } catch { return $null }
}

function Get-LdWsaClientPath {
    $pkg = Get-LdWsaPackage
    if (-not $pkg) { return $null }
    $p = Join-Path $pkg.InstallLocation 'WsaClient\WsaClient.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    # fall back to a recursive search (layout differs between builds)
    try {
        $hit = Get-ChildItem -LiteralPath $pkg.InstallLocation -Filter 'WsaClient.exe' -Recurse -File -ErrorAction Stop |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    } catch { }
    return $null
}

function Get-LdWsaSettingsPath {
    return (Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalState\settings.json" -f $script:LD.WsaPfn))
}

function Get-LdWsaSettings {
    $path = Get-LdWsaSettingsPath
    $out = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $out }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.Trim()) { return $out }
        $parsed = $raw | ConvertFrom-Json
        foreach ($p in $parsed.PSObject.Properties) { $out[$p.Name] = $p.Value }
    } catch {
        Write-LdLog "Could not parse WSA settings.json: $($_.Exception.Message)" WARN
    }
    return $out
}

function Set-LdWsaSettings {
    <#
        Merges values into the WSA settings file (never replaces unknown keys).
        The file is only read by the VM at boot, so changes take effect on the
        next start of the subsystem.
    #>
    param([Parameter(Mandatory)][hashtable]$Values)

    $path = Get-LdWsaSettingsPath
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $obj = Get-LdWsaSettings
    foreach ($k in $Values.Keys) { $obj[$k] = $Values[$k] }

    $json = $obj | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-LdLog ("settings.json updated: " + (($Values.Keys | Sort-Object) -join ', ')) OK
}

function Get-LdMissingWsaFiles {
    # Only the image's own top-level native DLLs are mirrored beside the EXE.
    # Do not guess system DLL names or download standalone DLLs.
    $pkg = Get-LdWsaPackage
    $client = Get-LdWsaClientPath
    if (-not $pkg -or -not $client) { return @('WsaClient.exe') }
    $dir = Split-Path -Parent $client
    $missing = New-Object System.Collections.ArrayList
    foreach ($name in @('gfxstream_backend.dll', 'WSACodecs.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $name))) { [void]$missing.Add($name) }
    }
    foreach ($dll in @(Get-ChildItem -LiteralPath $pkg.InstallLocation -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $dll.Name)) -and -not $missing.Contains($dll.Name)) {
            [void]$missing.Add($dll.Name)
        }
    }
    return $missing.ToArray()
}

function Start-LdWsa {
    <#
        Boots the Android subsystem by asking it to open Android Settings, which
        is the cheapest reliable way to wake the VM without a user app.
    #>
    $client = Get-LdWsaClientPath
    if (-not $client) {
        Write-LdLog 'Android runtime is not installed yet.' ERR
        return $false
    }
    $missing = @(Get-LdMissingWsaFiles)
    if ($missing.Count -gt 0) {
        Write-LdLog ('Android cannot start; missing runtime files: ' + ($missing -join ', ') + '. Run START HERE.bat from the updated ZIP to repair them.') ERR
        return $false
    }
    Write-LdLog 'Starting Android runtime ...' STEP
    try {
        Start-Process -FilePath $client -ArgumentList '/launch wsa://com.android.settings' -ErrorAction Stop | Out-Null
    } catch {
        Write-LdLog "Could not start runtime: $($_.Exception.Message)" ERR
        return $false
    }
    return $true
}

function Stop-LdWsa {
    <#
        Best effort shutdown: stop every Android app, then stop the host client
        processes. The VM itself is torn down by Windows once nothing runs.
    #>
    param([switch]$Force)

    if (Test-LdAdbDevice) {
        Invoke-LdAdb -Arguments @('shell', 'am', 'kill-all') -AllowFail -Quiet | Out-Null
    }
    $svc = Get-Service -Name 'WsaService' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        try { Stop-Service -Name 'WsaService' -Force -ErrorAction Stop; Write-LdLog 'WsaService stopped.' INFO } catch { }
    }
    if ($Force) {
        foreach ($n in @('WsaClient','WsaSettings')) {
            Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
                try { $_.Kill() } catch { }
            }
        }
    }
    Start-Sleep -Milliseconds 800
}

function Get-LdVmProcess {
    foreach ($n in @('vmmemWSA', 'vmmem')) {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p) { return $p }
    }
    return $null
}

#endregion

#region apps

function Get-LdInstalledApps {
    <#
        Authoritative list of installed Android apps plus, when available, the
        Start Menu shortcut Windows created for each one (that shortcut is what
        makes an Android app feel native: taskbar, Start, Alt-Tab).
    #>
    param([switch]$NoAdb)

    $apps = @{}

    if (-not $NoAdb -and (Test-LdAdbDevice)) {
        $res = Invoke-LdAdb -Arguments @('shell', 'pm', 'list', 'packages', '-3') -AllowFail -Quiet
        if ($res -and $res.ExitCode -eq 0) {
            foreach ($line in ($res.Text -split "`n")) {
                $t = $line.Trim()
                if ($t -like 'package:*') {
                    $pkg = $t.Substring(8).Trim()
                    if ($pkg) {
                        if (-not $apps.ContainsKey($pkg)) {
                            $apps[$pkg] = [pscustomobject]@{
                                Package  = $pkg
                                Label    = $pkg
                                Shortcut = ''
                                IconPath = ''
                                MemoryKb = 0
                            }
                        }
                        $apps[$pkg].Label = $pkg
                    }
                }
            }
        }
    }

    # Start Menu shortcuts -> friendly labels, launch args and icons
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { }
    $menuDirs = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    )
    if ($shell) {
        foreach ($dir in $menuDirs) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            try {
                $links = Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -Recurse -File -ErrorAction Stop
            } catch { continue }
            foreach ($lnk in $links) {
                try { $sc = $shell.CreateShortcut($lnk.FullName) } catch { continue }
                if (-not $sc.TargetPath) { continue }
                if ($sc.TargetPath -notlike '*WsaClient.exe') { continue }

                $pkg = ''
                if ($sc.Arguments) {
                    $m = [regex]::Match($sc.Arguments, 'wsa://([A-Za-z0-9_\.]+)')
                    if ($m.Success) { $pkg = $m.Groups[1].Value }
                }
                if (-not $pkg) { continue }
                if ($pkg -eq 'com.android.settings') { continue }

                if (-not $apps.ContainsKey($pkg)) {
                    $apps[$pkg] = [pscustomobject]@{
                        Package  = $pkg
                        Label    = $pkg
                        Shortcut = $lnk.FullName
                        IconPath = ''
                        MemoryKb = 0
                    }
                }
                $apps[$pkg].Label = $lnk.BaseName
                $apps[$pkg].Shortcut = $lnk.FullName
                # Only trust real image files here. WSA often stores an EXE+index
                # icon location, and loading an EXE as an image would fail; in that
                # case the LocalState PNG pass below finds the real icon.
                if ($sc.IconLocation) {
                    $iconFile = ($sc.IconLocation -split ',')[0]
                    if ($iconFile -and $iconFile -match '\.png$' -and (Test-Path -LiteralPath $iconFile)) {
                        $apps[$pkg].IconPath = $iconFile
                    }
                }
            }
        }
    }

    # WSA caches a PNG per app in LocalState - much nicer than the generic icon
    $localState = Join-Path $env:LOCALAPPDATA ("Packages\{0}\LocalState" -f $script:LD.WsaPfn)
    if (Test-Path -LiteralPath $localState) {
        foreach ($pkg in @($apps.Keys)) {
            if ($apps[$pkg].IconPath) { continue }
            $direct = Join-Path $localState ($pkg + '.png')
            if (Test-Path -LiteralPath $direct) { $apps[$pkg].IconPath = $direct; continue }
            try {
                $hit = Get-ChildItem -LiteralPath $localState -Filter ($pkg + '*.png') -File -ErrorAction SilentlyContinue |
                       Select-Object -First 1
                if ($hit) { $apps[$pkg].IconPath = $hit.FullName }
            } catch { }
        }
    }

    return @($apps.Values | Sort-Object Label)
}

function Update-LdAppMemory {
    <#
        Fills .MemoryKb for the given app objects using one dumpsys call.
    #>
    param([object[]]$Apps)

    if (-not $Apps -or $Apps.Count -eq 0) { return $Apps }
    if (-not (Test-LdAdbDevice)) { return $Apps }

    $res = Invoke-LdAdb -Arguments @('shell', 'dumpsys', 'meminfo') -AllowFail -Quiet -TimeoutSec 40
    if (-not $res -or $res.ExitCode -ne 0) { return $Apps }

    $map = ConvertFrom-LdMeminfo -Lines ($res.Text -split "`n")
    foreach ($a in $Apps) {
        $kb = 0
        foreach ($k in $map.Keys) {
            if ($k -eq $a.Package -or $k -like ($a.Package + ':*')) {
                $kb = $kb + $map[$k]
            }
        }
        $a.MemoryKb = $kb
    }
    return $Apps
}

function Install-LdApk {
    <#
        Installs one or more APKs. Returns the list of newly appeared package
        names, so the GUI can launch the app immediately (sideload -> open).
    #>
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [switch]$Launch
    )

    if (-not $script:LD.Config) { Initialize-LiteDroid | Out-Null }
    $cfg = Get-LdConfig

    $installed = @()
    if (-not (Start-LdVmAndAdb)) { throw 'The Android runtime is not reachable.' }

    foreach ($apk in $Path) {
        if (-not (Test-Path -LiteralPath $apk)) {
            Write-LdLog "APK not found: $apk" ERR
            continue
        }
        $before = @(Get-LdThirdPartyPackages)
        $sizeMb = [math]::Round((Get-Item -LiteralPath $apk).Length / 1MB, 1)
        Write-LdLog ("Installing {0} ({1} MB) ..." -f (Split-Path -Leaf $apk), $sizeMb) STEP

        $adbArgs = @('-s', ('127.0.0.1:' + $script:LD.WsaPort), 'install', '-r')
        if ($cfg['GrantPermissions']) { $adbArgs += '-g' }
        $adbArgs += $apk

        $res = Invoke-LdAdb -Arguments $adbArgs -TimeoutSec 300 -AllowFail
        if (-not $res) { continue }
        if ($res.Text -notmatch 'Success') {
            Write-LdLog ("Install failed: {0}" -f $res.Text) ERR
            continue
        }

        Start-Sleep -Milliseconds 700
        $after = @(Get-LdThirdPartyPackages)
        $new = @($after | Where-Object { $before -notcontains $_ })
        Write-LdLog ("Installed: {0}" -f (Split-Path -Leaf $apk)) OK

        foreach ($p in $new) {
            $installed += $p
            if ($Launch) {
                Launch-LdApp -Package $p
            }
        }
        if ($new.Count -eq 0) {
            Write-LdLog 'Package was already installed (updated in place).' INFO
        }
    }
    return $installed
}

function Get-LdThirdPartyPackages {
    $res = Invoke-LdAdb -Arguments @('shell', 'pm', 'list', 'packages', '-3') -AllowFail -Quiet
    if (-not $res -or $res.ExitCode -ne 0) { return @() }
    $out = New-Object System.Collections.ArrayList
    foreach ($line in ($res.Text -split "`n")) {
        $t = $line.Trim()
        if ($t -like 'package:*') { [void]$out.Add($t.Substring(8).Trim()) }
    }
    return $out.ToArray()
}

function Launch-LdApp {
    <#
        Opens an Android app in its own Windows window (this is the wsa:// host
        protocol; the app then shows up in Alt-Tab and the taskbar like any EXE).
    #>
    param([Parameter(Mandatory)][string]$Package)

    $client = Get-LdWsaClientPath
    if (-not $client) { throw 'Android runtime is not installed.' }
    try {
        Start-Process -FilePath $client -ArgumentList ('/launch wsa://' + $Package) -ErrorAction Stop | Out-Null
        Write-LdLog "Launched $Package" OK
        return $true
    } catch {
        Write-LdLog "Launch failed: $($_.Exception.Message)" ERR
        return $false
    }
}

function Stop-LdApp {
    param([Parameter(Mandatory)][string]$Package)
    Invoke-LdAdb -Arguments @('shell', 'am', 'force-stop', $Package) -AllowFail -Quiet | Out-Null
    Write-LdLog "Stopped $Package" INFO
}

function Uninstall-LdApp {
    param([Parameter(Mandatory)][string]$Package)
    $res = Invoke-LdAdb -Arguments @('shell', 'pm', 'uninstall', '--user', '0', $Package) -AllowFail
    if ($res -and $res.Text -match 'Success') {
        Write-LdLog "Uninstalled $Package" OK
        return $true
    }
    Write-LdLog ("Uninstall returned: " + $(if ($res) { $res.Text } else { 'no response' })) WARN
    return $false
}

function Stop-LdAllApps {
    if (-not (Test-LdAdbDevice)) { return }
    Invoke-LdAdb -Arguments @('shell', 'am', 'kill-all') -AllowFail -Quiet | Out-Null
    $pkgs = Get-LdThirdPartyPackages
    foreach ($p in $pkgs) {
        Invoke-LdAdb -Arguments @('shell', 'am', 'force-stop', $p) -AllowFail -Quiet | Out-Null
    }
    Write-LdLog ("Hibernated {0} app(s)." -f $pkgs.Count) OK
}

function Start-LdVmAndAdb {
    param([int]$TimeoutSec = 100)

    if (Test-LdAdbDevice) { return $true }
    if (-not (Get-LdWsaPackage)) { return $false }
    if (-not (Start-LdWsa)) { return $false }
    return (Connect-LdAdb -TimeoutSec $TimeoutSec)
}

function Add-LdDesktopShortcut {
    param([Parameter(Mandatory)][string]$Package, [string]$Label)

    $client = Get-LdWsaClientPath
    if (-not $client) { throw 'Android runtime is not installed.' }
    if (-not $Label) { $Label = $Package }
    $safe = ($Label -replace '[\\/:*?"<>|]', '_')
    $desktop = [Environment]::GetFolderPath('Desktop')
    $path = Join-Path $desktop ($safe + '.lnk')
    try {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($path)
        $sc.TargetPath = $client
        $sc.Arguments = '/launch wsa://' + $Package
        $sc.Description = "$Label (Android, via LiteDroid)"
        $sc.Save()
        Write-LdLog "Desktop shortcut created: $safe" OK
        return $path
    } catch {
        Write-LdLog "Shortcut failed: $($_.Exception.Message)" ERR
        return $null
    }
}

#endregion

#region tuning

function Get-LdMemoryReport {
    <#
        Live numbers for the UI: host RAM, VM footprint, and per-app PSS.
    #>
    $vm = Get-LdVmProcess
    $vmMb = 0
    if ($vm) { $vmMb = [math]::Round($vm.WorkingSet64 / 1MB, 0) }

    $freeMb = 0
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $freeMb = [math]::Round($os.FreePhysicalMemory / 1024, 0)
    } catch { }

    $running = 0
    if (Test-LdAdbDevice) {
        $res = Invoke-LdAdb -Arguments @('shell', 'dumpsys', 'meminfo') -AllowFail -Quiet -TimeoutSec 30
        if ($res -and $res.ExitCode -eq 0) {
            $map = ConvertFrom-LdMeminfo -Lines ($res.Text -split "`n")
            foreach ($k in $map.Keys) {
                if ($map[$k] -gt 20000) { $running = $running + 1 }
            }
        }
    }

    return [pscustomobject]@{
        VmMb      = $vmMb
        HostFreeMb = $freeMb
        Running   = $running
        VmAlive   = ($null -ne $vm)
    }
}

function Invoke-LdTuning {
    <#
        Applies the performance profile inside Android. Every step is tolerant of
        failure: a tweak that a particular build does not support is skipped.
        Returns a list of "what changed" strings for the UI.
    #>
    param([hashtable]$Options)

    $cfg = Get-LdConfig
    if (-not $Options) {
        $Options = @{
            DisableAnimations = $cfg['DisableAnimations']
            ScreenMode        = $cfg['ScreenMode']
            DisableBloat      = $cfg['DisableBloat']
            CachedAppsFreezer = $cfg['CachedAppsFreezer']
        }
    }

    $done = New-Object System.Collections.ArrayList

    if (-not (Start-LdVmAndAdb)) {
        Write-LdLog 'Cannot tune: runtime is not reachable.' ERR
        return $done
    }

    if ($Options['DisableAnimations']) {
        foreach ($k in @('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale')) {
            $r = Invoke-LdAdb -Arguments @('shell', 'settings', 'put', 'global', $k, '0') -AllowFail -Quiet
            if ($r -and $r.ExitCode -eq 0) { }
        }
        [void]$done.Add('Animations off (snappier UI, less GPU work)')
    }

    $mode = [string]$Options['ScreenMode']
    if ($mode -eq '720p') {
        [void](Invoke-LdAdb -Arguments @('shell', 'wm', 'size', '1280x720') -AllowFail -Quiet)
        [void](Invoke-LdAdb -Arguments @('shell', 'wm', 'density', '240') -AllowFail -Quiet)
        [void]$done.Add('Render surface reduced to 1280x720')
    } elseif ($mode -eq '1080p') {
        [void](Invoke-LdAdb -Arguments @('shell', 'wm', 'size', '1920x1080') -AllowFail -Quiet)
        [void](Invoke-LdAdb -Arguments @('shell', 'wm', 'density', '320') -AllowFail -Quiet)
        [void]$done.Add('Render surface set to 1920x1080')
    } elseif ($mode -eq 'native') {
        [void](Invoke-LdAdb -Arguments @('shell', 'wm', 'size', 'reset') -AllowFail -Quiet)
        [void](Invoke-LdAdb -Arguments @('shell', 'wm', 'density', 'reset') -AllowFail -Quiet)
        [void]$done.Add('Render surface reset')
    }

    if ($Options['CachedAppsFreezer']) {
        $r = Invoke-LdAdb -Arguments @('shell', 'settings', 'put', 'global', 'cached_apps_freezer', 'enabled') -AllowFail -Quiet
        if ($r -and $r.ExitCode -eq 0) { [void]$done.Add('Cached-app freezer enabled (idle apps give RAM back)') }
    }

    if ($Options['DisableBloat']) {
        $n = 0
        foreach ($p in $script:LDBloat) {
            $r = Invoke-LdAdb -Arguments @('shell', 'pm', 'disable-user', '--user', '0', $p) -AllowFail -Quiet
            if ($r -and $r.Text -match 'new state: disabled') { $n = $n + 1 }
        }
        if ($n -gt 0) { [void]$done.Add("$n unused system package(s) disabled") }
    }

    foreach ($d in $done) { Write-LdLog $d OK }
    return $done
}

function Set-LdResourceLimits {
    <#
        Writes the RAM / vCPU / GPU budget into the subsystem's own settings file.
        Takes effect the next time the Android VM boots.
    #>
    param([int]$MemoryMb, [int]$Cores, [bool]$EnableGpu = $true)

    if (-not $script:LD.Config) { Initialize-LiteDroid | Out-Null }
    $cfg = Get-LdConfig

    if ($MemoryMb -le 0) {
        $pf = Get-LdPreflight
        $MemoryMb = Resolve-LdMemoryMb -HostRamGb $pf.HostRamGb
    }
    if ($Cores -le 0) {
        $pf = Get-LdPreflight
        $Cores = Resolve-LdCores -LogicalCores $pf.LogicalCores
    }
    if ($MemoryMb -lt 2048) { $MemoryMb = 2048 }

    Set-LdWsaSettings -Values @{
        memoryMB     = $MemoryMb
        numberOfCores = $Cores
        gpuOptions   = @{ enableGPU = $EnableGpu }
        debugging    = @{ localConnect = $true }
    }

    $cfg['MemoryMB'] = $MemoryMb
    $cfg['Cores'] = $Cores
    $cfg['EnableGpu'] = $EnableGpu
    Save-LdConfig -Config $cfg

    Write-LdLog ("Budget set: {0} MB RAM, {1} vCPU, GPU {2}" -f $MemoryMb, $Cores, $(if ($EnableGpu) { 'on' } else { 'off' })) OK
    return [pscustomobject]@{ MemoryMb = $MemoryMb; Cores = $Cores; EnableGpu = $EnableGpu }
}

#endregion

#region self test

function Test-LdSelfTest {
    <#
        Runs the deterministic parts of the engine and prints PASS/FAIL.
        Nothing here touches Windows, so it is safe to run any time.
    #>
    $results = New-Object System.Collections.ArrayList
    $check = {
        param($Name, $Actual, $Expected)
        $ok = ($Actual -eq $Expected)
        [void]$results.Add([pscustomobject]@{ Test = $Name; Pass = $ok; Got = $Actual; Want = $Expected })
    }

    & $check 'Format-LdSize 512'      (Format-LdSize 512)     '512 MB'
    & $check 'Format-LdSize 2048'     (Format-LdSize 2048)    '2.0 GB'
    & $check 'Format-LdSize 0'        (Format-LdSize 0)       '0 MB'
    & $check 'Format-LdKBytes 524288' (Format-LdKBytes 524288) '512 MB'
    & $check 'Resolve-LdMemoryMb 4GB'  (Resolve-LdMemoryMb 4)  2048
    & $check 'Resolve-LdMemoryMb 8GB'  (Resolve-LdMemoryMb 8)  2560
    & $check 'Resolve-LdMemoryMb 16GB' (Resolve-LdMemoryMb 16) 4096
    & $check 'Resolve-LdCores 2'       (Resolve-LdCores 2)     2
    & $check 'Resolve-LdCores 8'       (Resolve-LdCores 8)     4
    & $check 'Resolve-LdCores 12'      (Resolve-LdCores 12)    4

    $mem = ConvertFrom-LdMeminfo -Lines @(
        'Total PSS by process:',
        '  182,331K: com.yacine.tv (pid 4321)',
        '   44,120K: com.yacine.tv:remote (pid 4400)',
        '    9,001K: com.android.systemui (pid 1200)',
        'not a match'
    )
    & $check 'meminfo: yacine PSS'   $mem['com.yacine.tv']         182331
    & $check 'meminfo: yacine remote' $mem['com.yacine.tv:remote'] 44120
    & $check 'meminfo: count'        $mem.Count                    3

    $failed = @($results | Where-Object { -not $_.Pass })
    foreach ($r in $results) {
        if ($r.Pass) { Write-Host ("  PASS  {0}" -f $r.Test) -ForegroundColor Green }
        else         { Write-Host ("  FAIL  {0}  got={1} want={2}" -f $r.Test, $r.Got, $r.Want) -ForegroundColor Red }
    }
    Write-Host ''
    if ($failed.Count -eq 0) {
        Write-Host ("All {0} self-tests passed." -f $results.Count) -ForegroundColor Green
        return $true
    }
    Write-Host ("{0} of {1} self-tests FAILED." -f $failed.Count, $results.Count) -ForegroundColor Red
    return $false
}

#endregion
