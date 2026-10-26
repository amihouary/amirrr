# Instance manager UI. WinForms ships with Windows, so there is nothing to install.
# All the actual work lives in android.ps1 - this window only calls it, so every button
# here has an equivalent command line. Paths, device profiles and the requirements check
# are shared with it through common.ps1.
#
#   manager.ps1              open the window
#   manager.ps1 -SelfTest    no window: list the instances, print the requirements, assert
#                            the identity rules, and dry-run every button
#   manager.ps1 -Logs wa01   open only the log viewer, on that instance (see logs.bat)
#
# Four buttons are worth knowing about before the rest:
#   Requirements  what is installed / missing / too slow here, with the fix for each and a
#                 button that downloads the missing SDK parts
#   Settings      where the SDK, the JDK and the instances live -> settings.ini
#   New           asks what kind of device the instance should look like (screen, region,
#                 SIM number, RAM); Identity asks the same for an existing one
#   Screen scan   drag a rectangle on THIS screen and every instance's camera shows it, so
#                 a WhatsApp Web QR on the monitor can be scanned from inside the guests
#                 (android.ps1 -PickRegion). Click it again to re-pick or switch it off.
# Group > Install app takes a plain .apk or a whole .xapk / .apks / .apkm bundle.

param(
    [switch] $SelfTest,
    [string] $Logs,
    # One dialog on its own, without the instance list. -SelfTest can only dry-run the
    # code that decides what to do; a WinForms layout is only ever proved by opening it,
    # so this is how each new dialog gets smoke-tested (and it is a fine shortcut too).
    [ValidateSet('', 'requirements', 'settings', 'new', 'group')]
    [string] $Dialog = ''
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$ErrorActionPreference = 'Stop'

# manager.bat launches this with -WindowStyle Hidden, so without this trap any failure
# before the window opens is completely silent: no console, no form, nothing to read.
trap {
    if (-not $SelfTest) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)",
            'Android instances - startup failed', 'OK', 'Error')
    }
    break
}

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$engine = Join-Path $here 'android.ps1'
if (-not (Test-Path $engine)) { throw "android.ps1 not found next to this script" }

# Paths, the device/region profile lists and the requirements check are shared with the
# engine, so this window can never offer a device android.ps1 does not know or look for the
# instances in a different folder than the one that boots them.
. (Join-Path $here 'common.ps1')

# Read once into script scope; the Settings dialog reassigns both after a save.
$Settings = Get-Settings
$AvdHome  = $Settings.AvdHome
$adb      = Join-Path $Settings.SdkRoot 'platform-tools\adb.exe'

$script:DryRun = [bool] $SelfTest

# manager.bat runs this hidden, so until now the window itself logged NOTHING: "the group
# screen hangs" arrived with no evidence at all, while every android.ps1 run had a transcript.
# Same pattern as the engine: one file, 4 MB rollover, a per-process fallback when a second
# window cannot append, and never a reason to refuse to open.
$LogDir = Join-Path $here 'logs'
if (-not $SelfTest) {
    try {
        New-Item -ItemType Directory -Force $LogDir | Out-Null
        $ManagerLog = Join-Path $LogDir '_manager.log'
        if ((Test-Path $ManagerLog) -and (Get-Item $ManagerLog).Length -gt 4MB) {
            Move-Item -LiteralPath $ManagerLog -Destination "$ManagerLog.1" -Force -ErrorAction SilentlyContinue
        }
        try { Start-Transcript -LiteralPath $ManagerLog -Append -Force | Out-Null }
        catch { try { Start-Transcript -LiteralPath (Join-Path $LogDir "_manager.$PID.log") -Append -Force | Out-Null } catch { } }
        Write-Log "=== manager : $(if ($Dialog) { "-Dialog $Dialog" } elseif ($Logs) { "-Logs $Logs" } else { 'window' })"
    } catch { }
}

# userdata-qemu.img is a SPARSE 6 GB file that occupies ~100 MB. FileInfo.Length reports
# the 6 GB hole as if it were on the disk, which made this window claim ~10 GB for an
# instance that really costs 4.6 - and "how do I save space" is unanswerable while the
# number is wrong. GetCompressedFileSize is the only API that returns allocated bytes.
Add-Type -Namespace Fs -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetCompressedFileSizeW(string name, out uint high);
'@

function Get-OnDiskBytes([string] $dir) {
    $total = [long] 0
    foreach ($f in (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue)) {
        $high = 0
        $low  = [Fs.Native]::GetCompressedFileSizeW($f.FullName, [ref] $high)
        # 0xFFFFFFFF is the documented failure marker; fall back to the logical size.
        if ($low -eq [uint32]::MaxValue) { $total += $f.Length }
        else { $total += ([long]$high -shl 32) + $low }
    }
    return $total
}

# ---------------------------------------------------------------------- helpers
# -Fast = names, ports and profiles only: no `adb devices` (which starts the adb server if it
# is not up: seconds) and no per-instance disk walk. Get-OnDiskBytes recurses a multi-GB AVD
# folder and calls GetCompressedFileSizeW per file, on a 7200 rpm SMR disk with a cold cache -
# that is what made the group screen take many seconds to open, and it needs neither number:
# it reads the name and the phone number, and asks the WINDOW list whether an instance is up.
function Get-Instances([switch] $Fast) {
    $running = @{}
    if (-not $Fast -and (Test-Path $adb)) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            foreach ($line in (& $adb devices 2>&1)) {
                if ("$line" -match 'emulator-(\d+)\s+(\w+)') { $running[[int]$Matches[1]] = $Matches[2] }
            }
        } finally { $ErrorActionPreference = $prev }
    }

    if (-not (Test-Path $AvdHome)) { return @() }

    foreach ($dir in (Get-ChildItem $AvdHome -Filter '*.avd' -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        # NOT $dir.BaseName: PowerShell only strips the extension for files, so on a
        # DirectoryInfo it hands back "wa01.avd" and every downstream -Name lookup fails.
        $name = $dir.Name -replace '\.avd$', ''

        $cfg = Join-Path $dir.FullName 'config.ini'
        $ram = ''; $cores = ''; $res = ''
        if (Test-Path $cfg) {
            foreach ($l in Get-Content $cfg) {
                if ($l -match '^\s*hw\.ramSize\s*=\s*(\S+)')   { $ram   = $Matches[1] }
                if ($l -match '^\s*hw\.cpu\.ncore\s*=\s*(\S+)') { $cores = $Matches[1] }
                if ($l -match '^\s*skin\.name\s*=\s*(\S+)')     { $res   = $Matches[1] }
            }
        }
        # identity.ini is written by android.ps1 (Get-Identity). Read, never generated
        # here: one owner for the format, and a missing file just means "not booted yet".
        $idFile = Join-Path $dir.FullName 'identity.ini'
        $device = ''; $number = ''
        if (Test-Path $idFile) {
            foreach ($l in (Get-Content $idFile -ErrorAction SilentlyContinue)) {
                if ($l -match '^\s*Device\s*=\s*(.+?)\s*$') { $device = $Matches[1] }
                if ($l -match '^\s*Phone\s*=\s*(.+?)\s*$')  { $number = $Matches[1] }
            }
        }
        $portFile = Join-Path $dir.FullName 'port.txt'
        $port     = if (Test-Path $portFile) { [int](Get-Content $portFile -First 1).Trim() } else { 0 }
        $gb       = if ($Fast) { 0 } else { [math]::Round((Get-OnDiskBytes $dir.FullName) / 1GB, 2) }
        $snap     = if (Test-Path (Join-Path $dir.FullName 'snapshots\default_boot')) { 'yes' } else { 'no' }
        $state    = if ($port -and $running.ContainsKey($port)) { $running[$port] } else { 'off' }

        [pscustomobject]@{
            Name = $name; Port = $port; Ram = $ram; Cores = $cores; Res = $res
            GB = $gb; Snapshot = $snap; State = $state
            Device = $device; Number = $number
            Launcher = (Test-Path (Join-Path $here "run-$name.bat"))
        }
    }
}

# No window at all: -WindowStyle Hidden and no -NoExit. Every button used to leave a
# PowerShell console open, which is what the ask was about; the engine now appends
# everything it would have printed to logs\<instance>.log, and the Logs button below
# tails that live. A failed run still raises a dialog of its own.
#
# Start-Process joins -ArgumentList with single spaces and quotes NOTHING, so an array
# element is not an argument boundary. This folder is "andriod sum", so the unquoted
# engine path reached powershell.exe as "-File C:\...\andriod" plus a stray "sum\..."
# and it died before running a line - that is the "a PowerShell window opens and
# nothing happens" every button had. Quote here, or the split comes back.
function Get-EngineArgs([string[]] $argv, [bool] $hidden = $true) {
    $all = @('-ExecutionPolicy', 'Bypass', '-NoProfile')
    # A download that runs for minutes is the one case where a console is the point, and
    # -NoExit keeps its output readable after sdkmanager finishes.
    if ($hidden) { $all += @('-WindowStyle', 'Hidden') } else { $all += '-NoExit' }
    $all += @('-File', $engine) + $argv
    return @($all | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { "$_" } })
}

function Invoke-Engine([string[]] $argv, [switch] $Visible) {
    if ($script:DryRun) {
        Write-Host "    would run: android.ps1 $($argv -join ' ')$(if ($Visible) { '   (in a visible window)' })" -ForegroundColor DarkGray
        return
    }
    if ($Visible) { Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-EngineArgs $argv $false) }
    else          { Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-EngineArgs $argv) -WindowStyle Hidden }
}

# ---------------------------------------------------------------------- log viewer
# $LogDir is set with the transcript above.

# Share-tolerant on purpose: the emulator holds its own redirected log open for writing,
# and plain Get-Content fails with "being used by another process" on exactly the file
# that explains a stalled boot.
function Get-LogTail([string] $path, [int] $lines = 800) {
    if (-not (Test-Path $path)) { return "(nothing logged yet)`r`n$path" }
    $text = ''
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return "(cannot read the file: $($_.Exception.Message))`r`n$path" }
    $all = $text -split "`r?`n"
    # A log file ends with a newline, so the split leaves an empty last element - which
    # would silently cost one real line of the tail and put a blank row at the bottom.
    if ($all.Count -gt 1 -and $all[-1] -eq '') { $all = $all[0..($all.Count - 2)] }
    if ($all.Count -le $lines) { return ($all -join "`r`n") }
    return (($all[($all.Count - $lines)..($all.Count - 1)]) -join "`r`n")
}

