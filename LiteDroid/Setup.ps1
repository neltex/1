<#
    LiteDroid - Setup
    -----------------
    One-time, elevated installer. It does exactly five things:

      1. checks the machine can virtualize Android,
      2. turns on the two Windows features the runtime needs,
      3. fetches the *smallest* Android 13 image that fits the chosen profile,
      4. registers it with Windows so apps appear as native windows,
      5. tunes it down (RAM budget, vCPUs, GPU, animations, bloat).

    Usage (from an elevated PowerShell):

        .\Setup.ps1                      # ultra-light profile, auto sizing
        .\Setup.ps1 -Profile balanced    # + Google Play services
        .\Setup.ps1 -Replace             # wipe the runtime and reinstall
        .\Setup.ps1 -MemoryMB 2048 -Cores 2

    Exit codes: 0 ok, 2 blocked, 3 reboot required, 4 unexpected failure.
#>

[CmdletBinding()]
param(
    [ValidateSet('ultralight', 'balanced')]
    [string]$Profile = 'ultralight',
    [int]$MemoryMB = 0,
    [int]$Cores = 0,
    [switch]$Replace,
    [switch]$SkipTune,
    [switch]$SkipApk
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Core.ps1')

Initialize-LiteDroid | Out-Null

Write-Host ''
Write-Host '  LiteDroid setup' -ForegroundColor White
Write-Host '  ---------------' -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-LdAdmin)) {
    Write-LdLog 'Setup must run as administrator.' ERR
    Write-Host '  Right-click "Install LiteDroid.bat" and choose "Run as administrator".' -ForegroundColor Yellow
    exit 2
}

