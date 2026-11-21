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

# On pre-22H2 Windows 10 the runtime expects two cumulative updates. Report
# which ones are missing instead of failing later with an appx error.
if (-not $pf.IsWin11 -and $pf.Build -lt 19045) {
    $missing = @()
    foreach ($kb in @('KB5014032', 'KB5022834')) {
        $found = $null
        try { $found = Get-HotFix -Id $kb -ErrorAction Stop } catch { $found = $null }
        if (-not $found) { $missing += $kb }
    }
    if ($missing.Count -gt 0) {
        Write-LdLog ("Missing update(s): {0} - Windows Update will install them; the runtime may not start without them." -f ($missing -join ', ')) WARN
    } else {
        Write-LdLog 'Both compatibility updates are present.' OK
    }
}

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
function Get-LdRemoteSize {
    <#
        Content-Length of a URL, or -1 when unknown. Used to tell a complete
        download from one that died halfway.
    #>
    param([string]$Url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'
        $req.UserAgent = 'LiteDroid'
        $req.AllowAutoRedirect = $true
        $req.Timeout = 25000
        $resp = $req.GetResponse()
        $len = $resp.ContentLength
        $resp.Close()
        return [int64]$len
    } catch { return [int64]-1 }
}

function Test-LdDownloadComplete {
    param([string]$OutFile, [int64]$ExpectedBytes)
    if (-not (Test-Path -LiteralPath $OutFile)) { return $false }
    $have = (Get-Item -LiteralPath $OutFile).Length
    if ($have -le 0) { return $false }
    if ($ExpectedBytes -gt 0) { return ($have -eq $ExpectedBytes) }
    return $true
}

function Invoke-LdStreamDownload {
    <#
        Pure .NET fallback downloader: HTTP Range resume, streamed straight to
        disk in 256 KB chunks, with progress lines. Never buffers the whole file
        in memory (which is what makes Invoke-WebRequest useless for a 530 MB
        image on PowerShell 5.1).
    #>
    param([string]$Url, [string]$OutFile, [string]$Label, [int64]$ExpectedBytes = -1)

    $have = [int64]0
    if (Test-Path -LiteralPath $OutFile) { $have = (Get-Item -LiteralPath $OutFile).Length }

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'LiteDroid/1.0'
    $req.AllowAutoRedirect = $true
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 60000
    if ($have -gt 0) {
        Write-LdLog ("Resuming at {0:N1} MB ..." -f ($have / 1MB)) INFO
        $req.AddRange($have)
    }

    $resp = $req.GetResponse()
    $mode = [System.IO.FileMode]::Append
    if ($have -gt 0 -and [int]$resp.StatusCode -ne 206) {
        # server ignored the Range header: start over cleanly
        Write-LdLog 'Server does not support resume - restarting this file.' WARN
        $have = 0
        $mode = [System.IO.FileMode]::Create
    }
    $total = $have + $resp.ContentLength

    $fs = New-Object System.IO.FileStream($OutFile, $mode, [System.IO.FileAccess]::Write)
    $in = $resp.GetResponseStream()
    $buf = New-Object byte[] 262144
    $done = $have
    $lastMark = $have
    $started = Get-Date
    try {
        while ($true) {
            $n = $in.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $fs.Write($buf, 0, $n)
            $done += $n
            if (($done - $lastMark) -ge (25 * 1MB) -or ($total -gt 0 -and $done -eq $total)) {
                $lastMark = $done
                $pct = 0
                if ($total -gt 0) { $pct = [int](100 * $done / $total) }
                $elapsed = ((Get-Date) - $started).TotalSeconds
                $rate = 0
                if ($elapsed -gt 0) { $rate = (($done - $have) / 1MB) / $elapsed }
                Write-LdLog ("{0}: {1} MB / {2} MB ({3}%, {4:N0} KB/s)" -f $Label, [int]($done / 1MB), [int]($total / 1MB), $pct, ($rate * 1024)) INFO
            }
        }
    } finally {
        $fs.Flush()
        $fs.Close()
        $in.Close()
        $resp.Close()
    }
    return $done
}

