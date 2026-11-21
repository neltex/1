<#
    LiteDroid - user interface
    --------------------------
    WinForms, drawn from PowerShell so there is nothing to install and the whole
    front-end costs a few MB of RAM while it is open (close it when you are done
    - the Android apps keep running).

    Design rule: every control is a stock WinForms control. No custom drawing, no
    embedded fonts, no images to load at startup. That keeps it fast and makes it
    impossible for a missing resource to break the window.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:LDUi = @{
    Bg      = [System.Drawing.Color]::FromArgb(17, 19, 24)
    Panel   = [System.Drawing.Color]::FromArgb(26, 29, 38)
    Panel2  = [System.Drawing.Color]::FromArgb(33, 37, 48)
    Text    = [System.Drawing.Color]::FromArgb(232, 235, 242)
    Muted   = [System.Drawing.Color]::FromArgb(138, 146, 162)
    Accent  = [System.Drawing.Color]::FromArgb(46, 204, 148)
    Warn    = [System.Drawing.Color]::FromArgb(240, 180, 60)
    Danger  = [System.Drawing.Color]::FromArgb(232, 92, 92)
    Font    = $null
    Mono    = $null
    Form    = $null
    List    = $null
    Icons   = $null
    Status  = $null
    LogBox  = $null
    Search  = $null
    Timer   = $null
    Tick    = 0
    Apps    = @()
    IconMap = @{}
    Busy    = $false
    AppRoot = (Split-Path -Parent $PSScriptRoot)
}

function Get-LdAppRoot {
    return $script:LDUi.AppRoot
}

#region small builders