# ---------------------------------------------------------------- 1. preflight
$pf = Get-LdPreflight
Write-LdLog ("{0} build {1} | {2} | {3} logical cores | {4} GB RAM | {5} GB free" -f `
    $(if ($pf.IsWin11) { 'Windows 11' } else { 'Windows 10' }), $pf.Build, $pf.Arch, $pf.LogicalCores, $pf.HostRamGb, $pf.FreeDiskGb) INFO

foreach ($w in $pf.Warnings) { Write-LdLog $w WARN }

if ($pf.Blockers.Count -gt 0) {
    foreach ($b in $pf.Blockers) { Write-LdLog $b ERR }
    Write-LdLog 'Setup cannot continue on this machine.' ERR
    exit 2
}

# ------------------------------------------------------------- 2. features
Write-LdLog 'Checking Windows features ...' STEP
$restartNeeded = $false
foreach ($feat in @('VirtualMachinePlatform', 'HypervisorPlatform')) {
    $state = 'Unknown'
    try { $state = [string](Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction Stop).State } catch { }
    if ($state -eq 'Enabled') {
        Write-LdLog "$feat already enabled." INFO
        continue
    }
    Write-LdLog "Enabling $feat ..." STEP
    try {
        $res = Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart -ErrorAction Stop
        if ($res.RestartNeeded) { $restartNeeded = $true }
        Write-LdLog "$feat enabled." OK
    } catch {
        Write-LdLog "Could not enable $feat : $($_.Exception.Message)" ERR
        exit 2
    }
}

if ($restartNeeded) {
    Write-Host ''
    Write-LdLog 'A REBOOT is required to finish enabling virtualization support.' WARN
    Write-LdLog 'Reboot now, then run Setup again - it will pick up where it left off.' WARN
    Write-Host ''
    Write-Host '  Press Enter to restart Windows, or close this window to reboot later.' -ForegroundColor Yellow
    try { Read-Host | Out-Null } catch { }
    try { Restart-Computer -Force } catch { }
    exit 3
}

# ------------------------------------------------------------ 3. toolchain
function Invoke-LdDownload {
    param([string]$Url, [string]$OutFile, [string]$Label)

    if ((Test-Path -LiteralPath $OutFile) -and ((Get-Item -LiteralPath $OutFile).Length -gt 0)) {
        Write-LdLog "$Label already downloaded." INFO
        return $true
    }
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Write-LdLog "Downloading $Label ..." STEP
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        # curl.exe is much faster than Invoke-WebRequest for big files and shows
        # a real progress bar in the console.
        & $curl -L --fail --retry 3 --retry-delay 3 --connect-timeout 20 -o $OutFile $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)) {
            Write-LdLog ("{0}: {1:N1} MB" -f $Label, ((Get-Item -LiteralPath $OutFile).Length / 1MB)) OK
            return $true
        }
        Write-LdLog "curl failed (exit $LASTEXITCODE), retrying with PowerShell ..." WARN
    }
    try {
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
        $ProgressPreference = $old
        Write-LdLog ("{0}: {1:N1} MB" -f $Label, ((Get-Item -LiteralPath $OutFile).Length / 1MB)) OK
        return $true
    } catch {
        Write-LdLog "Download failed: $($_.Exception.Message)" ERR
        return $false
    }
}

Write-LdLog 'Preparing tools ...' STEP
$toolsDir = Join-Path $script:LD.Root 'tools'
if (-not (Test-Path -LiteralPath $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }

# 7zr.exe - 600 KB standalone extractor, the only external binary we need.
$sevenZip = Join-Path $toolsDir '7zr.exe'
if (-not (Test-Path -LiteralPath $sevenZip)) {
    $installed7z = 'C:\Program Files\7-Zip\7z.exe'
    if (Test-Path -LiteralPath $installed7z) {
        $sevenZip = $installed7z
        Write-LdLog 'Using installed 7-Zip.' INFO
    } else {
        if (-not (Invoke-LdDownload -Url 'https://www.7-zip.org/a/7zr.exe' -OutFile $sevenZip -Label '7-Zip standalone (7zr.exe)')) {
            Write-LdLog 'Cannot extract the Android image without 7zr.exe.' ERR
            exit 4
        }
    }
}

# adb - from Google's platform-tools, ~5 MB.
$adbExe = Join-Path $toolsDir 'platform-tools\adb.exe'
if (-not (Test-Path -LiteralPath $adbExe)) {
    $ptZip = Join-Path $script:LD.Root 'downloads\platform-tools.zip'
    if (Invoke-LdDownload -Url 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $ptZip -Label 'Android platform-tools (adb)') {
        Write-LdLog 'Extracting platform-tools ...' STEP
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ptZip, $toolsDir)
            Write-LdLog 'adb ready.' OK
        } catch {
            Write-LdLog "Could not extract platform-tools: $($_.Exception.Message)" ERR
        }
    }
}

# --------------------------------------------------------- 4. pick the image
function Resolve-LdWsaAsset {
    <#
        Asks the WSABuilds project for its newest release and picks the smallest
        asset that matches this machine + profile. Everything is filtered by OS
        build and CPU architecture, so Windows 10 gets the patched build.
    #>
    param([string]$ProfileName, [bool]$WinTen, [string]$Arch)

    $tagPrefix = 'Windows_11_'
    if ($WinTen) { $tagPrefix = 'Windows_10_' }
    $archTag = ''
    if ($Arch -eq 'ARM64') { $archTag = '_arm64' }

    Write-LdLog 'Looking up the current Android image ...' STEP
    $rels = Invoke-RestMethod -Uri 'https://api.github.com/repos/MustardChef/WSABuilds/releases?per_page=40' `
                              -Headers @{ 'User-Agent' = 'LiteDroid' } -ErrorAction Stop

    foreach ($rel in ($rels | Sort-Object { $_.published_at } -Descending)) {
        $tag = [string]$rel.tag_name
        if ($tag -notlike ($tagPrefix + '*')) { continue }
        if ($archTag) {
            if ($tag -notlike ('*' + $archTag)) { continue }
        } else {
            if ($tag -like '*_arm64*') { continue }
        }

        foreach ($asset in $rel.assets) {
            $n = [string]$asset.name
            if ($n -notlike '*.7z') { continue }
            if ($n -like '*magisk*') { continue }
            if ($WinTen) {
                if ($n -notlike '*Windows_10*') { continue }
            } else {
                if ($n -like '*Windows_10*') { continue }
            }
            if ($n -notlike '*NoAmazon*') { continue }
            if ($ProfileName -eq 'ultralight') {
                if ($n -notlike '*NoGApps*') { continue }
            } else {
                if ($n -like '*NoGApps*') { continue }
            }
            return [pscustomobject]@{
                Url       = [string]$asset.browser_download_url
                Name      = $n
                SizeMb    = [math]::Round([double]$asset.size / 1MB, 0)
                Release   = $tag
            }
        }
    }
    return $null
}

$isWin10 = -not $pf.IsWin11
$asset = $null
try {
    $asset = Resolve-LdWsaAsset -ProfileName $Profile -WinTen $isWin10 -Arch $pf.Arch
} catch {
    Write-LdLog "Release lookup failed: $($_.Exception.Message)" WARN
}