function Invoke-LdDownload {
    <#
        Downloads $Url to $OutFile, resuming whatever bytes are already on disk.

        The 530 MB Android image is the one thing here that can hit a bad network,
        so this is deliberately stubborn: curl with resume + retry-all-errors,
        then a Range-based .NET stream downloader, then verification against the
        expected size. A truncated file is never treated as "already done".
    #>
    param(
        [string]$Url,
        [string]$OutFile,
        [string]$Label,
        [int64]$ExpectedBytes = -1
    )

    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ($ExpectedBytes -le 0) { $ExpectedBytes = Get-LdRemoteSize -Url $Url }

    if (Test-Path -LiteralPath $OutFile) {
        $have = (Get-Item -LiteralPath $OutFile).Length
        if ($ExpectedBytes -gt 0 -and $have -eq $ExpectedBytes) {
            Write-LdLog ("$Label already downloaded ({0:N1} MB)." -f ($have / 1MB)) INFO
            return $true
        }
        if ($ExpectedBytes -le 0 -and $have -gt 0) {
            Write-LdLog "$Label already downloaded." INFO
            return $true
        }
        Write-LdLog ("Incomplete file on disk ({0:N1} MB) - continuing from there." -f ($have / 1MB)) WARN
    }

    if ($ExpectedBytes -gt 0) {
        Write-LdLog ("Downloading {0} ({1:N0} MB) ..." -f $Label, ($ExpectedBytes / 1MB)) STEP
    } else {
        Write-LdLog "Downloading $Label ..." STEP
    }

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            if ($attempt -gt 1) {
                Write-LdLog ("Retry {0}/4 - resuming the broken transfer ..." -f $attempt) WARN
                Start-Sleep -Seconds 5
            }

            # Resume offset is passed explicitly (-C <bytes>) instead of curl's
            # "-C -" auto mode: same result, no ambiguity in the command line.
            $have = [int64]0
            if (Test-Path -LiteralPath $OutFile) { $have = (Get-Item -LiteralPath $OutFile).Length }
            $curlArgs = @('-L')
            if ($have -gt 0) { $curlArgs += @('-C', [string]$have) }
            $curlArgs += @(
                '--retry', '5', '--retry-delay', '3',
                '--retry-all-errors',            # also retries curl's "partial file" (18)
                '--connect-timeout', '25',
                '--speed-limit', '20480',        # give up after ...
                '--speed-time', '120',           # ... 2 minutes under 20 KB/s
                '--fail', '-o', $OutFile, $Url
            )
            & $curl @curlArgs
            $code = $LASTEXITCODE
            if (Test-LdDownloadComplete -OutFile $OutFile -ExpectedBytes $ExpectedBytes) {
                Write-LdLog ("{0}: {1:N1} MB" -f $Label, ((Get-Item -LiteralPath $OutFile).Length / 1MB)) OK
                return $true
            }
            Write-LdLog ("curl attempt {0} stopped early (exit {1})." -f $attempt, $code) WARN
        }
    }

    # --- fallback: our own resumable downloader
    Write-LdLog 'Switching to the built-in resumable downloader ...' WARN
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            [void](Invoke-LdStreamDownload -Url $Url -OutFile $OutFile -Label $Label -ExpectedBytes $ExpectedBytes)
        } catch {
            Write-LdLog ("Download error: " + $_.Exception.Message) WARN
        }
        if (Test-LdDownloadComplete -OutFile $OutFile -ExpectedBytes $ExpectedBytes) {
            Write-LdLog ("{0}: {1:N1} MB" -f $Label, ((Get-Item -LiteralPath $OutFile).Length / 1MB)) OK
            return $true
        }
        Start-Sleep -Seconds 5
    }

    $have = 0
    if (Test-Path -LiteralPath $OutFile) { $have = (Get-Item -LiteralPath $OutFile).Length }
    Write-LdLog ("Download did not finish: {0:N0} MB of {1:N0} MB on disk." -f ($have / 1MB), ($ExpectedBytes / 1MB)) ERR
    Write-LdLog 'Run Setup again - it continues from the bytes already downloaded, it does not start over.' WARN
    return $false
}