function Show-LogViewer([string] $prefer) {
    if ($script:DryRun) { Write-Host "    would open the log viewer for '$prefer'" -ForegroundColor DarkGray; return }
    New-Item -ItemType Directory -Force $LogDir | Out-Null

    $f               = New-Object System.Windows.Forms.Form
    $f.Text          = "Logs - $LogDir"
    $f.Size          = New-Object System.Drawing.Size(1020, 660)
    $f.MinimumSize   = New-Object System.Drawing.Size(640, 320)
    $f.StartPosition = 'CenterScreen'

    $combo               = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.Location      = New-Object System.Drawing.Point(12, 12)
    $combo.Size          = New-Object System.Drawing.Size(330, 24)
    $f.Controls.Add($combo)

    $follow         = New-Object System.Windows.Forms.CheckBox
    $follow.Text    = 'follow'
    $follow.Checked = $true
    $follow.Location = New-Object System.Drawing.Point(352, 13)
    $follow.Size    = New-Object System.Drawing.Size(66, 22)
    $f.Controls.Add($follow)

    $only         = New-Object System.Windows.Forms.CheckBox
    $only.Text    = 'problems only'
    $only.Location = New-Object System.Drawing.Point(420, 13)
    $only.Size    = New-Object System.Drawing.Size(110, 22)
    $f.Controls.Add($only)

    $box            = New-Object System.Windows.Forms.RichTextBox
    $box.ReadOnly   = $true
    $box.WordWrap   = $false
    $box.Font       = New-Object System.Drawing.Font('Consolas', 9)
    $box.Location   = New-Object System.Drawing.Point(12, 44)
    $box.Size       = New-Object System.Drawing.Size(980, 570)
    $box.Anchor     = 'Top,Left,Bottom,Right'
    $box.BackColor  = [System.Drawing.Color]::White
    $f.Controls.Add($box)

    foreach ($b in @(@{ T = 'Folder'; X = 780 }, @{ T = 'Clear'; X = 890 })) {
        $btn          = New-Object System.Windows.Forms.Button
        $btn.Text     = $b.T
        $btn.Tag      = $b.T
        $btn.Location = New-Object System.Drawing.Point($b.X, 11)
        $btn.Size     = New-Object System.Drawing.Size(100, 26)
        $btn.Anchor   = 'Top,Right'
        $btn.Add_Click({
            if ([string]$this.Tag -eq 'Folder') { Start-Process explorer.exe ('"' + $LogDir + '"'); return }
            $sel = "$($combo.SelectedItem)"
            if (-not $sel) { return }
            if ([System.Windows.Forms.MessageBox]::Show("Empty $sel ?", 'Clear log', 'YesNo', 'Warning') -eq 'Yes') {
                # Truncate rather than delete: a running emulator has the file open, and
                # deleting it would leave its handle writing into nothing.
                try { Set-Content -LiteralPath (Join-Path $LogDir $sel) -Value '' -ErrorAction Stop }
                catch { [void][System.Windows.Forms.MessageBox]::Show("in use: $($_.Exception.Message)", 'Clear log') }
            }
        })
        $f.Controls.Add($btn)
    }

    # Files are listed by name so an instance is where you expect it, and reloaded only
    # when the file actually changed - a 4 MB log re-read every second for nothing would
    # make the viewer itself a load problem.
    $seen = @{ Name = ''; Stamp = [datetime]::MinValue; Size = -1L; Only = $false }

    $load = {
        foreach ($n in @(Get-ChildItem $LogDir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object Name)) {
            if (-not $combo.Items.Contains($n)) { [void]$combo.Items.Add($n) }
        }
        if ($combo.Items.Count -eq 0) { $box.Text = "no logs in $LogDir yet"; return }
        if (-not $combo.SelectedItem) {
            $want = "$prefer.log"
            $combo.SelectedItem = $(if ($combo.Items.Contains($want)) { $want } else { $combo.Items[0] })
        }

        $name = "$($combo.SelectedItem)"
        $path = Join-Path $LogDir $name
        $fi   = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        $stamp = if ($fi) { $fi.LastWriteTimeUtc } else { [datetime]::MinValue }
        $size  = if ($fi) { $fi.Length } else { -1L }
        if ($name -eq $seen.Name -and $stamp -eq $seen.Stamp -and $size -eq $seen.Size -and $only.Checked -eq $seen.Only) { return }
        $seen.Name = $name; $seen.Stamp = $stamp; $seen.Size = $size; $seen.Only = $only.Checked

        # LF only, never CRLF: a RichTextBox stores \n internally, so text assigned with
        # \r\n makes every regex offset below drift by one per line and the colouring
        # lands on the wrong rows further down the file.
        $text = (Get-LogTail $path) -replace "`r`n", "`n"
        if ($only.Checked) {
            $text = (($text -split "`n" | Where-Object { $_ -match '\[(ERROR|WARN)' -or $_ -match 'FATAL|-> ' }) -join "`n")
            if (-not $text) { $text = '(no warnings or errors in this log)' }
        }
        $box.Text = $text
        # Colour after setting the text, and only the lines that matter, so a long log
        # does not repaint character by character.
        $i = 0
        foreach ($m in [regex]::Matches($text, '^.*\[(ERROR|WARN)\s*\].*$', 'Multiline')) {
            if ($i -ge 400) { break }
            $box.Select($m.Index, $m.Length)
            $box.SelectionColor = $(if ($m.Groups[1].Value -eq 'ERROR') { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DarkOrange })
            $i++
        }
        $box.Select($box.TextLength, 0)
        if ($follow.Checked) { $box.SelectionStart = $box.TextLength; $box.ScrollToCaret() }
    }

    $combo.Add_SelectedIndexChanged({ $seen.Name = ''; & $load })
    $only.Add_CheckedChanged({ & $load })

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick($load)
    $f.Add_Shown({ & $load; $timer.Start() })
    $f.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
    [void]$f.ShowDialog()
}

function Ask([string] $prompt, [string] $default = '') {
    if ($script:DryRun) { return $default }
    [Microsoft.VisualBasic.Interaction]::InputBox($prompt, 'Android instances', $default)
}

# $owner matters in the group screen: a MessageBox with no owner can end up behind the
# window that raised it, and then the app looks frozen while it waits for an answer nobody
# can see.
function Confirm-Action([string] $text, [string] $title, $owner = $null) {
    if ($script:DryRun) { return $true }
    if ($owner) { return ([System.Windows.Forms.MessageBox]::Show($owner, $text, $title, 'YesNo', 'Warning') -eq 'Yes') }
    return ([System.Windows.Forms.MessageBox]::Show($text, $title, 'YesNo', 'Warning') -eq 'Yes')
}

function Get-Selected {
    if ($script:DryRun) { return 'wa01' }
    if ($list.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select an instance first.', 'Android instances')
        return $null
    }
    return $list.SelectedItems[0].Text
}

# ---------------------------------------------------------------------- requirements
# "Is this machine able to run the thing, and if not, what exactly is missing." Every row
# comes from Test-Requirements in common.ps1, so the same report is available on the command
# line (android.ps1 -Requirements) and in the log.
function Show-Requirements {
    if ($script:DryRun) {
        @(Test-Requirements (Get-Settings)) | Format-Table Item, State, Detail -AutoSize |
            Out-String -Width 200 | Write-Host
        return
    }

    $f               = New-Object System.Windows.Forms.Form
    $f.Text          = 'Requirements'
    $f.Size          = New-Object System.Drawing.Size(940, 610)
    $f.MinimumSize   = New-Object System.Drawing.Size(720, 460)
    $f.StartPosition = 'CenterScreen'

    $lv               = New-Object System.Windows.Forms.ListView
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines     = $true
    $lv.MultiSelect   = $false
    $lv.Location      = New-Object System.Drawing.Point(12, 12)
    $lv.Size          = New-Object System.Drawing.Size(900, 350)
    $lv.Anchor        = 'Top,Left,Bottom,Right'
    foreach ($c in @(@('what', 150), @('state', 80), @('detail', 650))) { [void]$lv.Columns.Add($c[0], $c[1]) }
    $f.Controls.Add($lv)

    $hint            = New-Object System.Windows.Forms.TextBox
    $hint.Multiline  = $true
    $hint.ReadOnly   = $true
    $hint.ScrollBars = 'Vertical'
    $hint.Location   = New-Object System.Drawing.Point(12, 372)
    $hint.Size       = New-Object System.Drawing.Size(900, 130)
    $hint.Anchor     = 'Bottom,Left,Right'
    $f.Controls.Add($hint)

    $install          = New-Object System.Windows.Forms.Button
    $install.Text     = 'Install missing'
    $install.Location = New-Object System.Drawing.Point(12, 514)
    $install.Size     = New-Object System.Drawing.Size(130, 28)
    $install.Anchor   = 'Bottom,Left'
    $f.Controls.Add($install)

    $settings          = New-Object System.Windows.Forms.Button
    $settings.Text     = 'Settings...'
    $settings.Location = New-Object System.Drawing.Point(152, 514)
    $settings.Size     = New-Object System.Drawing.Size(110, 28)
    $settings.Anchor   = 'Bottom,Left'
    $f.Controls.Add($settings)

    $recheck          = New-Object System.Windows.Forms.Button
    $recheck.Text     = 'Recheck'
    $recheck.Location = New-Object System.Drawing.Point(272, 514)
    $recheck.Size     = New-Object System.Drawing.Size(100, 28)
    $recheck.Anchor   = 'Bottom,Left'
    $f.Controls.Add($recheck)

    $close          = New-Object System.Windows.Forms.Button
    $close.Text     = 'Close'
    $close.Location = New-Object System.Drawing.Point(812, 514)
    $close.Size     = New-Object System.Drawing.Size(100, 28)
    $close.Anchor   = 'Bottom,Right'
    $f.Controls.Add($close)

    $fill = {
        $rows = @(Test-Requirements (Get-Settings))
        $lv.BeginUpdate()
        $lv.Items.Clear()
        foreach ($r in $rows) {
            $it = New-Object System.Windows.Forms.ListViewItem($r.Item)
            [void]$it.SubItems.Add($r.State)
            [void]$it.SubItems.Add($r.Detail)
            $it.Tag = $r.Hint
            if     ($r.State -eq 'ok')   { $it.ForeColor = [System.Drawing.Color]::DarkGreen }
            elseif ($r.State -eq 'warn') { $it.ForeColor = [System.Drawing.Color]::DarkOrange }
            else                         { $it.ForeColor = [System.Drawing.Color]::Firebrick }
            [void]$lv.Items.Add($it)
        }
        $lv.EndUpdate()

        $missing = @($rows | Where-Object { $_.State -eq 'missing' })
        $bad     = @($rows | Where-Object { $_.State -eq 'bad' })
        $warn    = @($rows | Where-Object { $_.State -eq 'warn' })
        # Only the download can be automated; a bad path or a missing Windows feature has
        # to be pointed at the button that fixes it instead.
        $install.Enabled = ($missing.Count -gt 0)

        $text = @()
        if (-not $missing.Count -and -not $bad.Count) {
            $text += 'Everything this project needs is in place.'
        }
        foreach ($r in ($missing + $bad + $warn)) { $text += "[$($r.State)] $($r.Item): $($r.Hint)" }
        $text += ''
        $text += 'Click a row for its detail. Same report from a terminal: android.ps1 -Requirements'
        $hint.Text = ($text -join "`r`n`r`n")
    }

    $lv.Add_SelectedIndexChanged({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $it = $lv.SelectedItems[0]
        $hint.Text = "$($it.Text)  [$($it.SubItems[1].Text)]`r`n$($it.SubItems[2].Text)" +
                     $(if ("$($it.Tag)") { "`r`n`r`n$($it.Tag)" })
    })
    $install.Add_Click({
        Invoke-Engine @('-Install') -Visible
        [void][System.Windows.Forms.MessageBox]::Show(
            "Downloading in the window that just opened (~1.5 GB, several minutes)." +
            "`n`nPress Recheck when it finishes.", 'Install missing')
    })
    $settings.Add_Click({ Show-Settings; & $fill })
    $recheck.Add_Click($fill)
    $close.Add_Click({ $f.Close() })

    $f.Add_Shown($fill)
    [void]$f.ShowDialog()
}