$cfg = Get-LdConfig
if (-not $asset -and $cfg['WsaAssetUrl']) {
    Write-LdLog 'Using the pinned image URL from config.json.' WARN
    $asset = [pscustomobject]@{ Url = [string]$cfg['WsaAssetUrl']; Name = 'pinned-image.7z'; SizeMb = 0; Release = 'pinned' }
}
if (-not $asset) {
    Write-LdLog 'No matching Android image could be found (GitHub unreachable, or no asset for this profile).' ERR
    Write-LdLog 'Tip: set "WsaAssetUrl" in C:\LiteDroid\config.json to a direct .7z link and run Setup again.' WARN
    exit 4
}

Write-LdLog ("Image: {0} ({1} MB, {2})" -f $asset.Name, $asset.SizeMb, $asset.Release) INFO

$existing = Get-LdWsaPackage
if ($existing -and -not $Replace) {
    $installedProfile = [string]$cfg['InstalledProfile']
    if ($installedProfile -eq $Profile) {
        Write-LdLog 'The runtime is already installed with this profile - skipping the download.' OK
    } else {
        Write-LdLog ("A runtime is already installed (profile '{0}'). Re-run with -Replace to switch to '{1}'." -f $installedProfile, $Profile) WARN
        exit 4
    }
}

# ------------------------------------------------------- 5. download/extract
if ($Replace -and $existing) {
    Write-LdLog 'Removing the existing Android runtime ...' STEP
    try {
        Get-AppxPackage -Name $script:LD.WsaName -ErrorAction Stop | Remove-AppxPackage -ErrorAction Stop
        Write-LdLog 'Old runtime removed.' OK
    } catch {
        Write-LdLog "Could not remove old runtime: $($_.Exception.Message)" ERR
        exit 4
    }
    $existing = $null
}

$wsaDir = Join-Path $script:LD.Root 'wsa'
if (-not (Get-LdWsaPackage) -or $Replace) {
    $archive = Join-Path $script:LD.Root ('downloads\' + $asset.Name)
    if (-not (Invoke-LdDownload -Url $asset.Url -OutFile $archive -Label 'Android 13 image')) { exit 4 }

    Write-LdLog 'Extracting (this takes a minute on a hard disk) ...' STEP
    if (Test-Path -LiteralPath $wsaDir) {
        try { Remove-Item -LiteralPath $wsaDir -Recurse -Force -ErrorAction Stop } catch { }
    }
    New-Item -ItemType Directory -Path $wsaDir -Force | Out-Null
    & $sevenZip x $archive ("-o" + $wsaDir) -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LdLog "Extraction failed (7-Zip exit $LASTEXITCODE)." ERR
        exit 4
    }
    Write-LdLog 'Extracted.' OK

    # ---- dependencies: WSA links against the desktop VCLibs runtime
    $vclibsUrl = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'
    if ($pf.Arch -eq 'ARM64') { $vclibsUrl = 'https://aka.ms/Microsoft.VCLibs.arm64.14.00.Desktop.appx' }
    $vclibs = Join-Path $script:LD.Root 'downloads\VCLibs.appx'
    if (Invoke-LdDownload -Url $vclibsUrl -OutFile $vclibs -Label 'VCLibs dependency') {
        try {
            Add-AppxPackage -Path $vclibs -ErrorAction Stop
            Write-LdLog 'VCLibs ready.' OK
        } catch {
            Write-LdLog "VCLibs note: $($_.Exception.Message)" WARN
        }
    }

    # ---- register the unpackaged runtime
    Write-LdLog 'Registering the runtime with Windows ...' STEP
    $manifest = $null
    try {
        $manifest = Get-ChildItem -LiteralPath $wsaDir -Filter 'AppxManifest.xml' -Recurse -File -ErrorAction Stop |
                    Sort-Object { $_.FullName.Length } | Select-Object -First 1
    } catch { }
    if (-not $manifest) {
        Write-LdLog 'AppxManifest.xml not found in the extracted image.' ERR
        exit 4
    }
    Write-LdLog ("Manifest: " + $manifest.FullName) INFO
    try {
        Add-AppxPackage -Register $manifest.FullName -ForceApplicationShutdown -ForceUpdateFromAnyVersion -ErrorAction Stop
        Write-LdLog 'Runtime registered.' OK
    } catch {
        Write-LdLog "Registration failed: $($_.Exception.Message)" ERR
        Write-LdLog 'Diagnostics:  Get-AppPackageLog -ActivityID <id printed above>' WARN
        Write-LdLog 'Common causes: a pending reboot, a third-party emulator holding virtualization, or an antivirus lock.' WARN
        exit 4
    }
}