function Find-LdLocalArchive {
    <#
        Escape hatch for slow connections: if a complete image is already on the
        disk (downloaded by a browser, an external download manager, copied from
        another PC or a phone), use it instead of downloading again.
    #>
    param([string]$Name, [int64]$ExpectedBytes, [string[]]$Dirs)

    foreach ($d in $Dirs) {
        if (-not $d -or -not (Test-Path -LiteralPath $d)) { continue }
        $candidates = @()
        try {
            $candidates = Get-ChildItem -LiteralPath $d -Filter '*.7z' -File -ErrorAction Stop
        } catch { continue }
        foreach ($c in $candidates) {
            $isNamed = ($c.Name -eq $Name)
            $isWsa = ($c.Name -like 'WSA_*.7z')
            if (-not ($isNamed -or $isWsa)) { continue }
            if ($ExpectedBytes -gt 0 -and $c.Length -ne $ExpectedBytes) {
                if ($isNamed) {
                    Write-LdLog ("Found {0} but it is {1:N0} MB instead of {2:N0} MB - incomplete, ignoring it." -f $c.FullName, ($c.Length / 1MB), ($ExpectedBytes / 1MB)) WARN
                }
                continue
            }
            Write-LdLog ("Using the image already on disk: " + $c.FullName) OK
            return $c.FullName
        }
    }
    return $null
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
                SizeBytes = [int64]$asset.size
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
    $asset = [pscustomobject]@{ Url = [string]$cfg['WsaAssetUrl']; Name = 'pinned-image.7z'; SizeMb = 0; SizeBytes = [int64]-1; Release = 'pinned' }
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
    $expected = [int64]-1
    try { $expected = [int64]$asset.SizeBytes } catch { $expected = [int64]-1 }

    # A complete image anywhere obvious wins over downloading 530 MB again.
    $localHit = $null
    if (-not (Test-LdDownloadComplete -OutFile $archive -ExpectedBytes $expected)) {
        $localHit = Find-LdLocalArchive -Name $asset.Name -ExpectedBytes $expected -Dirs @(
            (Split-Path -Parent $here), $here,
            (Join-Path $env:USERPROFILE 'Downloads'),
            (Join-Path $env:USERPROFILE 'Desktop')
        )
    }
    if ($localHit -and ($localHit -ne $archive)) {
        Write-LdLog 'Copying it into the LiteDroid folder ...' STEP
        try { Copy-Item -LiteralPath $localHit -Destination $archive -Force -ErrorAction Stop } catch {
            Write-LdLog ("Copy failed: " + $_.Exception.Message) ERR
        }
    }

    if (-not (Invoke-LdDownload -Url $asset.Url -OutFile $archive -Label 'Android 13 image' -ExpectedBytes $expected)) { exit 4 }

    Write-LdLog 'Verifying the archive ...' STEP
    & $sevenZip t $archive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LdLog 'The downloaded image is damaged. Deleting it so the next run fetches a clean copy.' ERR
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        exit 4
    }
    Write-LdLog 'Archive verified.' OK

    Write-LdLog 'Extracting (this takes a minute or two) ...' STEP
    if (Test-Path -LiteralPath $wsaDir) {
        try { Remove-Item -LiteralPath $wsaDir -Recurse -Force -ErrorAction Stop } catch { }
    }
    New-Item -ItemType Directory -Path $wsaDir -Force | Out-Null
    & $sevenZip x $archive ("-o" + $wsaDir) -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LdLog "Extraction failed (7-Zip exit $LASTEXITCODE)." ERR
        Write-LdLog 'Free some disk space (about 4 GB is needed while extracting), then run Setup again.' WARN
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
Write-Host '  Opening LiteDroid ...' -ForegroundColor Cyan
Write-Host '  (you can close this black window)' -ForegroundColor DarkGray
Write-Host ''

# Hand over to the manager so a first-time user does not have to find another
# file. The window runs in this elevated context, which only affects which
# account the file dialogs and shortcuts use - it is the same program.
try {
    $gui = Join-Path $here 'LiteDroid.ps1'
    Start-Process -FilePath 'powershell.exe' `
                  -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                                  '-File', ('"' + $gui + '"')) | Out-Null
} catch {
    Write-LdLog "Could not open the window automatically: $($_.Exception.Message)" WARN
    Write-Host '  Double-click "START HERE.bat" to open LiteDroid.' -ForegroundColor Yellow
}
exit 0