# ---------------------------------------------------------------------- settings
# Where the SDK, the JDK and the instances live. Written to settings.ini next to these
# scripts and read by both of them, so nothing here is hardcoded to this machine any more.
function Show-Settings {
    $s = Get-Settings
    if ($script:DryRun) {
        foreach ($k in $s.Keys) { Write-Host "    $k = $($s[$k])" -ForegroundColor DarkGray }
        return
    }

    $f               = New-Object System.Windows.Forms.Form
    $f.Text          = 'Settings - where everything lives'
    $f.Size          = New-Object System.Drawing.Size(760, 340)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox   = $false

    $boxes = @{}
    $y     = 18
    foreach ($k in @($s.Keys)) {
        $lab          = New-Object System.Windows.Forms.Label
        $lab.Text     = $k
        $lab.Location = New-Object System.Drawing.Point(12, ($y + 4))
        $lab.Size     = New-Object System.Drawing.Size(80, 20)
        $f.Controls.Add($lab)

        $tb          = New-Object System.Windows.Forms.TextBox
        $tb.Text     = "$($s[$k])"
        $tb.Location = New-Object System.Drawing.Point(96, $y)
        $tb.Size     = New-Object System.Drawing.Size(520, 24)
        $f.Controls.Add($tb)
        $boxes[$k] = $tb

        # Image is a package id, not a path - there is nothing to browse to.
        if ($k -ne 'Image') {
            $br          = New-Object System.Windows.Forms.Button
            $br.Text     = 'Browse'
            # Apk is the one setting that names a FILE, so a folder picker could never pick
            # it - it was silently useless on that row until this told the two apart.
            $br.Tag      = @{ Box = $tb; File = ($k -eq 'Apk') }
            $br.Location = New-Object System.Drawing.Point(626, ($y - 1))
            $br.Size     = New-Object System.Drawing.Size(100, 26)
            $br.Add_Click({
                $box = $this.Tag.Box
                if ($this.Tag.File) {
                    $dlg        = New-Object System.Windows.Forms.OpenFileDialog
                    $dlg.Filter = 'Android app (*.apk;*.xapk;*.apks;*.apkm)|*.apk;*.xapk;*.apks;*.apkm|All files (*.*)|*.*'
                    if ("$($box.Text)") { $dlg.InitialDirectory = Split-Path -Parent "$($box.Text)" }
                    if ($dlg.ShowDialog() -eq 'OK') { $box.Text = $dlg.FileName }
                } else {
                    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                    $dlg.SelectedPath = "$($box.Text)"
                    if ($dlg.ShowDialog() -eq 'OK') { $box.Text = $dlg.SelectedPath }
                }
            })
            $f.Controls.Add($br)
        }
        $y += 34
    }

    $note          = New-Object System.Windows.Forms.Label
    $note.Location = New-Object System.Drawing.Point(12, ($y + 6))
    $note.Size     = New-Object System.Drawing.Size(714, 96)
    $note.Text     = "JdkRoot must be the folder that CONTAINS bin\java.exe (here D:\jdk\jdk-17.0.19+10, not D:\jdk)." +
                     "`r`nMoving AvdHome does NOT move the instances: stop everything, move the <name>.avd folders" +
                     "`r`nyourself, then point this at the new place. An SSD here is the biggest speed win left -" +
                     "`r`nevery boot reads and writes on this disk, and a spinning one is the whole ceiling." +
                     "`r`nRequirements says whether what you typed actually exists."
    $f.Controls.Add($note)

    $save          = New-Object System.Windows.Forms.Button
    $save.Text     = 'Save'
    $save.Location = New-Object System.Drawing.Point(516, ($y + 110))
    $save.Size     = New-Object System.Drawing.Size(100, 28)
    $f.Controls.Add($save)

    $cancel          = New-Object System.Windows.Forms.Button
    $cancel.Text     = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(626, ($y + 110))
    $cancel.Size     = New-Object System.Drawing.Size(100, 28)
    $cancel.Add_Click({ $f.Close() })
    $f.Controls.Add($cancel)

    $save.Add_Click({
        $new = [ordered]@{}
        foreach ($k in @($s.Keys)) {
            $v = "$($boxes[$k].Text)".Trim()
            # Apk is the one optional setting - empty means "install apps by hand". Without
            # this exception the dialog could not be saved at all while it was blank, which
            # is its default.
            if (-not $v -and $k -ne 'Apk') {
                [void][System.Windows.Forms.MessageBox]::Show("$k cannot be empty.", 'Settings', 'OK', 'Warning')
                return
            }
            $new[$k] = $v
        }
        $path = Save-Settings $new
        # Both of these are read by every function in this window, so a save has to take
        # effect now rather than on the next launch.
        $script:Settings = Get-Settings
        $script:AvdHome  = $script:Settings.AvdHome
        $script:adb      = Join-Path $script:Settings.SdkRoot 'platform-tools\adb.exe'
        [void][System.Windows.Forms.MessageBox]::Show(
            "Saved to $path.`n`nThe list below now reads $($script:AvdHome).", 'Settings')
        $f.Close()
    })

    [void]$f.ShowDialog()
}

# ---------------------------------------------------------------------- new / profile
function Get-NextName {
    $used = @(Get-ChildItem $AvdHome -Filter '*.avd' -Directory -ErrorAction SilentlyContinue |
              ForEach-Object { $_.Name -replace '\.avd$', '' })
    for ($i = 1; $i -le 99; $i++) {
        $n = 'wa{0:D2}' -f $i
        if ($used -notcontains $n) { return $n }
    }
    return 'wa'
}

# "What kind of device do you want?" - asked once when an instance is created, and again
# from the Identity button for one that already exists (then the name is fixed and every
# field is prefilled with what that instance has, so opening the dialog changes nothing by
# itself). Both lists come from common.ps1, which is what the engine writes into
# identity.ini and config.ini.
function Show-ProfileDialog {
    param(
        [string] $Title,
        [string] $Name,
        [switch] $Existing,
        $Current
    )
    if ($script:DryRun) {
        # A dry run picks a profile on purpose: it then exercises the -Device/-Region/-Phone
        # path, spaces in the device name included, instead of the derived one.
        return @{ Name = $Name; Ram = 2048; Cores = 2; Device = 'Redmi Note 9'; Region = '964-751'; Phone = '' }
    }

    $f                 = New-Object System.Windows.Forms.Form
    $f.Text            = $Title
    $f.Size            = New-Object System.Drawing.Size(620, 430)
    $f.StartPosition   = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox     = $false

    $y     = 16
    $mkLab = {
        param($text)
        $l          = New-Object System.Windows.Forms.Label
        $l.Text     = $text
        $l.Location = New-Object System.Drawing.Point(12, ($y + 4))
        $l.Size     = New-Object System.Drawing.Size(96, 20)
        $f.Controls.Add($l)
    }

    & $mkLab 'instance'
    $nameBox          = New-Object System.Windows.Forms.TextBox
    $nameBox.Text     = $Name
    $nameBox.Location = New-Object System.Drawing.Point(112, $y)
    $nameBox.Size     = New-Object System.Drawing.Size(180, 24)
    $nameBox.Enabled  = -not $Existing
    $f.Controls.Add($nameBox)
    $y += 36

    & $mkLab 'device'
    $dev               = New-Object System.Windows.Forms.ComboBox
    $dev.DropDownStyle = 'DropDownList'
    $dev.Location      = New-Object System.Drawing.Point(112, $y)
    $dev.Size          = New-Object System.Drawing.Size(470, 24)
    [void]$dev.Items.Add('auto  -  derived from the instance name')
    foreach ($s in $Screens) { [void]$dev.Items.Add(('{0}  -  {1}x{2} @{3}dpi' -f $s.Name, $s.W, $s.H, $s.Dpi)) }
    $dev.SelectedIndex = 0
    $f.Controls.Add($dev)
    $y += 36

    & $mkLab 'region / SIM'
    $reg               = New-Object System.Windows.Forms.ComboBox
    $reg.DropDownStyle = 'DropDownList'
    $reg.Location      = New-Object System.Drawing.Point(112, $y)
    $reg.Size          = New-Object System.Drawing.Size(470, 24)
    [void]$reg.Items.Add('auto  -  derived from the instance name')
    foreach ($p in $Personas) { [void]$reg.Items.Add(('{0}  -  +{1} {2}  {3}' -f $p.Locale, $p.Cc, $p.Prefix, $p.Tz)) }
    $reg.SelectedIndex = 0
    $f.Controls.Add($reg)
    $y += 36

    & $mkLab 'phone number'
    $phoneBox          = New-Object System.Windows.Forms.TextBox
    $phoneBox.Location = New-Object System.Drawing.Point(112, $y)
    $phoneBox.Size     = New-Object System.Drawing.Size(220, 24)
    $f.Controls.Add($phoneBox)
    $phoneNote          = New-Object System.Windows.Forms.Label
    $phoneNote.Text     = 'digits with country code, no + (blank = from the region)'
    $phoneNote.Location = New-Object System.Drawing.Point(340, ($y + 4))
    $phoneNote.Size     = New-Object System.Drawing.Size(250, 20)
    $f.Controls.Add($phoneNote)
    $y += 36

    & $mkLab 'RAM'
    $ram               = New-Object System.Windows.Forms.ComboBox
    $ram.DropDownStyle = 'DropDownList'
    $ram.Location      = New-Object System.Drawing.Point(112, $y)
    $ram.Size          = New-Object System.Drawing.Size(470, 24)
    foreach ($r in @(
        '2048  -  one WhatsApp number (the image refuses less, and this resumes fastest)'
        '2560  -  WhatsApp + Business + a work profile (4 accounts in one instance)'
        '3072  -  heavy use; costs that many MB of real RAM while it runs'
    )) { [void]$ram.Items.Add($r) }
    $ram.SelectedIndex = 0
    $f.Controls.Add($ram)
    $y += 36

    & $mkLab 'CPU cores'
    $cores               = New-Object System.Windows.Forms.ComboBox
    $cores.DropDownStyle = 'DropDownList'
    $cores.Location      = New-Object System.Drawing.Point(112, $y)
    $cores.Size          = New-Object System.Drawing.Size(470, 24)
    foreach ($c in @(
        '2  -  default (6 physical cores here; two instances at 4 already fight over them)'
        '1  -  lightest, noticeably slower to boot'
        '4  -  only worth it when this is the only instance running'
    )) { [void]$cores.Items.Add($c) }
    $cores.SelectedIndex = 0
    $f.Controls.Add($cores)
    $y += 40

    # Prefilled from what the instance already has, so pressing OK without touching
    # anything is a no-op - the phone number of a registered instance especially.
    if ($Current) {
        if ($Current.Device) {
            for ($i = 0; $i -lt $Screens.Count; $i++) {
                if ($Screens[$i].Name -eq "$($Current.Device)") { $dev.SelectedIndex = $i + 1; break }
            }
        }
        if ($Current.Phone) {
            $phoneBox.Text = "$($Current.Phone)"
            for ($i = 0; $i -lt $Personas.Count; $i++) {
                $p = $Personas[$i]
                if ("$($Current.Phone)".StartsWith("$($p.Cc)$($p.Prefix)") -and "$($Current.Locale)" -eq $p.Locale) {
                    $reg.SelectedIndex = $i + 1
                    break
                }
            }
        }
        foreach ($pair in @(@{ Box = $ram; Val = "$($Current.Ram)" }, @{ Box = $cores; Val = "$($Current.Cores)" })) {
            if (-not $pair.Val) { continue }
            $hit = @($pair.Box.Items | Where-Object { "$_" -like "$($pair.Val)  -*" })[0]
            # A value this dialog does not offer (a hand-edited config.ini) becomes the
            # first entry rather than being silently changed to 2048 on OK.
            if ($hit) { $pair.Box.SelectedItem = $hit }
            else {
                [void]$pair.Box.Items.Insert(0, "$($pair.Val)  -  what it has now")
                $pair.Box.SelectedIndex = 0
            }
        }
    }

    $note          = New-Object System.Windows.Forms.Label
    $note.Location = New-Object System.Drawing.Point(12, $y)
    $note.Size     = New-Object System.Drawing.Size(575, 68)
    $note.Text     = "Model, brand, fingerprint and IMEI are the SAME on every instance - they come from one" +
                     "`r`nshared read-only system image and cannot be changed. What really differs per instance is" +
                     "`r`nexactly what is above: screen size, timezone, region, SIM number and device name." +
                     "`r`nA new screen size applies immediately; on an existing instance it needs a Stop and start."
    $f.Controls.Add($note)

    $ok          = New-Object System.Windows.Forms.Button
    $ok.Text     = if ($Existing) { 'Apply' } else { 'Create' }
    $ok.Location = New-Object System.Drawing.Point(380, ($y + 76))
    $ok.Size     = New-Object System.Drawing.Size(100, 28)
    $f.Controls.Add($ok)

    $cancel          = New-Object System.Windows.Forms.Button
    $cancel.Text     = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(487, ($y + 76))
    $cancel.Size     = New-Object System.Drawing.Size(100, 28)
    $cancel.Add_Click({ $f.Close() })
    $f.Controls.Add($cancel)

    $script:PdResult = $null
    $ok.Add_Click({
        $n = "$($nameBox.Text)".Trim()
        # Same rule as Assert-Name in the engine: anything else becomes a folder name.
        if ($n -notmatch '^[A-Za-z0-9_-]+$') {
            [void][System.Windows.Forms.MessageBox]::Show('Name: letters, digits, - and _ only.', $Title, 'OK', 'Warning')
            return
        }
        if (-not $Existing -and (Test-Path (Join-Path $AvdHome "$n.avd"))) {
            [void][System.Windows.Forms.MessageBox]::Show("'$n' already exists.", $Title, 'OK', 'Warning')
            return
        }
        $ph = ("$($phoneBox.Text)" -replace '\D', '')
        if ($ph -and ($ph.Length -lt 8 -or $ph.Length -gt 15)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                'A phone number is 8-15 digits including the country code, without a +.', $Title, 'OK', 'Warning')
            return
        }
        $script:PdResult = @{
            Name   = $n
            Ram    = [int](("$($ram.SelectedItem)" -split '\s+')[0])
            Cores  = [int](("$($cores.SelectedItem)" -split '\s+')[0])
            Device = $(if ($dev.SelectedIndex -gt 0) { $Screens[$dev.SelectedIndex - 1].Name } else { '' })
            Region = $(if ($reg.SelectedIndex -gt 0) { Get-RegionKey $Personas[$reg.SelectedIndex - 1] } else { '' })
            Phone  = $ph
        }
        $f.Close()
    })

    [void]$f.ShowDialog()
    return $script:PdResult
}