function New-LdButton {
    param(
        [string]$Text,
        [int]$X, [int]$Y, [int]$W = 110, [int]$H = 30,
        [System.Drawing.Color]$Back,
        [switch]$Primary
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.Font = $script:LDUi.Font
    $b.ForeColor = $script:LDUi.Text
    if ($Primary) {
        $b.BackColor = $script:LDUi.Accent
        $b.ForeColor = [System.Drawing.Color]::FromArgb(10, 20, 16)
    } elseif ($Back) {
        $b.BackColor = $Back
    } else {
        $b.BackColor = $script:LDUi.Panel2
    }
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

function Set-LdStatus {
    param([string]$Text, [string]$Kind = 'info')
    if (-not $script:LDUi.Status) { return }
    $script:LDUi.Status.Text = $Text
    switch ($Kind) {
        'ok'   { $script:LDUi.Status.ForeColor = $script:LDUi.Accent }
        'warn' { $script:LDUi.Status.ForeColor = $script:LDUi.Warn }
        'err'  { $script:LDUi.Status.ForeColor = $script:LDUi.Danger }
        default { $script:LDUi.Status.ForeColor = $script:LDUi.Muted }
    }
    try { [System.Windows.Forms.Application]::DoEvents() } catch { }
}

function Add-LdUiLog {
    param([string]$Line, [string]$Level = 'INFO')
    if (-not $script:LDUi.LogBox) { return }
    $tb = $script:LDUi.LogBox
    if ($tb.TextLength -gt 20000) { $tb.Text = $tb.Text.Substring($tb.TextLength - 12000) }
    $tb.AppendText($Line + "`r`n")
    $tb.SelectionStart = $tb.TextLength
    $tb.ScrollToCaret()
    try { [System.Windows.Forms.Application]::DoEvents() } catch { }
}

#endregion

#region data

function Update-LdAppList {
    <#
        Rebuilds the ListView from the installed apps. Keeps icons cached so a
        refresh is cheap. -Filter applies the search box without touching Android.
    #>
    param([switch]$WithMemory, [string]$Filter = '')

    $list = $script:LDUi.List
    if (-not $list) { return }

    $selected = ''
    if ($list.SelectedItems.Count -gt 0) { $selected = [string]$list.SelectedItems[0].Tag }

    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        $apps = @()
        try {
            $apps = Get-LdInstalledApps
        } catch {
            Add-LdUiLog ("Could not list apps: " + $_.Exception.Message) 'ERR'
        }
        if ($WithMemory) {
            try { $apps = Update-LdAppMemory -Apps $apps } catch { }
        }

        $script:LDUi.Apps = $apps
        $defaultIcon = 0

        foreach ($a in $apps) {
            if ($Filter) {
                $hit = ($a.Label -like ('*' + $Filter + '*')) -or ($a.Package -like ('*' + $Filter + '*'))
                if (-not $hit) { continue }
            }
            $idx = $defaultIcon
            if ($a.IconPath -and $script:LDUi.IconMap.ContainsKey($a.IconPath)) {
                $idx = $script:LDUi.IconMap[$a.IconPath]
            } elseif ($a.IconPath -and ($a.IconPath -like '*.png')) {
                try {
                    $img = [System.Drawing.Image]::FromFile($a.IconPath)
                    $bmp = New-Object System.Drawing.Bitmap($img, 24, 24)
                    $img.Dispose()
                    [void]$script:LDUi.Icons.Images.Add($bmp)
                    $idx = $script:LDUi.Icons.Images.Count - 1
                    $script:LDUi.IconMap[$a.IconPath] = $idx
                } catch { }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($a.Label, $idx)
            [void]$item.SubItems.Add($a.Package)
            if ($a.MemoryKb -gt 0) {
                [void]$item.SubItems.Add((Format-LdKBytes $a.MemoryKb))
            } else {
                [void]$item.SubItems.Add('-')
            }
            $item.Tag = $a.Package
            [void]$list.Items.Add($item)
            if ($a.Package -eq $selected) { $item.Selected = $true }
        }
    } finally {
        $list.EndUpdate()
    }

    if ($script:LDUi.Apps.Count -eq 0) {
        Set-LdStatus 'No Android apps yet - drop an .apk on this window.' 'info'
    }
}

function Get-LdSelectedPackage {
    $list = $script:LDUi.List
    if (-not $list -or $list.SelectedItems.Count -eq 0) { return $null }
    return [string]$list.SelectedItems[0].Tag
}

function Get-LdSelectedLabel {
    $list = $script:LDUi.List
    if (-not $list -or $list.SelectedItems.Count -eq 0) { return '' }
    return $list.SelectedItems[0].Text
}

#endregion

#region actions

function Start-LdElevated {
    param([string]$ScriptPath, [string[]]$Arguments = @())

    $cmd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"' + $ScriptPath + '"'))
    foreach ($a in $Arguments) { $cmd += $a }

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $cmd -Verb RunAs -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Add-LdUiLog ('Could not start the elevated setup: ' + $_.Exception.Message) 'ERR'
        Set-LdStatus 'Administrator rights are required (UAC was declined).' 'err'
        return $false
    }
}

function Invoke-LdGuiInstallApk {
    param([string[]]$Paths)

    if ($script:LDUi.Busy) { return }
    $script:LDUi.Busy = $true
    try {
        Set-LdStatus ('Installing ' + (Split-Path -Leaf $Paths[0]) + ' ...') 'info'
        $script:LDUi.Form.UseWaitCursor = $true
        [System.Windows.Forms.Application]::DoEvents()

        $installed = @()
        try {
            $installed = Install-LdApk -Path $Paths -Launch:($Paths.Count -eq 1)
        } catch {
            Add-LdUiLog ('Install failed: ' + $_.Exception.Message) 'ERR'
            Set-LdStatus 'Install failed - see the log below.' 'err'
        }

        if ($installed -and $installed.Count -gt 0) {
            Set-LdStatus ('Installed ' + ($installed -join ', ')) 'ok'
        }
        Update-LdAppList -WithMemory
    } finally {
        $script:LDUi.Form.UseWaitCursor = $false
        $script:LDUi.Busy = $false
    }
}

#endregion

#region settings dialog

function Show-LdSettings {
    param([object]$Preflight)

    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'LiteDroid settings'
    $d.Size = New-Object System.Drawing.Size(460, 380)
    $d.StartPosition = 'CenterParent'
    $d.BackColor = $script:LDUi.Bg
    $d.ForeColor = $script:LDUi.Text
    $d.FormBorderStyle = 'FixedDialog'
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.Font = $script:LDUi.Font

    $cfg = Get-LdConfig

    $label = {
        param($text, $x, $y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.AutoSize = $true
        $l.ForeColor = $script:LDUi.Muted
        $l.Font = $script:LDUi.Font
        $d.Controls.Add($l)
        return $l
    }

    & $label 'RAM for Android' 20 24
    $memCombo = New-Object System.Windows.Forms.ComboBox
    $memCombo.DropDownStyle = 'DropDownList'
    $memCombo.Location = New-Object System.Drawing.Point(180, 20)
    $memCombo.Size = New-Object System.Drawing.Size(230, 24)
    $memCombo.FlatStyle = 'Flat'
    $memCombo.BackColor = $script:LDUi.Panel2
    $memCombo.ForeColor = $script:LDUi.Text
    foreach ($v in @(2048, 2560, 3072, 4096, 5120, 6144)) { [void]$memCombo.Items.Add([string]$v) }
    $autoMem = Resolve-LdMemoryMb -HostRamGb $Preflight.HostRamGb
    $curMem = [string]$cfg['MemoryMB']
    if ($curMem -eq '0' -or -not $curMem) { $curMem = [string]$autoMem }
    if ($memCombo.Items.Contains($curMem)) { $memCombo.SelectedItem = $curMem } else { $memCombo.SelectedItem = [string]$autoMem }
    $d.Controls.Add($memCombo)
    $hint = & $label ('suggested: ' + $autoMem + ' MB for ' + $Preflight.HostRamGb + ' GB host') 20 44
    $hint.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)

    & $label 'vCPUs' 20 76
    $coreCombo = New-Object System.Windows.Forms.ComboBox
    $coreCombo.DropDownStyle = 'DropDownList'
    $coreCombo.Location = New-Object System.Drawing.Point(180, 72)
    $coreCombo.Size = New-Object System.Drawing.Size(230, 24)
    $coreCombo.FlatStyle = 'Flat'
    $coreCombo.BackColor = $script:LDUi.Panel2
    $coreCombo.ForeColor = $script:LDUi.Text
    foreach ($v in @(2, 3, 4, 6, 8)) { [void]$coreCombo.Items.Add([string]$v) }
    $autoCores = Resolve-LdCores -LogicalCores $Preflight.LogicalCores
    $curCores = [string]$cfg['Cores']
    if ($curCores -eq '0' -or -not $curCores) { $curCores = [string]$autoCores }
    $coreCombo.SelectedItem = $curCores
    if (-not $coreCombo.SelectedItem) { $coreCombo.SelectedItem = [string]$autoCores }
    $d.Controls.Add($coreCombo)

    & $label 'Render surface' 20 128
    $screenCombo = New-Object System.Windows.Forms.ComboBox
    $screenCombo.DropDownStyle = 'DropDownList'
    $screenCombo.Location = New-Object System.Drawing.Point(180, 124)
    $screenCombo.Size = New-Object System.Drawing.Size(230, 24)
    $screenCombo.FlatStyle = 'Flat'
    $screenCombo.BackColor = $script:LDUi.Panel2
    $screenCombo.ForeColor = $script:LDUi.Text
    foreach ($v in @('native', '1080p', '720p')) { [void]$screenCombo.Items.Add($v) }
    $screenCombo.SelectedItem = [string]$cfg['ScreenMode']
    if (-not $screenCombo.SelectedItem) { $screenCombo.SelectedItem = 'native' }
    $d.Controls.Add($screenCombo)

    $chkGpu = New-Object System.Windows.Forms.CheckBox
    $chkGpu.Text = 'Hardware GPU acceleration (recommended - much faster)'
    $chkGpu.Location = New-Object System.Drawing.Point(22, 166)
    $chkGpu.Size = New-Object System.Drawing.Size(400, 24)
    $chkGpu.ForeColor = $script:LDUi.Text
    $chkGpu.Checked = [bool]$cfg['EnableGpu']
    $d.Controls.Add($chkGpu)

    $chkAnim = New-Object System.Windows.Forms.CheckBox
    $chkAnim.Text = 'Turn off Android animations (snappier)'
    $chkAnim.Location = New-Object System.Drawing.Point(22, 192)
    $chkAnim.Size = New-Object System.Drawing.Size(400, 24)
    $chkAnim.ForeColor = $script:LDUi.Text
    $chkAnim.Checked = [bool]$cfg['DisableAnimations']
    $d.Controls.Add($chkAnim)

    $chkBloat = New-Object System.Windows.Forms.CheckBox
    $chkBloat.Text = 'Disable unused system packages (print, telemetry...)'
    $chkBloat.Location = New-Object System.Drawing.Point(22, 218)
    $chkBloat.Size = New-Object System.Drawing.Size(400, 24)
    $chkBloat.ForeColor = $script:LDUi.Text
    $chkBloat.Checked = [bool]$cfg['DisableBloat']
    $d.Controls.Add($chkBloat)

    $note = New-Object System.Windows.Forms.Label
    $note.Text = 'RAM and vCPU changes apply the next time the Android runtime boots.'
    $note.Location = New-Object System.Drawing.Point(22, 250)
    $note.Size = New-Object System.Drawing.Size(410, 32)
    $note.ForeColor = $script:LDUi.Muted
    $note.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
    $d.Controls.Add($note)

    $save = New-LdButton -Text 'Save' -X 240 -Y 296 -W 90 -Primary
    $save.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $d.Controls.Add($save)
    $cancel = New-LdButton -Text 'Cancel' -X 340 -Y 296 -W 90
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $d.Controls.Add($cancel)
    $d.AcceptButton = $save
    $d.CancelButton = $cancel

    if ($d.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $cfg['MemoryMB'] = [int]$memCombo.SelectedItem
    $cfg['Cores'] = [int]$coreCombo.SelectedItem
    $cfg['ScreenMode'] = [string]$screenCombo.SelectedItem
    $cfg['EnableGpu'] = [bool]$chkGpu.Checked
    $cfg['DisableAnimations'] = [bool]$chkAnim.Checked
    $cfg['DisableBloat'] = [bool]$chkBloat.Checked
    Save-LdConfig -Config $cfg

    # RAM/vCPU live in the subsystem's own settings file
    Set-LdResourceLimits -MemoryMb $cfg['MemoryMB'] -Cores $cfg['Cores'] -EnableGpu $cfg['EnableGpu'] | Out-Null

    # the rest are applied live if Android is running
    if (Test-LdAdbDevice) {
        Set-LdStatus 'Applying settings ...' 'info'
        [void](Invoke-LdTuning -Options @{
            DisableAnimations = $cfg['DisableAnimations']
            ScreenMode        = $cfg['ScreenMode']
            DisableBloat      = $cfg['DisableBloat']
            CachedAppsFreezer = $cfg['CachedAppsFreezer']
        })
        Set-LdStatus 'Settings applied.' 'ok'
    } else {
        Set-LdStatus 'Saved. RAM/vCPU apply at the next runtime start.' 'ok'
    }
}

#endregion

#region main window

function Show-LdMainWindow {
    param([object]$Preflight)

    $script:LDUi.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:LDUi.Mono = New-Object System.Drawing.Font('Consolas', 8)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'LiteDroid'
    $form.Size = New-Object System.Drawing.Size(1020, 700)
    $form.MinimumSize = New-Object System.Drawing.Size(820, 520)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $script:LDUi.Bg
    $form.ForeColor = $script:LDUi.Text
    $form.Font = $script:LDUi.Font
    $form.AllowDrop = $true
    $script:LDUi.Form = $form

    # ---------------------------------------------------------------- header
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 62
    $header.BackColor = $script:LDUi.Panel
    $form.Controls.Add($header)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'LiteDroid'
    $title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
    $title.ForeColor = $script:LDUi.Text
    $title.Location = New-Object System.Drawing.Point(18, 8)
    $title.AutoSize = $true
    $header.Controls.Add($title)

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = 'Android apps as native Windows windows - minimal footprint'
    $sub.ForeColor = $script:LDUi.Muted
    $sub.Location = New-Object System.Drawing.Point(20, 36)
    $sub.AutoSize = $true
    $sub.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $header.Controls.Add($sub)

    $vmNow = Get-LdVmProcess
    $stateText = 'IDLE  0 MB'
    if ($vmNow) { $stateText = 'RUNNING  ' + (Format-LdSize ([math]::Round($vmNow.WorkingSet64 / 1MB, 0))) }

    $stateLbl = New-Object System.Windows.Forms.Label
    $stateLbl.Text = $stateText
    $stateLbl.AutoSize = $false
    $stateLbl.TextAlign = 'MiddleRight'
    $stateLbl.Size = New-Object System.Drawing.Size(240, 24)
    $stateLbl.Location = New-Object System.Drawing.Point(740, 10)
    $stateLbl.Anchor = 'Top,Right'
    $stateLbl.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    $stateLbl.ForeColor = $script:LDUi.Accent
    $header.Controls.Add($stateLbl)
    $script:LDUi.StateLabel = $stateLbl

    # --------------------------------------------------------------- toolbar
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Top'
    $bar.Height = 48
    $bar.BackColor = $script:LDUi.Bg
    $form.Controls.Add($bar)

    $btnInstall = New-LdButton -Text 'Install APK...' -X 16 -Y 8 -W 120 -Primary
    $bar.Controls.Add($btnInstall)

    $btnOpen = New-LdButton -Text 'Open' -X 144 -Y 8 -W 76
    $bar.Controls.Add($btnOpen)

    $btnStop = New-LdButton -Text 'Stop' -X 226 -Y 8 -W 66
    $bar.Controls.Add($btnStop)

    $btnShortcut = New-LdButton -Text 'Shortcut' -X 298 -Y 8 -W 86
    $bar.Controls.Add($btnShortcut)

    $btnUninstall = New-LdButton -Text 'Uninstall' -X 390 -Y 8 -W 84
    $bar.Controls.Add($btnUninstall)

    $btnRefresh = New-LdButton -Text 'Refresh' -X 480 -Y 8 -W 78
    $bar.Controls.Add($btnRefresh)

    $btnHibernate = New-LdButton -Text 'Hibernate all' -X 660 -Y 8 -W 110
    $btnHibernate.Anchor = 'Top,Right'
    $bar.Controls.Add($btnHibernate)

    $btnSettings = New-LdButton -Text 'Settings' -X 776 -Y 8 -W 78
    $btnSettings.Anchor = 'Top,Right'
    $bar.Controls.Add($btnSettings)

    $btnSetup = New-LdButton -Text 'Repair / Install' -X 860 -Y 8 -W 130
    $btnSetup.Anchor = 'Top,Right'
    $bar.Controls.Add($btnSetup)

    # ----------------------------------------------------------------- search
    $search = New-Object System.Windows.Forms.TextBox
    $search.Location = New-Object System.Drawing.Point(16, 104)
    $search.Size = New-Object System.Drawing.Size(300, 24)
    $search.BackColor = $script:LDUi.Panel
    $search.ForeColor = $script:LDUi.Muted
    $search.BorderStyle = 'FixedSingle'
    $search.Text = 'Search apps...'
    $search.Anchor = 'Top,Left'
    $form.Controls.Add($search)
    $script:LDUi.Search = $search

    $search.Add_GotFocus({ if ($script:LDUi.Search.Text -eq 'Search apps...') { $script:LDUi.Search.Text = ''; $script:LDUi.Search.ForeColor = $script:LDUi.Text } })
    $search.Add_LostFocus({
        if ([string]::IsNullOrWhiteSpace($script:LDUi.Search.Text)) {
            $script:LDUi.Search.Text = 'Search apps...'
            $script:LDUi.Search.ForeColor = $script:LDUi.Muted
        }
    })
    $search.Add_TextChanged({
        $q = $script:LDUi.Search.Text
        if ($q -eq 'Search apps...') { $q = '' }
        Update-LdAppList -Filter $q
    })

    # ------------------------------------------------------------------ list
    $icons = New-Object System.Windows.Forms.ImageList
    $icons.ImageSize = New-Object System.Drawing.Size(24, 24)
    $icons.ColorDepth = 'Depth32Bit'
    $script:LDUi.Icons = $icons
    try {
        $client = Get-LdWsaClientPath
        if ($client) {
            $ic = [System.Drawing.Icon]::ExtractAssociatedIcon($client)
            if ($ic) { $icons.Images.Add($ic.ToBitmap()) }
        }
    } catch { }
    while ($icons.Images.Count -lt 1) {
        $bmp = New-Object System.Drawing.Bitmap(24, 24)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear($script:LDUi.Panel2)
        $g.Dispose()
        $icons.Images.Add($bmp)
    }

    $list = New-Object System.Windows.Forms.ListView
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.HideSelection = $false
    $list.MultiSelect = $false
    $list.SmallImageList = $icons
    $list.BackColor = $script:LDUi.Panel
    $list.ForeColor = $script:LDUi.Text
    $list.BorderStyle = 'None'
    $list.Location = New-Object System.Drawing.Point(16, 134)
    $list.Size = New-Object System.Drawing.Size(974, 356)
    $list.Anchor = 'Top,Left,Right,Bottom'
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    [void]$list.Columns.Add('App', 380)
    [void]$list.Columns.Add('Package', 400)
    [void]$list.Columns.Add('Memory', 110)
    $form.Controls.Add($list)
    $script:LDUi.List = $list

    # ------------------------------------------------------------------- log
    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ScrollBars = 'Vertical'
    $log.ReadOnly = $true
    $log.BackColor = $script:LDUi.Panel
    $log.ForeColor = $script:LDUi.Muted
    $log.BorderStyle = 'None'
    $log.Font = $script:LDUi.Mono
    $log.Location = New-Object System.Drawing.Point(16, 500)
    $log.Size = New-Object System.Drawing.Size(974, 96)
    $log.Anchor = 'Left,Right,Bottom'
    $form.Controls.Add($log)
    $script:LDUi.LogBox = $log

    # ---------------------------------------------------------------- status
    $status = New-Object System.Windows.Forms.Label
    $status.Text = 'Ready.'
    $status.Location = New-Object System.Drawing.Point(18, 610)
    $status.Size = New-Object System.Drawing.Size(820, 22)
    $status.Anchor = 'Left,Right,Bottom'
    $status.ForeColor = $script:LDUi.Muted
    $status.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $form.Controls.Add($status)
    $script:LDUi.Status = $status

    $stats = New-Object System.Windows.Forms.Label
    $stats.Text = ''
    $stats.Location = New-Object System.Drawing.Point(620, 610)
    $stats.Size = New-Object System.Drawing.Size(380, 22)
    $stats.TextAlign = 'MiddleRight'
    $stats.Anchor = 'Right,Bottom'
    $stats.ForeColor = $script:LDUi.Muted
    $stats.Font = New-Object System.Drawing.Font('Consolas', 8)
    $form.Controls.Add($stats)
    $script:LDUi.Stats = $stats

    # --------------------------------------------------------------- wiring
    $form.Add_DragEnter({
        param($sender, $e)
        if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
            foreach ($f in $files) {
                if ($f -like '*.apk') { $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy; return }
            }
        }
        $e.Effect = [System.Windows.Forms.DragDropEffects]::None
    })
    $form.Add_DragDrop({
        param($sender, $e)
        $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        $apks = @()
        foreach ($f in $files) { if ($f -like '*.apk') { $apks += $f } }
        if ($apks.Count -gt 0) { Invoke-LdGuiInstallApk -Paths $apks }
    })

    $btnInstall.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Android packages (*.apk)|*.apk|All files (*.*)|*.*'
        $dlg.Multiselect = $true
        $dlg.Title = 'Pick one or more APKs'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Invoke-LdGuiInstallApk -Paths $dlg.FileNames
        }
    })

    $list.Add_DoubleClick({
        $pkg = Get-LdSelectedPackage
        if ($pkg) { Launch-LdApp -Package $pkg | Out-Null }
    })

    $btnOpen.Add_Click({
        $pkg = Get-LdSelectedPackage
        if (-not $pkg) { Set-LdStatus 'Select an app first.' 'warn'; return }
        Launch-LdApp -Package $pkg | Out-Null
        Set-LdStatus ('Opened ' + (Get-LdSelectedLabel)) 'ok'
    })

    $btnStop.Add_Click({
        $pkg = Get-LdSelectedPackage
        if (-not $pkg) { Set-LdStatus 'Select an app first.' 'warn'; return }
        Stop-LdApp -Package $pkg
        Set-LdStatus ('Stopped ' + (Get-LdSelectedLabel)) 'ok'
        Update-LdAppList -WithMemory
    })

    $btnShortcut.Add_Click({
        $pkg = Get-LdSelectedPackage
        if (-not $pkg) { Set-LdStatus 'Select an app first.' 'warn'; return }
        $p = Add-LdDesktopShortcut -Package $pkg -Label (Get-LdSelectedLabel)
        if ($p) { Set-LdStatus ('Desktop shortcut created: ' + (Split-Path -Leaf $p)) 'ok' }
        else { Set-LdStatus 'Could not create the shortcut - see log.' 'err' }
    })

    $btnUninstall.Add_Click({
        $pkg = Get-LdSelectedPackage
        if (-not $pkg) { Set-LdStatus 'Select an app first.' 'warn'; return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Uninstall " + (Get-LdSelectedLabel) + '?'), 'LiteDroid',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Uninstall-LdApp -Package $pkg)
            Set-LdStatus ('Uninstalled ' + $pkg) 'ok'
            Update-LdAppList
        }
    })

    $btnRefresh.Add_Click({ Update-LdAppList -WithMemory; Set-LdStatus 'List refreshed.' 'info' })

    $btnHibernate.Add_Click({
        Set-LdStatus 'Hibernating Android apps ...' 'info'
        $script:LDUi.Form.UseWaitCursor = $true
        try { Stop-LdAllApps } catch { }
        $script:LDUi.Form.UseWaitCursor = $false
        Start-Sleep -Milliseconds 700
        $r = Get-LdMemoryReport
        Set-LdStatus ('Idle. Android VM: ' + (Format-LdSize $r.VmMb)) 'ok'
        Update-LdAppList
    })

    $btnSettings.Add_Click({ Show-LdSettings -Preflight $Preflight })

    $btnSetup.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "This opens an administrator window that repairs or reinstalls the Android runtime.`r`n`r`nContinue?",
            'LiteDroid', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $root = Get-LdAppRoot
        [void](Start-LdElevated -ScriptPath (Join-Path $root 'Setup.ps1') -Arguments @())
    })

    # ----------------------------------------------------------- live stats
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 4000
    $timer.Add_Tick({
        $script:LDUi.Tick = $script:LDUi.Tick + 1
        try {
            $vm = Get-LdVmProcess
            if ($vm) {
                $script:LDUi.StateLabel.Text = ('RUNNING  ' + (Format-LdSize ([math]::Round($vm.WorkingSet64 / 1MB, 0))))
                $script:LDUi.StateLabel.ForeColor = $script:LDUi.Accent
            } else {
                $script:LDUi.StateLabel.Text = 'IDLE  0 MB'
                $script:LDUi.StateLabel.ForeColor = $script:LDUi.Muted
            }

            $free = 0
            try {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $free = [math]::Round($os.FreePhysicalMemory / 1024, 0)
            } catch { }
            $script:LDUi.Stats.Text = ('Windows free: ' + (Format-LdSize $free))

            # per-app memory is expensive (one dumpsys round trip): every ~40 s
            if ($vm -and ($script:LDUi.Tick % 10 -eq 0) -and -not $script:LDUi.Busy) {
                Update-LdAppList -WithMemory
            }
        } catch { }
    })
    $timer.Start()
    $script:LDUi.Timer = $timer

    $form.Add_FormClosing({
        $script:LDUi.Timer.Stop()
        $script:LDUi.Timer.Dispose()
        # Closing LiteDroid means stop its Android processes too; otherwise
        # WsaClient can hold the extracted runtime directory open indefinitely.
        try { Stop-LdWsa -Force } catch { }
    })

    # ------------------------------------------------------------ bootstrap
    Register-LdLogSink { param($line, $level) Add-LdUiLog $line $level }

    Add-LdUiLog ('LiteDroid ' + $script:LD.Version) 'INFO'
    Add-LdUiLog ('Windows build ' + $Preflight.Build + ' | ' + $Preflight.HostRamGb + ' GB RAM | ' + $Preflight.LogicalCores + ' threads') 'INFO'

    if (-not $Preflight.WsaInstalled) {
        Add-LdUiLog 'The Android runtime is not installed yet.' 'WARN'
        Set-LdStatus 'Not installed - click "Repair / Install" to set up LiteDroid.' 'warn'
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "LiteDroid needs to install its Android runtime once (about 550 MB download, needs a reboot if virtualization features are off).`r`n`r`nRun the installer now?",
            'LiteDroid', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            [void](Start-LdElevated -ScriptPath (Join-Path (Get-LdAppRoot) 'Setup.ps1') -Arguments @())
        }
    } else {
        Add-LdUiLog ('Runtime installed: ' + $Preflight.WsaPackageFull) 'INFO'
        Update-LdAppList -WithMemory
        if (Test-LdAdbDevice) {
            Set-LdStatus 'Runtime reachable.' 'ok'
        } else {
            Set-LdStatus 'Runtime installed but asleep - open any app to wake it.' 'info'
        }
    }

    [void]$form.ShowDialog()
}

#endregion
