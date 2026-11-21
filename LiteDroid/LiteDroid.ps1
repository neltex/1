<#
    LiteDroid - entry point
    -----------------------
    Double-click "Start LiteDroid.bat" for the window, or use one verb:

        LiteDroid.ps1                     open the window
        LiteDroid.ps1 -Apk app.apk        install an APK (no window)
        LiteDroid.ps1 -Tune               re-apply the performance profile
        LiteDroid.ps1 -Hibernate          stop every Android app
        LiteDroid.ps1 -Diag               print a capability report
        LiteDroid.ps1 -SelfTest           run the built-in engine tests
#>

[CmdletBinding()]
param(
    [switch]$Setup,
    [string[]]$Apk,
    [switch]$Tune,
    [switch]$Hibernate,
    [switch]$Diag,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'lib\Core.ps1')

try {
    Initialize-LiteDroid | Out-Null
} catch {
    Write-Host ('Cannot create C:\LiteDroid: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Run this as a user who can write to C:\ (the installer does).' -ForegroundColor Yellow
    exit 4
}

# --------------------------------------------------------------- engine tests
if ($SelfTest) {
    exit $(if (Test-LdSelfTest) { 0 } else { 1 })
}

# ------------------------------------------------------------------ diagnostics
if ($Diag) {
    $pf = Get-LdPreflight
    Write-Host ''
    Write-Host '  LiteDroid diagnostics' -ForegroundColor White
    Write-Host '  ---------------------' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('  Windows        : build ' + $pf.Build + $(if ($pf.IsWin11) { ' (Windows 11)' } else { ' (Windows 10)' }))
    Write-Host ('  Architecture   : ' + $pf.Arch)
    Write-Host ('  CPU            : ' + $pf.CpuName + '  (' + $pf.LogicalCores + ' threads)')
    Write-Host ('  RAM            : ' + $pf.HostRamGb + ' GB')
    Write-Host ('  Free disk      : ' + $pf.FreeDiskGb + ' GB on ' + $env:SystemDrive)
    Write-Host ('  Virtualization : firmware=' + $pf.VirtFirmware + ' hypervisor=' + $pf.HypervisorOn)
    Write-Host ('  Feature VMP    : ' + $pf.FeatureVmp)
    Write-Host ('  Feature WHP    : ' + $pf.FeatureWhp)
    Write-Host ('  Runtime        : ' + $(if ($pf.WsaInstalled) { 'installed at ' + $pf.WsaLocation } else { 'not installed' }))
    Write-Host ('  adb            : ' + $(if (Get-LdAdbExe) { Get-LdAdbExe } else { 'missing' }))
    Write-Host ('  adb device     : ' + $(if (Test-LdAdbDevice) { 'connected' } else { 'not connected' }))
    $vm = Get-LdVmProcess
    if ($vm) { Write-Host ('  VM process     : ' + $vm.ProcessName + '  ' + (Format-LdSize ([math]::Round($vm.WorkingSet64 / 1MB, 0)))) }
    else { Write-Host '  VM process     : not running' }
    Write-Host ''
    if ($pf.Blockers.Count -gt 0) {
        Write-Host '  BLOCKERS:' -ForegroundColor Red
        foreach ($b in $pf.Blockers) { Write-Host ('   - ' + $b) -ForegroundColor Red }
    }
    if ($pf.Warnings.Count -gt 0) {
        Write-Host '  WARNINGS:' -ForegroundColor Yellow
        foreach ($w in $pf.Warnings) { Write-Host ('   - ' + $w) -ForegroundColor Yellow }
    }
    Write-Host ('  Log file       : ' + $script:LD.LogFile)
    Write-Host ''
    exit 0
}

# --------------------------------------------------------------------- install
if ($Setup) {
    if (-not (Test-LdAdmin)) {
        Write-Host 'Setup must run elevated. Use "Install LiteDroid.bat".' -ForegroundColor Yellow
        exit 2
    }
    & (Join-Path $here 'Setup.ps1')
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------- CLI actions
if ($Apk -and $Apk.Count -gt 0) {
    try {
        $done = Install-LdApk -Path $Apk -Launch
        if ($done -and $done.Count -gt 0) { Write-Host ('Installed: ' + ($done -join ', ')) -ForegroundColor Green }
        exit 0
    } catch {
        Write-Host ('Install failed: ' + $_.Exception.Message) -ForegroundColor Red
        exit 4
    }
}

if ($Hibernate) {
    try { Stop-LdAllApps } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 4 }
    exit 0
}

if ($Tune) {
    try { [void](Invoke-LdTuning) } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 4 }
    exit 0
}

# ------------------------------------------------------------------------ GUI
# WinForms needs a single-threaded apartment; re-launch ourselves if the host
# handed us an MTA thread (some shells do).
$apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
if ($apartment -ne [System.Threading.ApartmentState]::STA) {
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList | Out-Null
    exit 0
}

. (Join-Path $here 'lib\Ui.ps1')

$preflight = $null
try {
    $preflight = Get-LdPreflight
} catch {
    $preflight = [pscustomobject]@{
        Build = 0; IsWin11 = $false; Arch = $env:PROCESSOR_ARCHITECTURE
        LogicalCores = 2; HostRamGb = 8; FreeDiskGb = 0
        WsaInstalled = $false; WsaPackageFull = ''; Blockers = @(); Warnings = @()
    }
}

try {
    Show-LdMainWindow -Preflight $preflight
} catch {
    $msg = 'LiteDroid hit an unexpected error:' + "`r`n`r`n" + $_.Exception.Message + "`r`n`r`n" +
           $_.ScriptStackTrace + "`r`n`r`nLog: " + $script:LD.LogFile
    try { [System.Windows.Forms.MessageBox]::Show($msg, 'LiteDroid') | Out-Null } catch { Write-Host $msg }
    exit 4
}
exit 0