$pkg = Get-LdWsaPackage
if (-not $pkg) {
    Write-LdLog 'Runtime is not registered - something went wrong above.' ERR
    exit 4
}
$script:LD.WsaPfn = [string]$pkg.PackageFamilyName
Write-LdLog ("Runtime installed: " + $pkg.Version) OK

# --------------------------------------------------------- 6. resource budget
$mem = $MemoryMB
$cores = $Cores
if ($mem -le 0) { $mem = Resolve-LdMemoryMb -HostRamGb $pf.HostRamGb }
if ($cores -le 0) { $cores = Resolve-LdCores -LogicalCores $pf.LogicalCores }

if ((Get-Process -Name 'WsaClient' -ErrorAction SilentlyContinue) -or (Get-LdVmProcess)) {
    Write-LdLog 'Stopping the running runtime so the new budget applies ...' STEP
    Stop-LdWsa -Force
    Start-Sleep -Seconds 2
}

Set-LdResourceLimits -MemoryMb $mem -Cores $cores -EnableGpu ([bool]$cfg['EnableGpu']) | Out-Null

$cfg = Get-LdConfig
$cfg['Profile'] = $Profile
$cfg['InstalledProfile'] = $Profile
Save-LdConfig -Config $cfg

# ------------------------------------------------------------- 7. first boot
Write-LdLog 'Starting the runtime for the first time (30-90 s) ...' STEP
[void](Start-LdVmAndAdb -TimeoutSec 150)

if (-not (Test-LdAdbDevice)) {
    # A first boot can regenerate settings.json, which silently drops the adb
    # switch. Re-apply the budget, restart once, then report honestly.
    Write-LdLog 'No adb yet - re-applying settings and restarting the runtime once ...' WARN
    Set-LdResourceLimits -MemoryMb $mem -Cores $cores -EnableGpu ([bool]$cfg['EnableGpu']) | Out-Null
    Stop-LdWsa -Force
    Start-Sleep -Seconds 2
    [void](Start-LdVmAndAdb -TimeoutSec 120)
}

$applied = Get-LdWsaSettings
if ($applied.ContainsKey('memoryMB')) {
    Write-LdLog ('Runtime budget in effect: memoryMB=' + $applied['memoryMB'] + ' numberOfCores=' + $applied['numberOfCores']) INFO
} else {
    Write-LdLog 'settings.json has no memoryMB key yet - the runtime writes it on first shutdown. Re-run Setup to enforce the budget.' WARN
}

if (-not (Test-LdAdbDevice)) {
    Write-LdLog 'The runtime did not answer adb. It may still boot - open it once from the Start menu, then run LiteDroid again.' WARN
} else {
    Write-LdLog ("adb connected - Android is up with {0} MB RAM / {1} vCPU." -f $mem, $cores) OK
    if (-not $SkipTune) {
        [void](Invoke-LdTuning -Options @{
            DisableAnimations = [bool]$cfg['DisableAnimations']
            ScreenMode        = [string]$cfg['ScreenMode']
            DisableBloat      = [bool]$cfg['DisableBloat']
            CachedAppsFreezer = [bool]$cfg['CachedAppsFreezer']
        })
    }
}

# ------------------------------------------------------------ 8. ready APKs
if (-not $SkipApk) {
    $searchDirs = @((Split-Path -Parent $here), $here)
    $apks = Get-LdApkCandidates -Directories $searchDirs
    if ($apks.Count -gt 0 -and (Test-LdAdbDevice)) {
        Write-LdLog ("Installing {0} APK file(s) found next to LiteDroid ..." -f $apks.Count) STEP
        foreach ($apk in $apks) {
            try { [void](Install-LdApk -Path @($apk.Path)) } catch { Write-LdLog "  $($apk.Name): $($_.Exception.Message)" WARN }
        }
    }
}

$report = Get-LdMemoryReport
Write-Host ''
Write-LdLog 'Setup complete.' OK
Write-Host ''
Write-Host ('  Profile      : ' + $Profile) -ForegroundColor Gray
Write-Host ('  RAM budget   : ' + $mem + ' MB for Android') -ForegroundColor Gray
Write-Host ('  vCPUs        : ' + $cores) -ForegroundColor Gray
Write-Host ('  VM footprint : ' + (Format-LdSize $report.VmMb)) -ForegroundColor Gray
Write-Host ('  Windows free : ' + (Format-LdSize $report.HostFreeMb)) -ForegroundColor Gray
Write-Host ''
Write-Host '  Next: run "Start LiteDroid.bat" (no admin needed).' -ForegroundColor Cyan
Write-Host ''
exit 0
