# Stop only processes associated with LiteDroid's install and runtime.
# Does not uninstall WSA or delete the saved 530 MB archive.
$ErrorActionPreference = 'Continue'
Write-Host 'Closing LiteDroid and releasing its files ...'
$me = $PID
try {
    $adb = 'C:\LiteDroid\tools\platform-tools\adb.exe'
    if (Test-Path -LiteralPath $adb) { & $adb -P 5038 kill-server 2>$null | Out-Null }
} catch { }

# PowerShell processes started by the app or its installer can remain alive
# after the window has disappeared (especially older -NoExit installers).
try {
    $owners = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop |
        Where-Object {
            $_.ProcessId -ne $me -and $_.CommandLine -match '(?i)(?:LiteDroid\.ps1|LiteDroid[\\/]Setup\.ps1)'
        })
    foreach ($proc in $owners) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Host ("Closed LiteDroid PowerShell process " + $proc.ProcessId)
        } catch { Write-Host ("Could not close process " + $proc.ProcessId + ': ' + $_.Exception.Message) }
    }
} catch { Write-Host ("Could not inspect PowerShell processes: " + $_.Exception.Message) }

foreach ($name in @('WsaClient','WsaSettings','WsaService','WsaHost','vmmemWSA')) {
    foreach ($proc in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop }
        catch { Write-Host ("Could not close " + $name + ': ' + $_.Exception.Message) }
    }
}
try {
    $svc = Get-Service -Name WsaService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { Stop-Service WsaService -Force -ErrorAction Stop }
} catch { Write-Host ('Could not stop WsaService: ' + $_.Exception.Message) }
Write-Host 'Done. Close any DLL error popups, then delete the old extracted ZIP folder if you want.'
Write-Host 'Do not delete C:\LiteDroid\downloads - that contains your saved Android image.'
