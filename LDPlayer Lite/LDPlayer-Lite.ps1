# Configure an installed LDPlayer 9 with its documented ldconsole.exe interface.
# Does not patch LDPlayer binaries, registry, Windows virtualization or WSA.
$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host '  LDPlayer Lite — one-app mode' -ForegroundColor Cyan
Write-Host '  ----------------------------'

function Find-LdConsole {
    $paths = New-Object System.Collections.ArrayList
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA,
                         'C:\LDPlayer', 'D:\LDPlayer', 'C:\leidian', 'D:\leidian')) {
        if (-not $root) { continue }
        foreach ($sub in @('LDPlayer\LDPlayer9\ldconsole.exe', 'LDPlayer9\ldconsole.exe',
                           'LDPlayer\ldconsole.exe', 'leidian\LDPlayer9\ldconsole.exe',
                           'ldconsole.exe')) {
            [void]$paths.Add((Join-Path $root $sub))
        }
    }
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        foreach ($entry in @(Get-ItemProperty $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*LDPlayer*' })) {
            if ($entry.InstallLocation) { [void]$paths.Add((Join-Path $entry.InstallLocation 'ldconsole.exe')) }
        }
    }
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
    }
    return $null
}

$console = Find-LdConsole
if (-not $console) {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select ldconsole.exe inside your LDPlayer 9 installation'
    $dialog.Filter = 'LDPlayer console (ldconsole.exe)|ldconsole.exe'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $console = $dialog.FileName }
}
if (-not $console) {
    Write-Host 'LDPlayer 9 was not found. Install it from https://www.ldplayer.net/ first.' -ForegroundColor Yellow
    exit 2
}
Write-Host ('Found: ' + $console)
$instances = @(& $console list 2>&1)
if ($LASTEXITCODE -ne 0 -or -not $instances -or -not ($instances | Where-Object { $_.Trim() })) {
    Write-Host 'LDPlayer has no default instance yet. Open LDPlayer 9 once, then run this file again.' -ForegroundColor Yellow
    exit 3
}

Write-Host 'Closing only the default LDPlayer instance to apply light settings ...'
& $console quit --index 0 | Out-Null
Start-Sleep -Seconds 3
Write-Host 'Applying 2 CPU cores, 2048 MB RAM, and 720 x 1280 display ...'
& $console modify --index 0 --cpu 2 --memory 2048 --resolution 720,1280,240
if ($LASTEXITCODE -ne 0) { throw 'LDPlayer rejected the settings. No Android files were deleted.' }
Write-Host 'Starting LDPlayer ...'
& $console launch --index 0
if ($LASTEXITCODE -ne 0) { throw 'LDPlayer could not launch its default instance.' }

$parent = Split-Path -Parent $PSScriptRoot
$apk = Get-ChildItem -LiteralPath $parent -Filter 'YacineTV*.apk' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $apk) {
    $apk = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'YacineTV*.apk' -File -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($apk) {
    Write-Host ('Installing ' + $apk.Name + ' (the first boot may take a few minutes) ...')
    & $console installapp --index 0 --filename $apk.FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Automatic APK install did not succeed. Drag the APK into the LDPlayer window instead.' -ForegroundColor Yellow
        exit 4
    }
    Write-Host 'Install request sent. Open YacineTV inside LDPlayer to confirm it works.' -ForegroundColor Green
} else {
    Write-Host 'No YacineTV APK next to this folder. Drag your APK into the LDPlayer window.' -ForegroundColor Yellow
}