# ---------------------------------------------------------------------- group screen
# ONE window that gathers every instance. The emulator windows lose their own title bars and
# become OWNED by this form, so they sit inside it as tiles, stay above it instead of
# vanishing behind the sidebar - and because each one is still a real top-level window,
# clicking a device hands it the mouse and keyboard with no tricks at all. Deliberately not
# SetParent/WS_CHILD: a child window in another process cannot take the keyboard without
# AttachThreadInput, and that ties this window's input queue to every emulator's. The window
# facts behind all of it were measured first - see the group view section of common.ps1.
#
# It is also where several instances are started, stopped and given an APK at once, always
# by calling the same android.ps1 the single-instance buttons call.
#
# Closing this window RELEASES the tiles first (Restore-EmulatorFrames): an owned window is
# destroyed together with its owner, so skipping that would close every emulator with it.
function Show-GroupScreen {
    if ($script:DryRun) {
        $wins = @(Get-EmulatorWindows)
        Write-Host "    would open the group screen - $($wins.Count) emulator window(s) up, starting: $(@(Get-StartingInstances) -join ', ')" -ForegroundColor DarkGray
        return
    }

    $dark  = [System.Drawing.Color]::FromArgb(28, 28, 32)
    $panel = [System.Drawing.Color]::FromArgb(45, 45, 52)
    $pale  = [System.Drawing.Color]::FromArgb(235, 235, 240)
    # A WinForms Button takes its BackColor from its parent but NOT its ForeColor, so on the
    # dark sidebar every button came out black-on-black. Both colours are set explicitly, and
    # FlatStyle Flat because the 3D border is what a themed button paints INSTEAD of the
    # BackColor it was given.
    $btnBack = [System.Drawing.Color]::FromArgb(70, 70, 80)
    $uiFont  = New-Object System.Drawing.Font('Segoe UI', 10)

    $f               = New-Object System.Windows.Forms.Form
    $f.Text          = 'Group screen - every instance in one window'
    $f.BackColor     = $dark
    $f.Size          = New-Object System.Drawing.Size(1200, 820)
    # Tall enough that the docked info label cannot slide up over the buttons: list 200 +
    # checkboxes 84 + eight buttons 288 + the label.
    $f.MinimumSize   = New-Object System.Drawing.Size(820, 860)
    $f.StartPosition = 'CenterScreen'
    $f.WindowState   = 'Maximized'

    $side           = New-Object System.Windows.Forms.Panel
    $side.Dock      = 'Left'
    $side.Width     = 320
    $side.BackColor = $panel
    $f.Controls.Add($side)

    # Added first, so Dock Bottom claims the space under the buttons rather than over them.
    $info           = New-Object System.Windows.Forms.Label
    $info.Dock      = 'Bottom'
    $info.Height    = 210
    $info.ForeColor = $pale
    $info.Font      = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $info.Padding   = New-Object System.Windows.Forms.Padding(10, 6, 8, 6)
    $side.Controls.Add($info)

    $clb              = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location     = New-Object System.Drawing.Point(10, 10)
    $clb.Size         = New-Object System.Drawing.Size(300, 200)
    $clb.CheckOnClick = $true
    $clb.Font         = New-Object System.Drawing.Font('Consolas', 10)
    $side.Controls.Add($clb)

    $tips2 = New-Object System.Windows.Forms.ToolTip
    $y     = 220
    $boxes = @{}
    foreach ($c in @(
        @{ Key = 'one';   Text = 'one window (no title bars)'; On = $true
           Tip = 'Strips each emulator''s title bar and makes it owned by this window, so the set looks and behaves like a single screen. Unchecked, they go back to being ordinary windows in a grid.' }
        @{ Key = 'tools'; Text = 'hide the side toolbars';     On = $true
           Tip = 'Each emulator''s toolbar is a separate 54 px window docked to its right, so in a tight grid it covers the neighbour. The keyboard and adb still work without it.' }
        @{ Key = 'auto';  Text = 'keep arranging (3 s)';       On = $true
           Tip = 'Instances come up seconds to a minute apart, so the layout is re-run every 3 s and each window drops into its place as it appears. Windows already in place are left alone.' }
    )) {
        $cb           = New-Object System.Windows.Forms.CheckBox
        $cb.Text      = $c.Text
        $cb.Checked   = $c.On
        $cb.ForeColor = $pale
        $cb.Font      = $uiFont
        $cb.Location  = New-Object System.Drawing.Point(12, $y)
        $cb.Size      = New-Object System.Drawing.Size(300, 24)
        $tips2.SetToolTip($cb, $c.Tip)
        $side.Controls.Add($cb)
        $boxes[$c.Key] = $cb
        $y += 28
    }
    $oneWin = $boxes['one']; $hideTb = $boxes['tools']; $auto = $boxes['auto']

    # ---- what is checked, and what state everything is in ------------------------------
    # Instance rows are read ONCE, when the window opens, and with -Fast (no adb, no disk
    # walk). The 3 s tick uses the window list and the cached launcher list instead, which cost
    # single-digit milliseconds and - unlike adb - can also see an instance that is still
    # queued on the boot gate. Everything below runs on the UI thread, so anything expensive in
    # here is not "slow", it is the window refusing to answer a click.
    $script:GroupRows = @()
    $names = { @($clb.CheckedItems | ForEach-Object { ("$_" -split '\s+')[0] }) }

    # What THIS window just asked to boot. Get-StartingInstances reads other processes'
    # command lines over WMI and is now cached (it costs seconds while a guest boots), so for
    # a few seconds after a click it can still answer "nothing is starting" - and that gap is
    # exactly when clicking Start again launches a second copy of the same instance (measured
    # once: wa01 launched twice, 32 s apart). Remembered here instead of asked for: dropped as
    # soon as the instance has a window, or after 3 minutes if it never comes up.
    $script:GroupPending = @{}
    $pending = {
        # Held unconditionally for 20 s - that is the gap between the click and the launcher
        # process being readable over WMI. After that the launcher IS the evidence, so a boot
        # that died or was stopped stops reading as "starting": it used to keep the label for
        # a full 3 minutes and the Start button answered "already starting" the whole time.
        $live = @(Get-StartingInstances)
        foreach ($k in @($script:GroupPending.Keys)) {
            $age = ([datetime]::UtcNow - $script:GroupPending[$k]).TotalSeconds
            if ($age -gt 180 -or ($age -gt 20 -and $live -notcontains $k)) { $script:GroupPending.Remove($k) }
        }
        @($script:GroupPending.Keys)
    }

    $script:GroupState = ''
    $paint = {
        param($rows, $force)
        $checked = & $names
        $up      = @(Get-EmulatorWindows | ForEach-Object Name)
        # It has a window, so it is no longer "about to start".
        foreach ($n in $up) { $script:GroupPending.Remove($n) }
        $going   = @(@(Get-StartingInstances) + @(& $pending) | Sort-Object -Unique)
        # Rebuilding the list resets its scroll position, and the 3 s tick would do that
        # forever with a dozen instances. Only when a state actually changed.
        $sig = ($up -join ',') + '|' + ($going -join ',')
        if (-not $force -and $clb.Items.Count -and $sig -eq $script:GroupState) { return }
        $script:GroupState = $sig
        if (-not $clb.Items.Count -and $up.Count) { $checked = $up }   # first open: what is on the screen
        $clb.BeginUpdate()
        $clb.Items.Clear()
        foreach ($r in $rows) {
            # Window present or a launcher alive - never the cached adb state: that one is
            # read once (adb is slow) and would still say "device" minutes after a Stop.
            $state = if ($up -contains $r.Name) { 'up' } elseif ($going -contains $r.Name) { 'starting' } else { '-' }
            [void]$clb.Items.Add(('{0,-13} {1,-9} {2}' -f $r.Name, $state, $(if ($r.Number) { '+' + $r.Number } else { '' })),
                                 ($checked -contains $r.Name))
        }
        $clb.EndUpdate()
    }
    # -Fast: this list needs the name and the number, not the disk size - see Get-Instances.
    $fill    = { $script:GroupRows = @(Get-Instances -Fast); & $paint $script:GroupRows $true }
    $restate = { if ($script:GroupRows.Count) { & $paint $script:GroupRows $false } }

    $script:GroupNote = ''
    # One click or one tick at a time - see the timer at the bottom.
    $script:GroupBusy = $false
    $describe = {
        $sel   = & $names
        $up    = @(Get-EmulatorWindows | ForEach-Object Name)
        # A launcher stays alive for another half minute after the window appears (it is
        # still applying the identity and checking the app), and reporting that as "starting"
        # next to "on screen" reads like something is stuck.
        $going = @(@(Get-StartingInstances) + @(& $pending) | Sort-Object -Unique | Where-Object { $up -notcontains $_ })
        $live  = @($sel | Where-Object { $up -contains $_ })
        $text  = "$($sel.Count) checked - $($live.Count) on screen, $(@($sel | Where-Object { $going -contains $_ }).Count) starting."
        if ($going.Count) { $text += "  (booting: $($going -join ', '))" }
        if ($sel.Count) {
            $area = & $tileArea
            $plan = Get-GridPlan $sel.Count $area.Width $area.Height
            if ($plan) {
                $text += "`n`nGrid $($plan.Cols) x $($plan.Rows), tile about $($plan.W) x $($plan.H) in the $($area.Width) x $($area.Height) area."
                if ($plan.Tight) { $text += "  That is small - the guests are 480-600 px wide, so text will be hard to read." }
            }
            # The ceiling since guest RAM stopped living in a file on disk: ~3 GB of real
            # commit each. Past it Windows pages the guests out and they look frozen while
            # the CPU is idle - so it is said BEFORE anything is started.
            # GlobalMemoryStatusEx, not Win32_OperatingSystem: same number, but the WMI call
            # costs ~100 ms per tick and stalls for seconds on a box that is busy booting.
            $free = [math]::Round([Tiles.Win]::FreeRamMB() / 1024, 1)
            if ($free) { $text += "`n`n~3 GB of real RAM each: $($sel.Count) checked needs about $($sel.Count * 3) GB, $free GB free." }
        }
        $text += "`n`nClick any device to type in it. Boots are queued one at a time - this disk cannot resume two guests at once."
        $info.Text = $(if ($script:GroupNote) { "$($script:GroupNote)`n`n" } else { '' }) + $text
    }

    # ---- the tile area and the layout ---------------------------------------------------
    $tileArea = {
        $tl = $f.PointToScreen((New-Object System.Drawing.Point($side.Width, 0)))
        New-Object System.Drawing.Rectangle $tl.X, $tl.Y, ($f.ClientSize.Width - $side.Width), $f.ClientSize.Height
    }

    $arrange = {
        $sel = & $names
        # The ticked boxes ARE the group: a device whose box was unticked is handed back its
        # title bar and its old position here, so the screen never keeps hold of something
        # that is no longer checked.
        $loose = @(Get-EmulatorWindows | Where-Object { $sel -notcontains $_.Name } | ForEach-Object Name)
        if ($loose.Count) { [void](Restore-EmulatorFrames $loose) }
        if (-not $sel.Count) { & $describe; return @() }
        $area = & $tileArea
        if ($area.Width -lt 120 -or $area.Height -lt 120) { return @() }
        # @() around the WHOLE if: a branch that produces nothing leaves $placed as $null, not
        # as an empty array, and then "$($placed.Count) tile(s)" logs a blank where a 0 belongs
        # (it did, all through the 17:54 boot).
        $placed = @(if ($oneWin.Checked) {
            @(Set-EmulatorGrid -Only $sel -KeepToolbars:(-not $hideTb.Checked) -Area $area -Owner $f.Handle -Frameless)
        } else {
            @(Set-EmulatorGrid -Only $sel -KeepToolbars:(-not $hideTb.Checked) -Area $area)
        })
        if ($placed.Count) {
            $script:GroupNote = "$($placed.Count) in place:  " + (($placed | ForEach-Object { "$($_.Name) $($_.W)x$($_.H)" }) -join ' | ')
        }
        # On a settled grid this is empty every tick; a name here every 3 s means the layout is
        # fighting the emulator's own size correction and every guest is paying for it.
        if ($script:TilesMoved.Count) { Write-Log "group: moved $($script:TilesMoved -join ', ') ($($placed.Count) tile(s) in the grid)" }
        # A tile that is not in the grid always had a reason; now the reason is written down.
        if ($script:TilesSkipped.Count) {
            $script:GroupNote += "  -  waiting for $($script:TilesSkipped -join ', ') to answer (still busy booting)"
            Write-Log "group: $($script:TilesSkipped -join ', ') did not answer in 200 ms - left for the next pass" 'WARN'
        }
        & $describe
        return $placed
    }

    # ---- buttons ------------------------------------------------------------------------
    $y = 312
    foreach ($b in @(
        @{ T = 'All / none';      Tip = 'Check everything, or nothing' }
        @{ T = 'Start checked';   Tip = 'Boot the checked instances that are neither up nor already starting. They queue - one boot at a time - and each window drops into the grid as it appears.' }
        @{ T = 'Stop checked';    Tip = 'Graceful shutdown of every checked instance, so Android flushes its data' }
        @{ T = 'Install app ...'; Tip = 'Pick one .apk - or a whole .xapk / .apks / .apkm bundle - and install it into every checked instance. A bundle is unpacked first and its parts go in together (adb install-multiple), with any obb payload pushed to the sdcard. An instance that is off boots first. Progress is in each instance log.' }
        @{ T = 'Arrange now';     Tip = 'Lay the checked windows out again - also what android.ps1 -Tile does' }
        @{ T = 'Toolbars back';   Tip = 'Show every emulator''s side toolbar again' }
        @{ T = 'Release windows'; Tip = 'Give the tiles their title bars back and let them go: ordinary independent windows again. Happens automatically when this window closes.' }
        @{ T = 'Close' }
    )) {
        $btn           = New-Object System.Windows.Forms.Button
        $btn.Text      = $b.T
        $btn.Tag       = $b.T
        $btn.Location  = New-Object System.Drawing.Point(10, $y)
        $btn.Size      = New-Object System.Drawing.Size(300, 32)
        $btn.FlatStyle = 'Flat'
        $btn.BackColor = $btnBack
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.Font      = $uiFont
        $btn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(110, 110, 125)
        $btn.TextAlign = 'MiddleLeft'
        $btn.Padding   = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
        if ($b.Tip) { $tips2.SetToolTip($btn, $b.Tip) }
        # A modal MessageBox runs its own message loop, so the 3 s timer went on firing
        # INSIDE the confirmation dialog - re-entering the layout while a click was still
        # being answered. One flag guards both directions: no tick during a click, no second
        # click during a tick.
        $btn.Add_Click({
            if ($script:GroupBusy) { return }
            $script:GroupBusy = $true
            # Which button was pressed, and when: the group screen's own history in the log,
            # so "I clicked Stop and nothing happened" can be checked instead of guessed.
            Write-Log "group: click '$([string]$this.Tag)'"
            try {
            switch ([string]$this.Tag) {
                'All / none' {
                    $none = ($clb.CheckedItems.Count -eq 0)
                    for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $none) }
                    & $describe
                }
                'Start checked' {
                    $sel = & $names
                    if (-not $sel.Count) {
                        [void][System.Windows.Forms.MessageBox]::Show($f, 'Check the instances to start first.', 'Group screen')
                        return
                    }
                    $up    = @(Get-EmulatorWindows | ForEach-Object Name)
                    # -Fresh: this is the one decision that must not run on a cached answer.
                    $going = @(@(Get-StartingInstances -Fresh) + @(& $pending) | Sort-Object -Unique)
                    # A queued instance has no window and no console port for up to a
                    # minute, so without this it reads as "off" and clicking Start again is
                    # the obvious move - which is how wa01 got launched twice, 32 s apart.
                    $new = @($sel | Where-Object { $up -notcontains $_ -and $going -notcontains $_ })
                    if (-not $new.Count) {
                        $why = @()
                        if (@($sel | Where-Object { $up -contains $_ }).Count)    { $why += "already up: $((@($sel | Where-Object { $up -contains $_ })) -join ', ')" }
                        if (@($sel | Where-Object { $going -contains $_ }).Count) { $why += "already starting: $((@($sel | Where-Object { $going -contains $_ })) -join ', ')" }
                        [void][System.Windows.Forms.MessageBox]::Show($f, "Nothing to start.`n`n$($why -join "`n")", 'Group screen')
                        return
                    }
                    $free = [math]::Round([Tiles.Win]::FreeRamMB() / 1024, 1)
                    # Named, and asked, every time more than one is about to boot: "All /
                    # none" ticks every box, and the next click would otherwise start the
                    # whole list with nothing to confirm it.
                    if ($new.Count -gt 1) {
                        $warn = if ($free -and ($new.Count * 3) -gt $free) {
                            "`n`nWARNING: that needs about $($new.Count * 3) GB of real RAM and only $free GB is free. Past that Windows pages the guests out and they look frozen while the CPU sits idle."
                        } else { "`n`nThey boot one at a time, about 30 s each." }
                        if (-not (Confirm-Action "Start $($new.Count) instances?`n`n$($new -join ', ')$warn" 'Group screen - start several' $f)) { return }
                    }
                    elseif ($free -and 3 -gt $free) {
                        if (-not (Confirm-Action "Only $free GB of RAM is free and an instance needs about 3 GB.`n`nStart it anyway?" 'Group screen' $f)) { return }
                    }
                    foreach ($n in $new) {
                        Invoke-Engine @('-Name', $n)
                        $script:GroupPending[$n] = [datetime]::UtcNow
                    }
                    $auto.Checked = $true
                    Write-Log "group: launched $($new.Count) - $($new -join ', ') (queued on the boot gate, one at a time)"
                    $script:GroupNote = "starting $($new.Count): $($new -join ', ') - queued, one boot at a time (~30 s each). The list says 'starting' until the window appears; do not click again."
                    & $restate
                    & $describe
                }
                'Stop checked' {
                    $sel = & $names
                    if (-not $sel.Count) { return }
                    if (-not (Confirm-Action "Shut down $($sel.Count) instance(s) gracefully: $($sel -join ', ')?" 'Group screen' $f)) { return }
                    # Released first: a tile is owned by this window, and it must be an
                    # ordinary window again before Android closes it.
                    [void](Restore-EmulatorFrames)
                    foreach ($n in $sel) { Invoke-Engine @('-Name', $n, '-Stop') }
                    Write-Log "group: stopping $($sel -join ', ')"
                    $script:GroupNote = "stopping $($sel.Count): $($sel -join ', ')"
                    & $describe
                }
                'Install app ...' {
                    $sel = & $names
                    if (-not $sel.Count) {
                        [void][System.Windows.Forms.MessageBox]::Show($f, 'Check the instances to install into first.', 'Group screen')
                        return
                    }
                    $dlg        = New-Object System.Windows.Forms.OpenFileDialog
                    $dlg.Title  = "Install into $($sel.Count) instance(s)"
                    $dlg.Filter = 'Android app (*.apk;*.xapk;*.apks;*.apkm)|*.apk;*.xapk;*.apks;*.apkm|All files (*.*)|*.*'
                    if ($dlg.ShowDialog($f) -ne 'OK') { return }
                    $apk = $dlg.FileName
                    # Only .aab is refused here, once: the engine refuses it too, but from a
                    # hidden run that would be one error dialog per instance. A bundle is fine
                    # now - Install-AppFile unpacks it and installs the splits together.
                    if ($apk -match '\.aab$') {
                        [void][System.Windows.Forms.MessageBox]::Show($f,
                            "An .aab is a build artefact, not an installable app: it needs bundletool and a signing key.`n`nDownload the .apk or .xapk of this app instead.",
                            'Install app', 'OK', 'Warning')
                        return
                    }
                    $mb   = [math]::Round((Get-Item -LiteralPath $apk).Length / 1MB, 1)
                    $kind = if (Test-AppBundle $apk) { "`n`nIt is a bundle: it gets unpacked, one ABI split is kept and the parts are installed together." } else { '' }
                    if (-not (Confirm-Action "Install $(Split-Path -Leaf $apk) ($mb MB) into $($sel.Count) instance(s)?`n`n$($sel -join ', ')$kind`n`nEach one takes 10-60 s and is logged in its own instance log (Logs in the main window). Any instance that is off boots first." 'Install app' $f)) { return }
                    foreach ($n in $sel) { Invoke-Engine @('-Name', $n, '-Apk', $apk) }
                    Write-Log "group: installing $(Split-Path -Leaf $apk) into $($sel -join ', ')"
                    $script:GroupNote = "installing $(Split-Path -Leaf $apk) into $($sel.Count): $($sel -join ', ') - watch it in Logs"
                    & $describe
                }
                'Arrange now'     { [void](& $arrange) }
                'Toolbars back'   { $script:GroupNote = "put back $(Show-EmulatorToolbars) side toolbar(s)"; & $describe }
                'Release windows' {
                    $n = Restore-EmulatorFrames
                    # Unticking fires CheckedChanged, which re-arranges and writes its own
                    # note - so the note is set AFTER that, or it never reaches the label.
                    $oneWin.Checked   = $false
                    $script:GroupNote = "released $n window(s) - title bars back, they are ordinary windows again"
                    & $describe
                }
                'Close' { $f.Close() }
            }
            }
            finally { $script:GroupBusy = $false }
        })
        $side.Controls.Add($btn)
        $y += 36
    }

    # Unticking "one window" has to undo the frames, not just stop applying them.
    $oneWin.Add_CheckedChanged({
        if (-not $oneWin.Checked) { [void](Restore-EmulatorFrames) }
        [void](& $arrange)
    })
    $hideTb.Add_CheckedChanged({ if ($hideTb.Checked) { [void](& $arrange) } else { [void](Show-EmulatorToolbars); [void](& $arrange) } })

    # MouseUp and KeyUp, not ItemCheck: ItemCheck fires BEFORE the tick flips, so it would
    # act on the previous selection - one click behind, for ever. Arrange, not just describe,
    # so ticking a box pulls that device in and unticking one lets it go immediately.
    $clb.Add_MouseUp({ [void](& $arrange) })
    $clb.Add_KeyUp({ [void](& $arrange) })
    # Resizing or maximising changes the tile area, so the grid has to follow it.
    $f.Add_ResizeEnd({ [void](& $arrange) })

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.Add_Tick({
        # Never on top of a click that is still being answered (a MessageBox pumps messages,
        # so this used to fire while a confirmation was open), and never on top of a previous
        # tick that is still working.
        if ($script:GroupBusy) { return }
        # Minimised = nothing to arrange and nothing to read: the whole tick is skipped rather
        # than spent enumerating windows the user cannot see.
        if ($f.WindowState -eq 'Minimized') { return }
        $script:GroupBusy = $true
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            & $restate
            if ($auto.Checked) { [void](& $arrange) } else { & $describe }
        }
        finally {
            $script:GroupBusy = $false
            # A tick has 3 s and must not need more than a fraction of it: everything it does
            # runs on the UI thread, so a slow tick IS the window not answering. Said out loud
            # (it lands in logs\_group.log) instead of only being felt.
            if ($sw.ElapsedMilliseconds -gt 700) {
                Write-Log ('group: slow tick, {0} ms - the window cannot answer a click for that long' -f $sw.ElapsedMilliseconds) 'WARN'
            }
        }
    })
    $f.Add_Shown({
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $fill
        [void](& $arrange)
        $timer.Start()
        Write-Log ('group: open in {0:N0} ms - {1} instance(s) listed, {2} window(s) on screen' -f `
                   $sw.Elapsed.TotalMilliseconds, $script:GroupRows.Count, @(Get-EmulatorWindows).Count)
    })
    # THE reason this handler exists: these tiles are owned by this form, and an owned
    # window is destroyed with its owner - closing without releasing would take every
    # emulator down with it.
    $f.Add_FormClosing({ $timer.Stop(); Write-Log "group: closing - released $(Restore-EmulatorFrames) window(s)" })
    [void]$f.ShowDialog()
}

# The three profile arguments are only passed when something was actually picked, so an
# untouched dialog leaves identity.ini exactly as it was.
function Add-ProfileArgs([string[]] $argv, $r) {
    if ($r.Device) { $argv += @('-Device', $r.Device) }
    if ($r.Region) { $argv += @('-Region', $r.Region) }
    if ($r.Phone)  { $argv += @('-Phone',  $r.Phone) }
    return $argv
}

# Every button routes through here, so -SelfTest can dry-run the whole set and prove
# no label is unhandled - that class of typo is what makes "no button works".
function Invoke-Action([string] $action) {
    switch ($action) {
        'New' {
            $r = Show-ProfileDialog -Title 'New instance - what kind of device?' -Name (Get-NextName)
            if (-not $r) { return }
            Invoke-Engine (Add-ProfileArgs @('-New', $r.Name, '-Ram', "$($r.Ram)", '-Cores', "$($r.Cores)") $r)
            # Creating runs hidden and takes a while (it may also download the image), so
            # there would otherwise be nothing at all to look at.
            Show-LogViewer $r.Name
        }
        'Clone' {
            $src = Get-Selected; if (-not $src) { return }
            $dst = Ask "Copy '$src' to which new name?" "$($src)copy"
            if (-not $dst) { return }
            if (-not (Confirm-Action "The clone inherits everything inside '$src': the Google account, the installed apps and the Android ID.`n`nClone BEFORE registering a WhatsApp number, never after.`n`nContinue?" 'Clone instance')) { return }
            Invoke-Engine @('-Clone', $src, '-As', $dst)
        }
        'Rename' {
            $n = Get-Selected; if (-not $n) { return }
            $new = Ask "New name for '$n':" "$($n)x"
            if (-not $new -or $new -eq $n) { return }
            Invoke-Engine @('-Name', $n, '-Rename', $new)
        }
        'Delete' {
            $n = Get-Selected; if (-not $n) { return }
            if (-not (Confirm-Action "Delete '$n' permanently?`n`nIts WhatsApp session goes with it. Getting that number back means verifying it again with the SIM." 'Delete instance')) { return }
            Invoke-Engine @('-Name', $n, '-Delete', '-Force')
        }
        'Group'     { Show-GroupScreen }
        'Start'     { $n = Get-Selected; if ($n) { Invoke-Engine @('-Name', $n) } }
        'Stop'      { $n = Get-Selected; if ($n) { Invoke-Engine @('-Name', $n, '-Stop') } }
        'Cold boot' { $n = Get-Selected; if ($n) { Invoke-Engine @('-Name', $n, '-Cold') } }
        'Paste'     { $n = Get-Selected; if ($n) { Invoke-Engine @('-Name', $n, '-Paste') } }
        # Host screen -> guest camera. The selector runs in the engine's own process because
        # it has to be DPI-aware while this window must stay DPI-unaware (see the "screen ->
        # guest camera" section of common.ps1), so there is nothing to do here but launch it.
        # No -Name: one region serves every instance. Clicking again with a region already
        # stored re-picks it or switches it off - and "off" is those two files being gone,
        # because the boot only adds -camera-back while camera.png exists.
        'Screen scan' {
            $cur = Get-CamRegion
            if ($script:DryRun) {
                Write-Host "    camera region now: $(if ($cur) { "$($cur.W)x$($cur.H) at $($cur.X),$($cur.Y), fit $($cur.Fit) of a $($cur.FrameW)x$($cur.FrameH) frame" } else { 'none picked yet' })" -ForegroundColor DarkGray
                Invoke-Engine @('-PickRegion')
                return
            }
            if ($cur) {
                $a = [System.Windows.Forms.MessageBox]::Show(
                    "Every instance's camera currently shows a $($cur.W) x $($cur.H) px box at $($cur.X),$($cur.Y) on this screen.`n`n" +
                    "Yes  -  pick a new rectangle`n" +
                    "No  -  switch it off, back to the emulator's test pattern`n" +
                    "Cancel  -  leave it as it is",
                    'Screen scan', 'YesNoCancel', 'Question')
                if ($a -eq 'Cancel') { return }
                if ($a -eq 'No') {
                    foreach ($p in @($CamIni, $CamFile)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
                    Write-Log 'screen scan switched off - camera.ini and camera.png deleted'
                    $up = @(Get-EmulatorWindows | ForEach-Object Name)
                    [void][System.Windows.Forms.MessageBox]::Show(
                        "Screen scan is off. The feeder stops by itself within a second.$(if ($up.Count) { "`n`nRestart these once to give them the emulated camera back: $($up -join ', ')." })",
                        'Screen scan')
                    return
                }
            } else {
                [void][System.Windows.Forms.MessageBox]::Show(
                    "The screen goes dim - drag a box around what the guest camera should see (a WhatsApp Web QR code, say), or press Esc to cancel.`n`n" +
                    "The picture refreshes about once a second and the guest re-reads it every time something opens the camera, so an expired QR only needs the scanner closed and reopened.",
                    'Screen scan')
            }
            Invoke-Engine @('-PickRegion')
        }
        # Check and Network exist only to be read, and there is no console to read them
        # in any more, so open the log on the way out.
        'Check'     { $n = Get-Selected; if ($n) { Invoke-Engine @('-Name', $n, '-Check'); Show-LogViewer $n } }
        'Network'   { $n = Get-Selected; if ($n) { Invoke-Engine @('-Name', $n, '-Net');   Show-LogViewer $n } }
        'Identity' {
            $n = Get-Selected; if (-not $n) { return }
            # Prefilled from what this instance already has: identity.ini for the profile,
            # config.ini for RAM and cores, so Apply on an untouched dialog changes nothing.
            $cur = Read-Ini (Join-Path $AvdHome "$n.avd\identity.ini")
            $cfg = Read-Ini (Join-Path $AvdHome "$n.avd\config.ini")
            $cur['Ram']   = $cfg['hw.ramSize']
            $cur['Cores'] = $cfg['hw.cpu.ncore']
            $r = Show-ProfileDialog -Title "Profile of '$n'" -Name $n -Existing -Current $cur
            if (-not $r) { return }
            Invoke-Engine (Add-ProfileArgs @('-Name', $n, '-Identity', '-Ram', "$($r.Ram)", '-Cores', "$($r.Cores)") $r)
            Show-LogViewer $n
        }
        'Logs'         { $n = Get-Selected; if ($n) { Show-LogViewer $n } }
        'Launchers'    { Invoke-Engine @('-Launchers') }
        'Requirements' { Show-Requirements }
        'Settings'     { Show-Settings }
        'Stop all' {
            if (-not (Confirm-Action "Ask every running instance to shut down, then kill anything this project left running (adb, stuck emulators, launchers).`n`nSnapshots are saved, WhatsApp sessions are never touched. Takes about 30 s.`n`nThis window closes with it - it is part of the sweep.`n`nContinue?" 'Stop everything')) { return }
            Invoke-Engine @('-KillAll')
        }
        'Retune' {
            $n = Get-Selected; if (-not $n) { return }
            $ram = Ask "RAM in MB for '$n' (changing it invalidates the snapshot, so the next boot is cold).`nResume reads exactly this many MB off the disk, so lower = faster:" '2048'
            if (-not $ram) { return }
            Invoke-Engine @('-Name', $n, '-Retune', '-Ram', $ram)
        }
        'Folder' {
            $n = Get-Selected; if (-not $n) { return }
            $p = Join-Path $AvdHome "$n.avd"
            if ($script:DryRun) { Write-Host "    would open: $p" -ForegroundColor DarkGray; return }
            Start-Process explorer.exe ('"' + $p + '"')   # same unquoted-space trap as above
        }
        'Refresh' { }   # the caller refreshes after every action anyway
        default   { throw "unhandled button '$action'" }
    }
}

# ---------------------------------------------------------------------- self test
if ($SelfTest) {
    Write-Host '== instances ==' -ForegroundColor Cyan
    $rows = @(Get-Instances)
    if ($rows.Count -eq 0) { Write-Host '  none found' -ForegroundColor Yellow }
    $rows | Format-Table Name, Port, Ram, Cores, Res, GB, Snapshot, State, Device, Number, Launcher -AutoSize

    Write-Host '== name sanity ==' -ForegroundColor Cyan
    foreach ($r in $rows) {
        $bad = $r.Name -like '*.avd'
        Write-Host "  $(if ($bad) { 'FAIL' } else { 'OK  ' }) '$($r.Name)'$(if ($bad) { '  <- still carries .avd' })"
    }

    Write-Host '== settings ==' -ForegroundColor Cyan
    $s = Get-Settings
    foreach ($k in $s.Keys) { Write-Host ('  {0,-8} {1}' -f $k, $s[$k]) }
    Write-Host "  file     $SettingsFile$(if (Test-Path $SettingsFile) { '' } else { '  (not written yet - defaults in use)' })"

    Write-Host '== requirements ==' -ForegroundColor Cyan
    $reqs = @(Test-Requirements $s)
    $reqs | Format-Table Item, State, Detail -AutoSize
    foreach ($r in ($reqs | Where-Object { $_.State -ne 'ok' })) { Write-Host "  $($r.Item): $($r.Hint)" -ForegroundColor Yellow }

    # The identity is the one piece of logic here that can be wrong in silence: a phone
    # number that moved is only visible after a registration has already been burnt.
    Write-Host '== identity resolution ==' -ForegroundColor Cyan
    $base   = Resolve-Identity 'wa01' $null $null
    $again  = Resolve-Identity 'wa01' $null @{ Device = ''; Region = ''; Phone = '' }
    $devPick = Resolve-Identity 'wa01' $null @{ Device = 'Redmi Note 9' }
    $regPick = Resolve-Identity 'wa01' $null @{ Region = '971-502' }
    $bothPick = Resolve-Identity 'wa01' $null @{ Region = '971-502'; Phone = '+964 751 540 4553' }
    $registered = @{ Phone = '9641234567890'; Timezone = 'Asia/Aden'; Locale = 'en-YE'
                     Device = 'hand edited'; Width = '500'; Height = '900'; Dpi = '240' }
    $keep   = Resolve-Identity 'wa01' $registered @{ Device = 'Redmi 9A' }
    foreach ($t in @(
        @{ Name = 'derived from the name, stable';        Ok = ($base.Phone -eq $again.Phone -and $base.Device -eq $again.Device) }
        @{ Name = 'identity.ini has all 7 keys';          Ok = ($base.Count -eq 7) }
        @{ Name = 'device pick sets the screen';          Ok = ($devPick.Device -eq 'Redmi Note 9' -and $devPick.Width -eq '600' -and $devPick.Height -eq '1024') }
        @{ Name = 'region pick keeps the last 7 digits';  Ok = ($regPick.Phone -eq ('971502' + $base.Phone.Substring($base.Phone.Length - 7)) -and $regPick.Timezone -eq 'Asia/Dubai') }
        @{ Name = 'typed number beats the region';        Ok = ($bothPick.Phone -eq '9647515404553') }
        @{ Name = 'a registered number never moves';      Ok = ($keep.Phone -eq '9641234567890' -and $keep.Locale -eq 'en-YE') }
        @{ Name = 'but its screen still changes';         Ok = ($keep.Device -eq 'Redmi 9A' -and $keep.Width -eq '480') }
        @{ Name = 'unknown device only renames';          Ok = ((Resolve-Identity 'wa01' $null @{ Device = 'Nokia 3310' }).Width -eq $base.Width) }
        @{ Name = 'image dir derived from the package id'; Ok = ((Get-ImageDir @{ SdkRoot = 'D:\Android\Sdk'; Image = 'system-images;android-30;google_apis_playstore;x86_64' }) -eq 'D:\Android\Sdk\system-images\android-30\google_apis_playstore\x86_64') }
        @{ Name = 'image target derived too';             Ok = ((Get-ImageTarget @{ Image = 'system-images;android-30;google_apis_playstore;x86_64' }) -eq 'android-30') }
    )) { Write-Host "  $(if ($t.Ok) { 'OK  ' } else { 'FAIL' }) $($t.Name)" -ForegroundColor $(if ($t.Ok) { 'Green' } else { 'Red' }) }

    # "Is a launcher for this instance alive?" answers two questions that both hurt when they
    # are wrong: the group screen refuses to Start something it thinks is already starting,
    # and -Stop kills what this matches. A verb run (-Stop, -Apk, ...) carries -Name too and
    # must never look like a boot.
    Write-Host '== launcher detection ==' -ForegroundColor Cyan
    $ps = 'powershell -NoProfile -File "C:\Users\user\Downloads\andriod sum\android.ps1"'
    foreach ($t in @(
        @{ Name = 'a bare boot is a launcher';         Ok = ((Get-LauncherName "$ps -Name wa01") -eq 'wa01') }
        @{ Name = 'digits in the name survive';        Ok = ((Get-LauncherName "$ps -Name 3794xa") -eq '3794xa') }
        @{ Name = '-Stop is not a launcher';           Ok = ((Get-LauncherName "$ps -Name wa01 -Stop") -eq '') }
        @{ Name = '-Apk is not a launcher';            Ok = ((Get-LauncherName "$ps -Name wa01 -Apk c:\x.apk") -eq '') }
        @{ Name = '-Check is not a launcher';          Ok = ((Get-LauncherName "$ps -Name wa01 -Check") -eq '') }
        @{ Name = 'the run bat counts';                Ok = ((Get-LauncherName 'cmd /c "C:\a b\run-wa01.bat"') -eq 'wa01') }
        @{ Name = 'the run bat with -Stop does not';   Ok = ((Get-LauncherName 'cmd /c "C:\a b\run-wa01.bat" -Stop') -eq '') }
        @{ Name = 'the manager window is not one';     Ok = ((Get-LauncherName 'powershell -File manager.ps1 -Dialog group') -eq '') }
        @{ Name = 'an unrelated process is not one';   Ok = ((Get-LauncherName 'powershell -Command Get-Date') -eq '') }
        @{ Name = 'no command line, no launcher';      Ok = ((Get-LauncherName '') -eq '') }
    )) { Write-Host "  $(if ($t.Ok) { 'OK  ' } else { 'FAIL' }) $($t.Name)" -ForegroundColor $(if ($t.Ok) { 'Green' } else { 'Red' }) }

    # The grid is the other pure piece of logic here, and a wrong plan is not obvious from
    # a screenshot: a tile that overflows its cell just looks like overlapping windows.
    Write-Host '== group view: grid plan ==' -ForegroundColor Cyan
    $p1  = Get-GridPlan 1  1707 929
    $p5  = Get-GridPlan 5  1707 929
    $p12 = Get-GridPlan 12 1707 929
    $p30 = Get-GridPlan 30 1707 929
    foreach ($n in @(1, 2, 3, 4, 5, 6, 9, 12, 15, 20, 30)) {
        $p = Get-GridPlan $n 1707 929
        Write-Host ('  {0,3} -> {1} x {2}, tile {3} x {4} in a {5} x {6} cell{7}' -f `
                    $n, $p.Cols, $p.Rows, $p.W, $p.H, $p.CellW, $p.CellH, $(if ($p.Tight) { '  (tight)' } else { '' }))
    }
    foreach ($t in @(
        @{ Name = 'one instance is one cell';              Ok = ($p1.Cols -eq 1 -and $p1.Rows -eq 1) }
        # ceil(sqrt(5)) would say 3x2 and waste half the height: these windows are portrait.
        @{ Name = 'portrait windows prefer columns';       Ok = ($p5.Cols -eq 5 -and $p5.Rows -eq 1) }
        @{ Name = 'no empty last row';                    Ok = (($p12.Cols * ($p12.Rows - 1)) -lt 12) }
        @{ Name = 'enough cells for every instance';       Ok = (($p12.Cols * $p12.Rows) -ge 12) }
        @{ Name = 'tile never overflows its cell';         Ok = ($p12.W -le $p12.CellW -and $p12.H -le $p12.CellH) }
        @{ Name = 'the whole grid fits the screen';        Ok = ((4 * ($p12.Cols + 1) + $p12.Cols * $p12.CellW) -le 1707 -and
                                                                (4 * ($p12.Rows + 1) + $p12.Rows * $p12.CellH) -le 929) }
        @{ Name = 'aspect ratio kept';                    Ok = ([math]::Abs(($p12.W / $p12.H) - 0.5625) -lt 0.02) }
        @{ Name = 'more instances = smaller tiles';       Ok = ($p5.W -gt $p12.W -and $p12.W -gt $p30.W) }
        @{ Name = '30 at once is reported as too small';  Ok = ($p30.Tight -and -not $p12.Tight) }
        @{ Name = 'nothing to arrange = no plan';         Ok = ($null -eq (Get-GridPlan 0 1707 929)) }
    )) { Write-Host "  $(if ($t.Ok) { 'OK  ' } else { 'FAIL' }) $($t.Name)" -ForegroundColor $(if ($t.Ok) { 'Green' } else { 'Red' }) }
    # The two things that made the group screen hang, both now assertable without a window:
    # placement must be idempotent (or the 3 s tick re-moves every tile, which resizes every
    # guest), and the window list / RAM read must be cheap enough to run on the UI thread.
    Write-Host '== group view: does it stay put, and is it cheap ==' -ForegroundColor Cyan
    $tEnum  = (Measure-Command { $null = @(Get-EmulatorWindows) }).TotalMilliseconds
    $null   = Get-StartingInstances -Fresh
    $tCache = (Measure-Command { $null = Get-StartingInstances }).TotalMilliseconds
    Write-Host ('  window list {0:N0} ms, cached launcher list {1:N0} ms, free RAM {2:N0} MB' -f `
                $tEnum, $tCache, [Tiles.Win]::FreeRamMB()) -ForegroundColor DarkGray
    foreach ($t in @(
        @{ Name = 'exactly in place = leave it';           Ok =      (Test-TileInPlace 100 100 400 800  100 100 400 800) }
        # The emulator corrects the size it is given, which moves the centred x a few pixels.
        @{ Name = 'a few px off = still in place';         Ok =      (Test-TileInPlace 104 100 396 790  100 100 400 800) }
        @{ Name = 'a different cell = move it';            Ok = (-not (Test-TileInPlace 500 100 400 800  100 100 400 800)) }
        @{ Name = 'a different size = move it';            Ok = (-not (Test-TileInPlace 100 100 300 600  100 100 400 800)) }
        @{ Name = 'the window list is UI-thread cheap';    Ok = ($tEnum -lt 60) }
        @{ Name = 'the launcher list is cached';           Ok = ($tCache -lt 20) }
        @{ Name = 'free RAM without WMI';                  Ok = ([Tiles.Win]::FreeRamMB() -gt 0) }
    )) { Write-Host "  $(if ($t.Ok) { 'OK  ' } else { 'FAIL' }) $($t.Name)" -ForegroundColor $(if ($t.Ok) { 'Green' } else { 'Red' }) }

    Write-Host '  emulator windows found now:' -ForegroundColor DarkGray
    $wins = @(Get-EmulatorWindows)
    if ($wins.Count) { $wins | Format-Table Name, Port, Hwnd, Width, Height, Aspect -AutoSize }
    else { Write-Host '    none up' }

    # The two pure pieces of the screen-scan and bundle paths. Both fail SILENTLY in the real
    # thing: a capture that lands wrong in the camera frame just never scans, and a bundle
    # with the wrong split kept just says INSTALL_FAILED_NO_MATCHING_ABIS 40 s later.
    Write-Host '== screen scan: capture -> camera frame ==' -ForegroundColor Cyan
    $land = Get-CamFit 800 600 640 480 0.92
    $tall = Get-CamFit 400 900 640 480 0.92
    $full = Get-CamFit 640 480 640 480 1.0
    Write-Host ('  800x600 -> {0}x{1} at {2},{3}   400x900 -> {4}x{5} at {6},{7}' -f `
                $land.W, $land.H, $land.X, $land.Y, $tall.W, $tall.H, $tall.X, $tall.Y) -ForegroundColor DarkGray
    foreach ($t in @(
        # A QR only decodes if the WHOLE symbol is in the frame - this is that guarantee.
        @{ Name = 'the whole capture is inside the frame'; Ok = ($land.X -ge 0 -and $land.Y -ge 0 -and ($land.X + $land.W) -le 640 -and ($land.Y + $land.H) -le 480) }
        @{ Name = 'centred';                               Ok = ([math]::Abs((2 * $land.X + $land.W) - 640) -le 1 -and [math]::Abs((2 * $land.Y + $land.H) - 480) -le 1) }
        @{ Name = 'aspect kept, so nothing is stretched';  Ok = ([math]::Abs(($land.W / $land.H) - (800 / 600)) -lt 0.02) }
        @{ Name = 'a tall region is limited by height';    Ok = ($tall.H -le 480 -and [math]::Abs(($tall.W / $tall.H) - (400 / 900)) -lt 0.02) }
        @{ Name = 'fit 1.0 really fills the frame';        Ok = ($full.W -eq 640 -and $full.H -eq 480) }
        @{ Name = 'fit 0.92 leaves the margin';            Ok = ($land.W -le ([int](640 * 0.92) + 1)) }
        @{ Name = 'a silly fit falls back to 0.92';        Ok = ((Get-CamFit 800 600 640 480 9).W -eq $land.W) }
        @{ Name = 'nothing to capture = no box';           Ok = ($null -eq (Get-CamFit 0 100 640 480)) }
        @{ Name = 'a region is only used if it is real';   Ok = ($null -eq (Get-CamRegion) -or (Get-CamRegion).W -ge 8) }
        # The one that cost an evening: a space anywhere in the camera image path and the
        # guest gets a camera it can never open, with no error from the emulator at all.
        @{ Name = 'the camera image path has no space';    Ok = ($CamFile -notmatch ' ') }
    )) { Write-Host "  $(if ($t.Ok) { 'OK  ' } else { 'FAIL' }) $($t.Name)" -ForegroundColor $(if ($t.Ok) { 'Green' } else { 'Red' }) }
    Write-Host "  frames: $CamFile" -ForegroundColor DarkGray

    Write-Host '== app bundles (.xapk / .apks / .apkm) ==' -ForegroundColor Cyan
    $mixed = @('C:\b\base.apk', 'C:\b\config.x86_64.apk', 'C:\b\config.arm64_v8a.apk',
               'C:\b\config.armeabi_v7a.apk', 'C:\b\config.xxhdpi.apk', 'C:\b\split_config.en.apk')
    $kept  = @(Select-BundleApks $mixed)
    $arm   = @(Select-BundleApks @('C:\b\base.apk', 'C:\b\config.arm64_v8a.apk', 'C:\b\config.armeabi_v7a.apk'))
    $plain = @(Select-BundleApks @('C:\b\base.apk', 'C:\b\config.xxhdpi.apk'))
    Write-Host "  kept: $((($kept | ForEach-Object { Split-Path -Leaf $_ })) -join ', ')" -ForegroundColor DarkGray

    # A real zip through the real unpacker, so "is an XAPK just a zip" is asserted and not
    # assumed. Fake .apk payloads: nothing here reads their contents.
    $bDir = Join-Path $env:TEMP "mgr-bundle-$PID"
    $src  = Join-Path $bDir 'src'
    New-Item -ItemType Directory -Force (Join-Path $src 'Android\obb\com.example.app') | Out-Null
    Set-Content -LiteralPath (Join-Path $src 'com.example.app.apk') -Value 'the base is the biggest part of a bundle'
    Set-Content -LiteralPath (Join-Path $src 'config.x86_64.apk')   -Value 'split'
    Set-Content -LiteralPath (Join-Path $src 'Android\obb\com.example.app\main.1.obb') -Value 'obb'
    $zip = Join-Path $bDir 'test.xapk'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
    $got = Expand-AppBundle $zip (Join-Path $bDir 'out')
    foreach ($t in @(
        @{ Name = 'one ABI split kept, x86_64 first';      Ok = ($kept.Count -eq 4 -and ($kept -join ';') -match 'config\.x86_64\.apk' -and ($kept -join ';') -notmatch 'arm') }
        @{ Name = 'density and language splits survive';   Ok = (($kept -join ';') -match 'xxhdpi' -and ($kept -join ';') -match 'split_config\.en') }
        @{ Name = 'arm64 wins when there is no x86_64';    Ok = ($arm.Count -eq 2 -and ($arm -join ';') -match 'arm64_v8a' -and ($arm -join ';') -notmatch 'armeabi_v7a') }
        @{ Name = 'no ABI split = nothing dropped';        Ok = ($plain.Count -eq 2) }
        @{ Name = '.xapk is a bundle, .apk is not';        Ok = ((Test-AppBundle 'x.xapk') -and (Test-AppBundle 'x.apks') -and -not (Test-AppBundle 'x.apk')) }
        @{ Name = 'a real zip unpacks to its parts';       Ok = ($got.Apks.Count -eq 2) }
        @{ Name = 'the base comes first (biggest)';        Ok = ((Split-Path -Leaf $got.Apks[0]) -eq 'com.example.app.apk') }
        @{ Name = 'the obb and its package are found';     Ok = ($got.Obbs.Count -eq 1 -and $got.ObbPkg -eq 'com.example.app') }
    )) { Write-Host "  $(if ($t.Ok) { 'OK  ' } else { 'FAIL' }) $($t.Name)" -ForegroundColor $(if ($t.Ok) { 'Green' } else { 'Red' }) }
    Remove-Item -LiteralPath $bDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host '== every button, dry run ==' -ForegroundColor Cyan
    foreach ($a in @('New','Clone','Rename','Delete','Start','Stop','Cold boot','Group','Paste','Screen scan','Check','Network','Retune','Identity','Logs','Folder','Launchers','Refresh','Requirements','Settings','Stop all')) {
        Write-Host "  $a"
        try { Invoke-Action $a } catch { Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    }

    # The log viewer is the only new logic here that can be wrong quietly: an off-by-one
    # in the tail, or a colour regex that stops matching the engine's line format, would
    # just look like "the log is empty" or "nothing is highlighted".
    Write-Host '== log tail + highlight ==' -ForegroundColor Cyan
    $tmp = Join-Path $env:TEMP "mgr-selftest-$PID.log"
    $lines = 1..900 | ForEach-Object { "line $_" }
    $lines += '12:00:00.000 [WARN ] a warning'
    $lines += '12:00:01.000 [ERROR] a failure'
    Set-Content -LiteralPath $tmp -Value $lines
    $tail = Get-LogTail $tmp 50
    $got  = @($tail -split "`r?`n")
    $hits = @([regex]::Matches($tail, '^.*\[(ERROR|WARN)\s*\].*$', 'Multiline'))
    foreach ($t in @(
        @{ Name = 'tail length is capped';   Ok = ($got.Count -eq 50) }
        @{ Name = 'tail keeps the LAST line'; Ok = ($got[-1] -like '*a failure*') }
        @{ Name = 'WARN and ERROR matched';   Ok = ($hits.Count -eq 2) }
        @{ Name = 'locked file still reads';  Ok = ([bool](Get-LogTail (Join-Path $LogDir '_killall.log') 5)) }
    )) { Write-Host "  $(if ($t.Ok) { 'OK  ' } else { 'FAIL' }) $($t.Name)" -ForegroundColor $(if ($t.Ok) { 'Green' } else { 'Red' }) }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    Write-Host "`n== launch line ==" -ForegroundColor Cyan
    # The second line matters twice over: this folder has a space in it AND a device name
    # does too ("Redmi Note 9"), and Start-Process quotes neither for you.
    foreach ($argv in @(
        ,@('-Name', 'wa01', '-Check')
        ,@('-New', 'wa03', '-Ram', '2048', '-Device', 'Redmi Note 9', '-Region', '964-751')
    )) {
        $line = @(Get-EngineArgs $argv)
        Write-Host "  powershell $($line -join ' ')"
        # Start-Process does no quoting of its own, so an argument with a space that is not
        # already quoted here is one that powershell.exe will receive split in two.
        $unquoted = @($line | Where-Object { $_ -match '\s' -and $_ -notmatch '^".*"$' })
        if ($unquoted.Count) { Write-Host "  FAIL unquoted argument(s): $($unquoted -join ' | ')" -ForegroundColor Red }
        else                 { Write-Host "  OK   every argument with a space is quoted" -ForegroundColor Green }
    }
    return
}

# The log viewer on its own, so logs.bat is one double-click away from "why did it not
# start" without the instance list in the way.
if ($Logs) { Show-LogViewer $Logs; return }

if ($Dialog) {
    switch ($Dialog) {
        'requirements' { Show-Requirements }
        'settings'     { Show-Settings }
        'group'        { Show-GroupScreen }
        'new' {
            $r = Show-ProfileDialog -Title 'New instance - what kind of device?' -Name (Get-NextName)
            if ($r) { foreach ($k in $r.Keys) { Write-Host ('  {0,-6} {1}' -f $k, $r[$k]) } }
        }
    }
    return
}

# ------------------------------------------------------------------------- form
$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'Android instances'
# Tall enough for the whole button column: they anchor top-right, so a shorter form
# clips the last ones off the bottom instead of scrolling.
$form.Size          = New-Object System.Drawing.Size(1140, 820)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(960, 800)

$list               = New-Object System.Windows.Forms.ListView
$list.View          = 'Details'
$list.FullRowSelect = $true
$list.GridLines     = $true
$list.MultiSelect   = $false
$list.HideSelection = $false
$list.Location      = New-Object System.Drawing.Point(12, 12)
# Anchors only kick in on a resize, so the initial size has to match the taller form.
$list.Size          = New-Object System.Drawing.Size(950, 720)
$list.Anchor        = 'Top,Left,Bottom,Right'
foreach ($c in @(
    @('instance', 130), @('port', 55), @('RAM MB', 65), @('cores', 50),
    @('screen', 85), @('disk GB', 70),
    # "snap file", not "snapshot": the file may exist and still be ignored, because a
    # fresh boot measured 4-8x faster than resuming one on this disk.
    @('snap file', 70), @('state', 70),
    @('looks like', 110), @('phone number', 115), @('run .bat', 65)
)) { [void]$list.Columns.Add($c[0], $c[1]) }
$form.Controls.Add($list)

$status          = New-Object System.Windows.Forms.Label
$status.Location = New-Object System.Drawing.Point(12, 738)
$status.Size     = New-Object System.Drawing.Size(950, 34)
$status.Anchor   = 'Bottom,Left,Right'
$form.Controls.Add($status)

function Update-List {
    $keep = if ($list.SelectedItems.Count) { $list.SelectedItems[0].Text } else { $null }
    $list.BeginUpdate()
    $list.Items.Clear()
    $rows = @(Get-Instances)
    foreach ($r in $rows) {
        $item = New-Object System.Windows.Forms.ListViewItem($r.Name)
        [void]$item.SubItems.Add("$(if ($r.Port) { $r.Port } else { '-' })")
        [void]$item.SubItems.Add("$($r.Ram)")
        [void]$item.SubItems.Add("$($r.Cores)")
        [void]$item.SubItems.Add("$($r.Res)")
        [void]$item.SubItems.Add("$($r.GB)")
        [void]$item.SubItems.Add($r.Snapshot)
        [void]$item.SubItems.Add($r.State)
        [void]$item.SubItems.Add($(if ($r.Device) { $r.Device } else { '-' }))
        [void]$item.SubItems.Add($(if ($r.Number) { '+' + $r.Number } else { '-' }))
        [void]$item.SubItems.Add($(if ($r.Launcher) { 'yes' } else { 'MISSING' }))
        if ($r.State -eq 'device')  { $item.ForeColor = [System.Drawing.Color]::DarkGreen }
        if ($r.State -eq 'offline') { $item.ForeColor = [System.Drawing.Color]::DarkOrange }
        if ($r.Name -eq $keep) { $item.Selected = $true }
        [void]$list.Items.Add($item)
    }
    $list.EndUpdate()

    $total = ($rows | Measure-Object GB -Sum).Sum
    $on    = @($rows | Where-Object { $_.State -ne 'off' }).Count
    $drive = $AvdHome.Substring(0, 2)
    $free  = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'").FreeSpace / 1GB, 1)
    $status.Text = "$($rows.Count) instances, $on running, $([math]::Round($total,1)) GB used, $free GB free on $drive" +
                   "`nAll AVDs report the same device fingerprint - fresh or cloned makes no difference there. Space registrations out over days."
}

$tips = New-Object System.Windows.Forms.ToolTip
$y    = 12
foreach ($b in @(
    @{ Text = 'New';       Tip = 'Create a fresh instance - asks what kind of device it should look like (no apps, no Google account)' }
    @{ Text = 'Clone';     Tip = 'Copy the selected instance - do this BEFORE registering a number' }
    @{ Text = 'Rename';    Tip = 'Rename the instance and its run .bat (keeps the port)' }
    @{ Text = 'Delete';    Tip = 'Erase the instance and its WhatsApp session for good' }
    @{ Text = '-' }
    @{ Text = 'Start';     Tip = 'Boot it (~30 s, fresh boot). It does NOT open WhatsApp - tap the icon in the window when you are ready' }
    @{ Text = 'Stop';      Tip = 'Graceful shutdown so Android can flush the WhatsApp data' }
    @{ Text = 'Cold boot'; Tip = 'Same as Start - a fresh boot is the default now (it measured 4-8x faster than resuming)' }
    @{ Text = 'Group';     Tip = 'Run several at once and arrange every window in one grid - the tile size follows the count. Also starts them in the right order (one boot at a time).' }
    @{ Text = '-' }
    @{ Text = 'Paste';     Tip = 'Paste the Windows clipboard into the focused field. Ctrl+V inside the emulator window does the same, single or in the group - the bridge that supplies that keystroke starts with the first instance.' }
    @{ Text = 'Screen scan'; Tip = 'Drag a rectangle around something on THIS screen - a WhatsApp Web QR code, say - and every instance''s camera shows that rectangle instead of the emulator''s test pattern. Then WhatsApp > Linked devices > Link a device scans it from inside the guest. Click again to re-pick or to switch it off.' }
    @{ Text = 'Check';     Tip = 'Device identity, Google Play, capabilities, and integrity - the last one prints why WhatsApp registration blocks on an emulator' }
    @{ Text = 'Network';   Tip = 'Network diagnostics inside the guest' }
    @{ Text = 'Retune';    Tip = 'Re-apply the tuned settings (asks for RAM)' }
    @{ Text = 'Identity';  Tip = 'Give it its own screen size, timezone, region, phone number and device name' }
    @{ Text = '-' }
    @{ Text = 'Logs';      Tip = 'Live log of the selected instance - boots, errors, the emulator''s own output' }
    @{ Text = 'Folder';    Tip = 'Open the instance directory in Explorer' }
    @{ Text = 'Launchers'; Tip = 'Rewrite every run-<name>.bat (they start hidden now)' }
    @{ Text = 'Refresh' }
    @{ Text = '-' }
    @{ Text = 'Requirements'; Tip = 'What this machine has, what is missing and what is too slow - with what to do about each, and a button that downloads the missing parts' }
    @{ Text = 'Settings';     Tip = 'Where the SDK, the JDK and the instances live (settings.ini next to these scripts)' }
    @{ Text = '-' }
    @{ Text = 'Stop all';  Tip = 'Panic button: shut everything down and kill the leftovers (closes this window too)' }
)) {
    if ($b.Text -eq '-') { $y += 14; continue }
    $btn          = New-Object System.Windows.Forms.Button
    $btn.Text     = $b.Text
    $btn.Tag      = $b.Text
    $btn.Location = New-Object System.Drawing.Point(978, $y)
    $btn.Size     = New-Object System.Drawing.Size(128, 28)
    $btn.Anchor   = 'Top,Right'
    if ($b.Tip) { $tips.SetToolTip($btn, $b.Tip) }
    $btn.Add_Click({
        try { Invoke-Action ([string]$this.Tag) }
        catch { [void][System.Windows.Forms.MessageBox]::Show("$($_.Exception.Message)", 'Error', 'OK', 'Error') }
        Update-List
    })
    $form.Controls.Add($btn)
    $y += 32
}

$list.Add_DoubleClick({ Invoke-Action 'Start'; Update-List })
$form.Add_Shown({ Update-List })
[void]$form.ShowDialog()
try { Stop-Transcript | Out-Null } catch { }
