# Dot-sourced by BOTH android.ps1 (the engine) and manager.ps1 (the window). Three things
# they have to agree on live here and nowhere else:
#
#   1. where the parts are installed   -> settings.ini  (Get-Settings / Save-Settings)
#   2. what a device profile can be    -> $Personas / $Screens / Resolve-Identity
#   3. whether this machine can run it -> Test-Requirements
#
# Nothing here prints, writes a log, or touches an emulator: manager.ps1 -SelfTest calls
# every function below, so they all have to be answerable without a booted instance.

$SettingsFile = Join-Path $PSScriptRoot 'settings.ini'

# Every launcher runs hidden, so a line that is not in a transcript is lost. Defined here
# rather than in android.ps1 (where it used to live) because the manager window needs the same
# timestamps: a group screen that "hangs" left no trace at all before this.
function Write-Log([string] $msg, [string] $level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss.fff'), $level.PadRight(5), $msg
    if     ($level -eq 'ERROR') { Write-Host $line -ForegroundColor Red }
    elseif ($level -eq 'WARN')  { Write-Host $line -ForegroundColor Yellow }
    elseif ($level -eq 'OK')    { Write-Host $line -ForegroundColor Green }
    else                        { Write-Host $line }
}

# The values this project was built and measured on, so settings.ini only has to carry
# what differs. C: is not an option on this box (~6 GB free) - see android.ps1.
$SettingDefaults = [ordered]@{
    SdkRoot = 'D:\Android\Sdk'
    JdkRoot = 'D:\jdk\jdk-17.0.19+10'
    AvdHome = 'D:\Android\avd'
    Image   = 'system-images;android-30;google_apis_playstore;x86_64'
    # Empty = off, and it stays off unless you ask for it. Set it to the official WhatsApp
    # .apk and a booting instance that has no WhatsApp sideloads it by itself - measured
    # 96 s, no Google account needed - but sideloaded means installerPackageName is the
    # shell, not com.android.vending, which is one of the signals WhatsApp checks before it
    # registers a number. See the -ResetApp / integrity notes in android.ps1.
    Apk     = ''
}

# Keys may contain dots, so this reads config.ini (hw.ramSize) as well as settings.ini and
# identity.ini. Returns a plain hashtable; a missing file is an empty one, not an error -
# "not created yet" is a normal state for every file this reads.
function Read-Ini([string] $path) {
    $h = @{}
    if (-not $path -or -not (Test-Path $path)) { return $h }
    foreach ($l in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        if ($l -match '^\s*[#;]') { continue }
        if ($l -match '^\s*([A-Za-z][A-Za-z0-9_.\-]*)\s*=\s*(.*?)\s*$') { $h[$Matches[1]] = $Matches[2] }
    }
    return $h
}

function Get-Settings {
    $s = [ordered]@{}
    foreach ($k in $SettingDefaults.Keys) { $s[$k] = $SettingDefaults[$k] }
    $have = Read-Ini $SettingsFile
    # Copy of the key list: assigning into the dictionary while enumerating it throws.
    foreach ($k in @($s.Keys)) { if ($have[$k]) { $s[$k] = $have[$k] } }
    return $s
}

function Save-Settings($s) {
    $out = @(
        '# Where this project finds its parts. Edit here, or in the manager window >'
        '# Settings. Delete a line to fall back to the default in common.ps1.'
        '#'
        '#   SdkRoot  Android SDK: emulator, adb, cmdline-tools, system images'
        '#   JdkRoot  the folder that CONTAINS bin\java.exe - the version subfolder,'
        '#            not D:\jdk (that has no bin directory)'
        '#   AvdHome  where the instances live, one <name>.avd folder each. Moving it'
        '#            means moving those folders too - stop everything first.'
        '#   Image    sdkmanager package id of the system image. android-30 +'
        '#            playstore is the oldest Play-certified image with arm64'
        '#            translation, which is what makes WhatsApp install.'
        '#   Apk      optional, and empty on purpose. An instance that boots without'
        '#            WhatsApp sideloads this by itself - no Play Store, no Google'
        '#            account - but a sideload sets installerPackageName to the shell'
        '#            instead of com.android.vending, and that is one of the things'
        '#            WhatsApp reads before it lets a number register. Install it in'
        '#            the emulator from the Play Store; fill this in only when you want'
        '#            the automatic sideload back. A plain .apk or a whole .xapk /'
        '#            .apks / .apkm bundle (unpacked, splits installed together).'
        ''
    )
    foreach ($k in $s.Keys) { $out += ('{0} = {1}' -f $k, $s[$k]) }
    $out | Set-Content -LiteralPath $SettingsFile -Encoding ASCII
    return $SettingsFile
}

# "system-images;android-30;google_apis_playstore;x86_64" is both the sdkmanager package id
# and, with the separators swapped, the folder it unpacks into. Derived instead of written
# twice, so changing Image in settings.ini cannot leave the two disagreeing (which would
# look like "the image is missing" right after a successful download).
function Get-ImageDir($s)    { Join-Path $s.SdkRoot (($s.Image -split ';') -join '\') }
function Get-ImageTarget($s) { ($s.Image -split ';')[1] }

# ============================================================ device profiles
# Measured first, then built: every AVD shares ONE read-only system image, so
# ro.product.model / brand / manufacturer / serialno / ro.build.fingerprint are identical on
# every instance and cannot be changed from here. `-prop` cannot override a ro.* that
# build.prop already set - booted with `-prop ro.product.model=SM-A515F` and the guest still
# answered `sdk_gphone_x86_64`. Changing those would need either a per-instance copy of the
# 2.83 GB system image, or a non-playstore image so `adb root` works - which costs Play
# certification, i.e. the Play Store and WhatsApp.
# So these cover what CAN differ, all verified to stick in the guest: screen geometry (what
# an app measures first), timezone, region, the SIM's phone number, and the device name.
$Personas = @(
    @{ Tz = 'Asia/Baghdad'; Locale = 'en-IQ'; Cc = '964'; Prefix = '770' }
    @{ Tz = 'Asia/Baghdad'; Locale = 'en-IQ'; Cc = '964'; Prefix = '751' }
    @{ Tz = 'Asia/Riyadh';  Locale = 'en-SA'; Cc = '966'; Prefix = '551' }
    @{ Tz = 'Asia/Dubai';   Locale = 'en-AE'; Cc = '971'; Prefix = '502' }
    @{ Tz = 'Asia/Amman';   Locale = 'en-JO'; Cc = '962'; Prefix = '791' }
    @{ Tz = 'Asia/Kuwait';  Locale = 'en-KW'; Cc = '965'; Prefix = '501' }
    @{ Tz = 'Asia/Beirut';  Locale = 'en-LB'; Cc = '961'; Prefix = '711' }
    @{ Tz = 'Africa/Cairo'; Locale = 'en-EG'; Cc = '20';  Prefix = '1012' }
)
# Kept deliberately small: 540x960 was the single biggest speed win in this project and a
# 1080p instance renders four times the pixels for a chat app. These all stay cheap while
# giving every instance a different dp footprint and aspect ratio.
$Screens = @(
    @{ W = 540; H = 960;  Dpi = 240; Name = 'Galaxy A51' }
    @{ W = 480; H = 854;  Dpi = 240; Name = 'Redmi 9A' }
    @{ W = 540; H = 1080; Dpi = 240; Name = 'Galaxy A12' }
    @{ W = 600; H = 1024; Dpi = 240; Name = 'Redmi Note 9' }
    @{ W = 576; H = 1024; Dpi = 240; Name = 'Oppo A54' }
    @{ W = 512; H = 1024; Dpi = 240; Name = 'Infinix Hot 10' }
    @{ W = 540; H = 1170; Dpi = 240; Name = 'Realme C21' }
    @{ W = 504; H = 896;  Dpi = 240; Name = 'Tecno Spark 7' }
)

function Get-ScreenProfile([string] $name) {
    if (-not $name) { return $null }
    foreach ($s in $Screens) { if ($s.Name -eq $name) { return $s } }
    return $null
}

# Keyed by "<cc>-<prefix>", not by locale: two personas share en-IQ / Asia/Baghdad and only
# differ in the operator prefix, so a locale key would silently pick the first of the two.
function Get-RegionProfile([string] $key) {
    if (-not $key) { return $null }
    foreach ($p in $Personas) { if ("$($p.Cc)-$($p.Prefix)" -eq $key) { return $p } }
    foreach ($p in $Personas) { if ($p.Locale -eq $key -or $p.Tz -eq $key) { return $p } }
    return $null
}

function Get-RegionKey($p) { "$($p.Cc)-$($p.Prefix)" }

# The identity an instance gets, as a pure function of (name, what identity.ini already
# says, what the user picked). No file I/O on purpose - this is the one piece of logic here
# that can be wrong quietly (a wrong phone number is only visible after a registration),
# so manager.ps1 -SelfTest asserts the whole override matrix instead.
#
#   $existing = parsed identity.ini, or $null   -> wins over the derived value
#   $over     = @{ Device / Region / Phone }    -> wins over both; '' means "leave it"
#
# Derived from an MD5 of the instance name rather than random: an instance keeps the same
# number and screen for ever, two instances never collide, and there is no database to lose.
function Resolve-Identity([string] $avd, $existing, $over) {
    $ov = @{}
    if ($over) { foreach ($k in @($over.Keys)) { $v = "$($over[$k])".Trim(); if ($v) { $ov[$k] = $v } } }

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try { $h = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($avd)) } finally { $md5.Dispose() }
    $p = $Personas[$h[0] % $Personas.Count]
    $s = $Screens[$h[1] % $Screens.Count]
    # 7 digits from three hash bytes: enough that two instances colliding needs the same
    # persona AND the same 10 million.
    $line = ([int]$h[2] * 65536 + [int]$h[3] * 256 + [int]$h[4]) % 10000000
    $id = @{
        Phone    = '{0}{1}{2:D7}' -f $p.Cc, $p.Prefix, $line
        Timezone = $p.Tz
        Locale   = $p.Locale
        Device   = $s.Name
        Width    = "$($s.W)"
        Height   = "$($s.H)"
        Dpi      = "$($s.Dpi)"
    }

    # A number that is already registered with WhatsApp must not move just because someone
    # opened the dialog: the file wins, and only an explicit pick changes it.
    if ($existing) {
        foreach ($k in @('Phone', 'Timezone', 'Locale', 'Device', 'Width', 'Height', 'Dpi')) {
            if ($existing[$k]) { $id[$k] = "$($existing[$k])" }
        }
    }

    if ($ov.Region) {
        $rp = Get-RegionProfile $ov.Region
        if ($rp) {
            $id.Timezone = $rp.Tz
            $id.Locale   = $rp.Locale
            # Country + operator part swapped, subscriber digits kept: picking a region
            # should not hand the instance a completely different number behind its back.
            $tail = ($id.Phone -replace '\D', '')
            if ($tail.Length -gt 7) { $tail = $tail.Substring($tail.Length - 7) }
            $id.Phone = '{0}{1}{2}' -f $rp.Cc, $rp.Prefix, $tail.PadLeft(7, '0')
        }
    }
    if ($ov.Device) {
        $sp = Get-ScreenProfile $ov.Device
        if ($sp) {
            $id.Device = $sp.Name
            $id.Width  = "$($sp.W)"
            $id.Height = "$($sp.H)"
            $id.Dpi    = "$($sp.Dpi)"
        } else {
            # A name that is not one of the profiles is still a legal device name (it is
            # what Settings and Bluetooth show); it just does not change the screen.
            $id.Device = $ov.Device
        }
    }
    # Last, so a hand-typed number beats the one a region change generated.
    if ($ov.Phone) { $id.Phone = ($ov.Phone -replace '\D', '') }
    return $id
}

# ============================================================ requirements
# One row per thing that has actually stopped an instance from running on this box. State is
# 'ok' | 'warn' | 'missing' | 'bad'; Hint says what to do about it, and is the only place
# the reason is written down for the person reading the window.
function Test-Requirements($s) {
    if (-not $s) { $s = Get-Settings }
    $rows = New-Object System.Collections.ArrayList
    $add  = {
        param($item, $state, $detail, $hint)
        [void]$rows.Add([pscustomobject]@{ Item = $item; State = $state; Detail = "$detail"; Hint = "$hint" })
    }

    $sdk     = "$($s.SdkRoot)"
    $jdk     = "$($s.JdkRoot)"
    $avdHome = "$($s.AvdHome)"

    $parts = [ordered]@{
        'Java (JDK)'   = @{ Path = (Join-Path $jdk 'bin\java.exe')
                            Hint = 'JdkRoot must be the folder that CONTAINS bin\java.exe - on this box D:\jdk\jdk-17.0.19+10, not D:\jdk. Change it in Settings.' }
        'Android SDK'  = @{ Path = $sdk
                            Hint = 'Settings > SdkRoot. Nothing can be downloaded until this folder and the command-line tools exist.' }
        'sdkmanager'   = @{ Path = (Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat')
                            Hint = 'Unzip the Android command-line tools into <SdkRoot>\cmdline-tools\latest. This is the one part nothing here can install for you.' }
        'adb'          = @{ Path = (Join-Path $sdk 'platform-tools\adb.exe')
                            Hint = '"Install missing" downloads it. Without adb nothing can tell whether an instance booted.' }
        'emulator'     = @{ Path = (Join-Path $sdk 'emulator\emulator.exe')
                            Hint = '"Install missing" downloads it (~500 MB).' }
        'system image' = @{ Path = (Get-ImageDir $s)
                            Hint = "`"Install missing`" downloads $($s.Image) (~2.8 GB, shared by EVERY instance - it is not per instance)." }
    }
    foreach ($k in $parts.Keys) {
        if (Test-Path $parts[$k].Path) { & $add $k 'ok' $parts[$k].Path '' }
        else                           { & $add $k 'missing' $parts[$k].Path $parts[$k].Hint }
    }

    # --- where the instances live -------------------------------------------------
    if (Test-Path $avdHome) {
        $n     = @(Get-ChildItem $avdHome -Filter '*.avd' -Directory -ErrorAction SilentlyContinue).Count
        $probe = Join-Path $avdHome ".writetest-$PID"
        $ok    = $true
        try { Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop } catch { $ok = $false }
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        if ($ok) { & $add 'instances folder' 'ok' "$avdHome - $n instance(s)" '' }
        else     { & $add 'instances folder' 'bad' "$avdHome is not writable" 'Pick a folder you own (Settings > AvdHome), or start this as Administrator.' }
    } else {
        & $add 'instances folder' 'warn' "$avdHome does not exist yet" 'Created by the first New. Settings > AvdHome to put the instances somewhere else - move the existing .avd folders yourself, with everything stopped.'
    }

    $drive = if ($avdHome -match '^([A-Za-z]):') { $Matches[1] } else { '' }
    if ($drive) {
        try {
            $d      = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($drive):'" -ErrorAction Stop
            $freeGb = [math]::Round($d.FreeSpace / 1GB, 1)
            # 2.5-4.7 GB measured per instance (GetCompressedFileSize, not FileInfo.Length).
            $fit    = [int]($freeGb / 4)
            $state  = if ($freeGb -lt 6) { 'bad' } elseif ($freeGb -lt 20) { 'warn' } else { 'ok' }
            & $add 'free disk' $state "$freeGb GB free on $($drive): - room for about $fit more instance(s)" `
                   'An instance costs 2.5-4.7 GB on disk, and a boot needs room to write. Under ~6 GB a boot fails half way through.'
        } catch { }
        # Win32 associations, NOT Get-PhysicalDisk/Get-Partition: the Storage provider on
        # this box answers "Invalid property" to both, so the whole row silently disappeared.
        # The model is all classic WMI gives (Win32_DiskDrive.MediaType says "Fixed hard
        # disk media" for an NVMe too), so SSD is recognised by name and anything else is
        # reported as a maybe rather than claimed as a fact.
        try {
            $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($drive):'" -ErrorAction Stop
            foreach ($part in (Get-CimAssociatedInstance -InputObject $ld -ResultClassName Win32_DiskPartition -ErrorAction Stop)) {
                foreach ($dd in (Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_DiskDrive -ErrorAction Stop)) {
                    $model = "$($dd.Model)"
                    if ($model -match 'SSD|NVMe|NVM Express') {
                        & $add 'disk type' 'ok' "$($drive): is $model - solid state" ''
                    } else {
                        & $add 'disk type' 'warn' "$($drive): is $model - not a recognised SSD" `
                               'If this is a spinning disk it is the ceiling of the whole project: guest RAM must never live on it (that was THE freeze), so snapshots stay off - which is the default. Moving AvdHome to an SSD is the biggest speed win left. Windows cannot tell SSD from HDD here (its Storage provider is broken on this box), so check the model yourself.'
                    }
                }
            }
        } catch { }
    }

    # --- host ---------------------------------------------------------------------
    try {
        $os        = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalGb   = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $freeGb    = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $commitPct = [int](100 * (1 - ($os.FreeVirtualMemory / $os.TotalVirtualMemorySize)))
        # ~3 GB of real commit per running instance, ever since guest RAM stopped being a
        # file on the disk. That is the current ceiling: ~7 at once on 32 GB, not 13.
        $fit       = [int]($freeGb / 3)
        $state     = if ($commitPct -gt 85 -or $fit -lt 1) { 'bad' } elseif ($commitPct -gt 70) { 'warn' } else { 'ok' }
        & $add 'host RAM' $state "$freeGb GB free of $totalGb GB, commit $commitPct% - room for about $fit running instance(s)" `
               'A running instance costs ~3 GB of real RAM. Past ~85% commit Windows pages the guests out and they look frozen while the CPU sits idle.'
    } catch { }

    $emu = Join-Path $sdk 'emulator\emulator.exe'
    if (Test-Path $emu) {
        # Native stderr becomes ErrorRecords and $ErrorActionPreference='Stop' would make
        # them terminating, so this asks politely and puts the preference back.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = ''; $code = 1
        try   { $out = ((& $emu -accel-check 2>&1 | ForEach-Object { "$_" }) -join ' '); $code = $LASTEXITCODE }
        catch { $out = "$($_.Exception.Message)" }
        finally { $ErrorActionPreference = $prev; $global:LASTEXITCODE = 0 }
        $txt = ($out -replace '\s+', ' ').Trim()
        if ($code -eq 0) { & $add 'CPU acceleration' 'ok' $txt '' }
        else {
            & $add 'CPU acceleration' 'bad' "$txt (exit $code)" `
                   'Turn on "Windows Hypervisor Platform" in Windows Features and reboot. Without it the guest is interpreted and unusable. Do NOT disable Hyper-V to "fix" this - WHPX is what the emulator wants here.'
        }
    }

    try {
        foreach ($g in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            $ver    = "$($g.DriverVersion)"
            $detail = "$($g.Name) driver $ver"
            $state  = 'ok'; $hint = ''
            if ($g.Name -match 'NVIDIA') {
                # NVIDIA hides its real version in the last five digits of the Windows one:
                # 27.21.14.5751 -> 457.51.
                $digits = ($ver -replace '\D', '')
                if ($digits.Length -ge 5) {
                    $short  = $digits.Substring($digits.Length - 5)
                    $nv     = [double]('{0}.{1}' -f $short.Substring(0, 3), $short.Substring(3, 2))
                    $detail = "$($g.Name) driver $nv (windows $ver)"
                    if ($nv -lt 553.35) {
                        $state = 'warn'
                        $hint  = "The emulator wants 553.35+ for Vulkan; below that it drops the WHOLE renderer to the CPU (4x slower boot, crawling UI). Handled: every boot here passes -feature -Vulkan and uses OpenGL, which this driver runs fine. Do not pass -Vulkan until the driver is newer."
                    }
                }
            }
            & $add 'GPU driver' $state $detail $hint
        }
    } catch { }

    try {
        $av = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(360|ZhuDongFangYu|QHSafe|QHActiveDefense)' })
        if ($av.Count) {
            & $add 'antivirus' 'warn' (($av | ForEach-Object Name | Sort-Object -Unique) -join ', ') `
                   "360 hooks qemu's file I/O and also trims idle working sets. Whitelist $sdk and $avdHome if boots stall."
        }
    } catch { }

    try {
        $q = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue)
        & $add 'running now' 'ok' "$($q.Count) emulator process(es) up" ''
    } catch { }

    return $rows.ToArray()
}

# ============================================================ group view (tiling)
# "Run several at once, in one arranged screen" is window placement, not a new renderer:
# each emulator's device window is an ordinary top-level window, so it can be measured and
# moved like any other. Measured on this box before writing any of it:
#   title    "Android Emulator - 3794xa:5558"   <- the AVD name and port, no WMI needed
#   class    Qt653QWindowIcon
#   resize   asked for 300x520, got back 298x521 - the emulator corrects the size itself to
#            keep the guest aspect ratio, so the plan below only has to get the CELL right
#   toolbar  a second, OWNED window (Qt653QWindowToolSaveBits, 54 px wide) that follows the
#            device window and therefore lands on top of the neighbour in a tight grid.
#            ShowWindow(SW_HIDE) on it survives later moves and the guest keeps running.
# Nothing here talks to adb: a window can be arranged while its instance is still booting.
if (-not ('Tiles.Win' -as [type])) {
    Add-Type -Namespace Tiles -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr param);
public delegate bool EnumProc(IntPtr hwnd, IntPtr param);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd, System.Text.StringBuilder text, int max);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd, System.Text.StringBuilder text, int max);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int w, int h, uint flags);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
[DllImport("user32.dll", SetLastError = true)] public static extern IntPtr GetWindowLongPtrW(IntPtr hwnd, int index);
[DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowLongPtrW(IntPtr hwnd, int index, IntPtr value);
[DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp, uint flags, uint ms, out IntPtr result);
[DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX buf);
public struct RECT { public int Left, Top, Right, Bottom; }
public struct MEMORYSTATUSEX {
    public uint dwLength; public uint dwMemoryLoad;
    public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile,
                 ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
}

// One row per interesting window. Filled INSIDE this class on purpose: the callback used to
// be a PowerShell scriptblock, and EnumWindows invokes it once per top-level window on the
// desktop (hundreds), so a single window list cost 130-250 ms - and the group screen asked
// for one 4-6 times per 3 s tick, on the UI thread. Same work in C# is ~2 ms.
public class Info {
    public IntPtr Hwnd; public string Name; public int Port; public string Cls;
    public IntPtr Owner; public bool Visible, Iconic;
    public int Left, Top, Width, Height;
}
static System.Collections.Generic.List<Info> _hits;
static bool Collect(IntPtr hwnd, IntPtr param) {
    var sb = new System.Text.StringBuilder(512);
    GetWindowTextW(hwnd, sb, 512);
    string title = sb.ToString();
    bool dev = title.StartsWith("Android Emulator - ", StringComparison.Ordinal);
    string cls = null;
    if (!dev) {
        var cb = new System.Text.StringBuilder(256);
        GetClassNameW(hwnd, cb, 256);
        cls = cb.ToString();
        // Toolbars are wanted whether visible or not (so they can be put back); every other
        // window on the desktop is not.
        if (cls.IndexOf("ToolSaveBits", StringComparison.Ordinal) < 0) return true;
    }
    var i = new Info();
    i.Hwnd = hwnd; i.Cls = cls;
    i.Visible = IsWindowVisible(hwnd); i.Iconic = IsIconic(hwnd);
    RECT r; GetWindowRect(hwnd, out r);
    i.Left = r.Left; i.Top = r.Top; i.Width = r.Right - r.Left; i.Height = r.Bottom - r.Top;
    if (dev) {
        // "Android Emulator - <avd>:<port>" - the AVD name can itself contain anything, so
        // the port is taken from the LAST colon.
        string rest = title.Substring(19);
        int c = rest.LastIndexOf(':');
        int port;
        if (c <= 0 || !int.TryParse(rest.Substring(c + 1), out port)) return true;
        i.Name = rest.Substring(0, c); i.Port = port;
    } else {
        i.Owner = GetWindow(hwnd, 4);   // GW_OWNER
        if (i.Owner == IntPtr.Zero) return true;
    }
    _hits.Add(i);
    return true;
}
public static Info[] List() {
    _hits = new System.Collections.Generic.List<Info>();
    EnumWindows(new EnumProc(Collect), IntPtr.Zero);
    var all = _hits; _hits = null;
    return all.ToArray();
}
// Does that window's thread still pump messages? SetWindowLongPtrW(GWL_STYLE) sends
// WM_STYLECHANGING/WM_STYLECHANGED, i.e. a SendMessage into another process that does NOT
// come back while a guest is mid-boot - the group screen was parked inside it with no error
// to show. WM_NULL with SMTO_ABORTIFHUNG answers that question with a timeout instead.
public static bool Responds(IntPtr hwnd, uint ms) {
    IntPtr res;
    return SendMessageTimeoutW(hwnd, 0x0000, IntPtr.Zero, IntPtr.Zero, 0x0002, ms, out res) != IntPtr.Zero;
}
// Win32_OperatingSystem over WMI for the same number costs ~100 ms and blocks for SECONDS
// while the box is busy booting a guest; this is the same counter, in microseconds.
public static double FreeRamMB() {
    var m = new MEMORYSTATUSEX();
    m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
    if (!GlobalMemoryStatusEx(ref m)) return 0;
    return m.ullAvailPhys / 1048576.0;
}
'@
}

# What each emulator window looked like before the group screen touched it, so Release (and
# closing the group window) can put it back. Per process, which is enough: only the process
# that changed a window ever has to change it back.
$script:TilesOriginal = @{}

# The two things that make separate windows read as ONE window: no title bar of their own,
# and OWNED by the group window so they always sit above it instead of disappearing behind
# it the moment its sidebar is clicked. Owner, not parent (SetParent/WS_CHILD): a child in
# another process needs AttachThreadInput before it can take the keyboard, while an owned
# top-level window keeps native focus - click a device and it just has the input.
# Both are undone by Restore-EmulatorFrames, which the group window calls on close BECAUSE
# an owned window is destroyed with its owner.
function Set-EmulatorFrame([IntPtr] $hwnd, [bool] $frameless, [IntPtr] $owner) {
    $key = [int64] $hwnd
    if (-not $script:TilesOriginal.ContainsKey($key)) {
        $r = New-Object Tiles.Win+RECT
        [void][Tiles.Win]::GetWindowRect($hwnd, [ref] $r)
        $script:TilesOriginal[$key] = @{
            Style = [int64][Tiles.Win]::GetWindowLongPtrW($hwnd, -16)   # GWL_STYLE
            Owner = [Tiles.Win]::GetWindowLongPtrW($hwnd, -8)           # GWL_HWNDPARENT
            Rect  = $r
        }
    }
    $orig = $script:TilesOriginal[$key]
    # WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX
    $style = if ($frameless) { ([int64]$orig.Style) -band (-bnot 0x00CF0000) } else { [int64]$orig.Style }
    # Compared before it is written, and that is not a micro-optimisation: a style change
    # SENDS WM_STYLECHANGING/WM_STYLECHANGED to the target window, i.e. a synchronous
    # SendMessage into the emulator's process, which does not return while the guest is busy.
    # The auto-arrange used to re-send it to every tile every 3 s, so any busy instance froze
    # the whole group screen. Callers also probe [Tiles.Win]::Responds first.
    try {
        if ([int64][Tiles.Win]::GetWindowLongPtrW($hwnd, -16) -ne $style) {
            # SetWindowLongPtrW is not exported on 32-bit Windows; the grid still works there,
            # the tiles just do not stay above the group window.
            [void][Tiles.Win]::SetWindowLongPtrW($hwnd, -16, [IntPtr]$style)
        }
    } catch { }
    try {
        if ([Tiles.Win]::GetWindowLongPtrW($hwnd, -8) -ne $owner) {
            [void][Tiles.Win]::SetWindowLongPtrW($hwnd, -8, $owner)
        }
    } catch { }
}

# Placement has to be IDEMPOTENT or the 3 s auto-arrange moves every window on every tick:
# the emulator corrects the size it is given (asked 522x921, got 521x901), that changes its
# aspect ratio, the next plan derives a slightly different width from the new ratio, so the
# centred x lands a few pixels off - and it moves again, for ever. Each of those moves is a
# real GL surface resize inside the guest, which is what made the emulators themselves crawl
# while the group screen was open. Exact equality on the position was the bug; a tolerance is
# the fix, and this is pure so manager.ps1 -SelfTest can assert it.
function Test-TileInPlace([int] $left, [int] $top, [int] $width, [int] $height,
                          [int] $x, [int] $y, [int] $w, [int] $h,
                          [int] $posTol = 12, [int] $sizeTol = 32) {
    return ([math]::Abs($left - $x) -le $posTol -and [math]::Abs($top - $y) -le $posTol -and
            [math]::Abs($width - $w) -le $sizeTol -and [math]::Abs($height - $h) -le $sizeTol)
}

# $Only = instance names, for taking ONE device back out of the group (its box was unticked)
# without releasing the rest. No names = release everything this process framed.
function Restore-EmulatorFrames([string[]] $Only) {
    $keys = @($script:TilesOriginal.Keys)
    if ($Only -and $Only.Count) {
        $want = @{}
        foreach ($w in (Get-EmulatorWindows)) { if ($Only -contains $w.Name) { $want[[int64]$w.Hwnd] = $true } }
        $keys = @($keys | Where-Object { $want.ContainsKey($_) })
    }
    $n = 0
    # Nothing saved, but a window is still sitting there with no title bar: that is what a
    # group screen that was killed instead of closed leaves behind (the saved styles died
    # with the process). Put the standard frame bits back - the same mask that was stripped -
    # so Release works from a fresh window instead of only in the process that framed them.
    if (-not $keys.Count) {
        foreach ($w in (Get-EmulatorWindows)) {
            if ($Only -and $Only.Count -and $Only -notcontains $w.Name) { continue }
            $st = [int64][Tiles.Win]::GetWindowLongPtrW($w.Hwnd, -16)
            if (($st -band 0x00C00000) -ne 0) { continue }   # already has a caption
            try {
                [void][Tiles.Win]::SetWindowLongPtrW($w.Hwnd, -8, [IntPtr]::Zero)
                [void][Tiles.Win]::SetWindowLongPtrW($w.Hwnd, -16, [IntPtr]($st -bor 0x00CF0000))
                [void][Tiles.Win]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $w.Left, $w.Top, $w.Width, $w.Height, 0x4060)
                $n++
            } catch { }
        }
        return $n
    }
    foreach ($key in $keys) {
        $h = [IntPtr]$key
        $o = $script:TilesOriginal[$key]
        $script:TilesOriginal.Remove($key)
        if (-not [Tiles.Win]::IsWindow($h)) { continue }
        try {
            # Owner first, then the frame: while a window is still owned, destroying the
            # owner would take it with it. Unconditional, and the cheap one of the two -
            # changing the owner sends no message to the target window.
            [void][Tiles.Win]::SetWindowLongPtrW($h, -8, $o.Owner)
            # The style change IS a blocking SendMessage into the guest's process, and this
            # runs while the group window is closing - a wedged instance would hang the close
            # with nothing on screen to explain it. Bounded: the window is already unowned, so
            # it survives regardless; it only keeps a missing title bar until Release windows
            # (or the next group screen's fallback above) puts it back.
            if (-not [Tiles.Win]::Responds($h, 1500)) {
                Write-Log "release: window $key is not answering - unowned and safe, but still frameless (press Release windows again later)" 'WARN'
                continue
            }
            [void][Tiles.Win]::SetWindowLongPtrW($h, -16, [IntPtr]([int64]$o.Style))
            [void][Tiles.Win]::SetWindowPos($h, [IntPtr]::Zero, $o.Rect.Left, $o.Rect.Top,
                                            ($o.Rect.Right - $o.Rect.Left), ($o.Rect.Bottom - $o.Rect.Top),
                                            0x4060)   # ASYNC | FRAMECHANGED | SHOWWINDOW
            $n++
        } catch { }
    }
    return $n
}

# "It is starting" is invisible to both adb and the window list: an instance queued on the
# boot gate has no window and no console port for up to a minute, so the group window showed
# it as off and a second click looked like the only option (measured: wa01 launched twice,
# 32 s apart, because the first click had nothing to show for itself). The launcher process
# is the missing evidence.
#
# A command line belonging to ANOTHER process can only be read over WMI, and that query costs
# ~100 ms on an idle box and SECONDS while a guest is booting (the WinMgmt RPC is starved by
# the same CPU the emulator is eating). The group screen asked for it TWICE per 3 s tick, on
# the UI thread - which is the second half of "the group screen hangs while instances start".
# So it is cached: 3 s while something is actually starting (the answer changes then), 15 s
# when nothing is (the only thing that can change is an instance started from outside this
# window, and its own window shows up in the list anyway). -Fresh is for the one place that
# must not be stale: deciding whether Start would launch a second copy.
$script:StartingCache = @{ At = [datetime]::MinValue; Val = @() }

# Which instance a command line is BOOTING, or '' for everything else. Pure, so
# manager.ps1 -SelfTest can assert it: this regex decides whether the group screen says
# "starting", and whether -Stop cancels a queued launcher - both of them kill or refuse to
# start things, so a wrong match here is expensive and invisible.
function Get-LauncherName([string] $commandLine) {
    if (-not $commandLine) { return '' }
    # Every other verb also carries -Name; only a bare boot means "starting".
    if ($commandLine -match '(?i)\s-(Stop|Check|Net|Paste|ClipboardBridge|Retune|Identity|Delete|Rename|Apk|Tile|Toolbars|KillAll|Launchers|Install|Requirements|SelfTest|Dialog|Logs)\b') { return '' }
    if ($commandLine -match '(?i)android\.ps1"?\s+-Name\s+"?([A-Za-z0-9_-]+)') { return $Matches[1] }
    if ($commandLine -match '(?i)run-([A-Za-z0-9_-]+)\.bat')                   { return $Matches[1] }
    return ''
}

# The launchers themselves, name AND pid, so -Stop can cancel one that has not started its
# emulator yet. Uncached on purpose: the two callers either kill what it returns or refresh
# the cache below with it, and both need the truth of this second.
function Get-LauncherProcesses([string] $avd = '') {
    $out = @()
    foreach ($p in (Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='cmd.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.ProcessId -eq $PID) { continue }
        $n = Get-LauncherName "$($p.CommandLine)"
        if (-not $n) { continue }
        if ($avd -and $n -ne $avd) { continue }
        $out += [pscustomobject]@{ Name = $n; ProcessId = $p.ProcessId }
    }
    return $out
}

function Get-StartingInstances([switch] $Fresh) {
    $ttl = if ($script:StartingCache.Val.Count) { 3 } else { 15 }
    if (-not $Fresh -and ([datetime]::UtcNow - $script:StartingCache.At).TotalSeconds -lt $ttl) {
        return $script:StartingCache.Val
    }
    $out = @(Get-LauncherProcesses | ForEach-Object Name)
    $script:StartingCache = @{ At = [datetime]::UtcNow; Val = @($out | Sort-Object -Unique) }
    return $script:StartingCache.Val
}

# One EnumWindows pass, done in C# ([Tiles.Win]::List): the device windows are the ones whose
# title carries the AVD name, and every other window of the toolbar class that is OWNED by one
# of them is that instance's toolbar. Matched by class, not by "any owned window": the emulator
# also owns invisible tooltip and popup windows, plus a stack of "Default IME" ones, and showing
# one of those would drop a stray grey rectangle on the desktop.
# The enumeration used to call back into a PowerShell scriptblock once per desktop window,
# which cost 130-250 ms EACH TIME - and the group screen's 3 s tick needed the list 4-6 times.
# That was most of "the group screen is slow"; the same pass in C# is ~2 ms.
function Get-EmulatorWindows {
    $all   = [Tiles.Win]::List()
    $owned = @($all | Where-Object { -not $_.Name })
    $out   = @()
    foreach ($d in $all) {
        if (-not $d.Name -or -not $d.Visible) { continue }
        # A minimised window reports -32000,-32000: its rect says nothing about its shape,
        # so fall back to the common 9:16 and let the caller restore it before placing.
        $out += [pscustomobject]@{
            Name   = $d.Name
            Port   = $d.Port
            Hwnd   = $d.Hwnd
            Left   = $d.Left
            Top    = $d.Top
            Width  = $d.Width
            Height = $d.Height
            Iconic = $d.Iconic
            Aspect = $(if (-not $d.Iconic -and $d.Width -gt 0 -and $d.Height -gt 0) { $d.Width / $d.Height } else { 0.5625 })
            # Hidden with the grid, not killed - Show-EmulatorToolbars puts them back.
            Toolbars = @($owned | Where-Object { $_.Owner -eq $d.Hwnd } |
                         ForEach-Object { @{ Hwnd = $_.Hwnd; Owner = $_.Owner; Visible = $_.Visible; W = $_.Width; H = $_.Height } })
        }
    }
    return @($out | Sort-Object Name)
}

# Pure, so manager.ps1 -SelfTest can assert it without a single instance running: how many
# columns x rows, and how big a cell, to make $count portrait windows as LARGE as possible
# inside the area. Every column count is tried rather than the usual ceil(sqrt(n)) because
# the windows are portrait on a landscape screen - 5 instances on 1707x929 fit best as 5x1,
# which sqrt would never pick.
function Get-GridPlan([int] $count, [int] $areaW, [int] $areaH, [double] $aspect = 0.5625, [int] $gap = 4) {
    if ($count -le 0) { return $null }
    if ($aspect -le 0) { $aspect = 0.5625 }
    $best = $null
    for ($cols = 1; $cols -le $count; $cols++) {
        # Trailing empty cells are not paid for: 5 in 3 columns is 3x2, not 3x3.
        $rows = [int][math]::Ceiling($count / $cols)
        $cw   = [int][math]::Floor(($areaW - $gap * ($cols + 1)) / $cols)
        $ch   = [int][math]::Floor(($areaH - $gap * ($rows + 1)) / $rows)
        if ($cw -lt 1 -or $ch -lt 1) { continue }
        $h = [math]::Min($ch, [int]($cw / $aspect))
        $w = [int]($h * $aspect)
        if ($w -lt 1 -or $h -lt 1) { continue }
        if (-not $best -or ($w * $h) -gt ($best.W * $best.H)) {
            $best = @{ Cols = $cols; Rows = $rows; W = $w; H = $h; CellW = $cw; CellH = $ch }
        }
    }
    if (-not $best) { return $null }
    # Below ~200 px wide the guest is arranged but no longer readable, which is the one
    # thing the ask was explicit about - so the caller can warn instead of pretending.
    $best.Tight = ($best.W -lt 200)
    return $best
}

# Places the windows and returns one row per instance it moved (so the caller can report
# "4 arranged, 3 x 2"). $Area is a Rectangle - the working area of a screen by default.
function Set-EmulatorGrid {
    param(
        [string[]] $Only,          # instance names; empty = every emulator window there is
        [switch]   $KeepToolbars,
        [int]      $Gap = 4,
        $Area,
        # The group window: tiles lose their title bars and become owned by it, so the set
        # reads as one window. Zero = leave every window as it is (plain tiling).
        [IntPtr]   $Owner = [IntPtr]::Zero,
        [switch]   $Frameless
    )
    $wins = @(Get-EmulatorWindows)
    if ($Only -and $Only.Count) { $wins = @($wins | Where-Object { $Only -contains $_.Name }) }
    if (-not $wins.Count) { return @() }

    if (-not $Area) {
        Add-Type -AssemblyName System.Windows.Forms
        $Area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    }

    # Restore first: a minimised window would be "arranged" off-screen at -32000.
    foreach ($w in $wins) { if ($w.Iconic) { [void][Tiles.Win]::ShowWindow($w.Hwnd, 9) } }   # SW_RESTORE

    $avg  = ($wins | ForEach-Object { $_.Aspect } | Measure-Object -Average).Average
    $plan = Get-GridPlan $wins.Count $Area.Width $Area.Height $avg $Gap
    if (-not $plan) { return @() }

    $placed = @()
    # Windows this pass left alone because their thread was not answering (see the probe
    # below). Read by the group screen so "one tile did not join the grid" has a reason in the
    # log instead of looking like a bug.
    $script:TilesSkipped = @()
    # Which windows this pass actually TOUCHED. The auto-arrange runs every 3 s, so on a
    # settled grid this has to come back empty - if it does not, every guest is rebuilding its
    # surface twenty times a minute for nothing (which is what "everything got slow while the
    # group screen was open" was).
    $script:TilesMoved = @()
    $i = 0
    foreach ($w in $wins) {
        $col = $i % $plan.Cols
        $row = [int][math]::Floor($i / $plan.Cols)
        $cx  = $Area.X + $Gap + $col * ($plan.CellW + $Gap)
        $cy  = $Area.Y + $Gap + $row * ($plan.CellH + $Gap)
        # Each instance keeps ITS own aspect - the screen profiles run from 480x854 to
        # 540x1170 - and is centred in the cell, so a mixed grid still lines up in rows.
        # For a tile the group screen has already framed, the ratio comes from the shape it
        # had BEFORE its title bar was stripped (saved in TilesOriginal), never from its
        # current shape: feeding the emulator's own size correction back into the next plan is
        # what made the grid re-place itself on every tick. See Test-TileInPlace.
        $framed = $script:TilesOriginal.ContainsKey([int64]$w.Hwnd)
        $a = if ($w.Aspect -gt 0) { $w.Aspect } else { $avg }
        if ($framed) {
            $o  = $script:TilesOriginal[[int64]$w.Hwnd].Rect
            $ow = $o.Right - $o.Left
            $oh = $o.Bottom - $o.Top
            if ($ow -gt 0 -and $oh -gt 0) { $a = $ow / $oh }
        }
        $h = [math]::Min($plan.CellH, [int]($plan.CellW / $a))
        $wd = [int]($h * $a)
        $x  = $cx + [int](($plan.CellW - $wd) / 2)
        # Already where it belongs? Leave it alone. The group screen re-runs this every 3 s
        # while instances boot, and moving a window that is already in place both flickers and
        # makes the guest rebuild its surface.
        if ((Test-TileInPlace $w.Left $w.Top $w.Width $w.Height $x $cy $wd $h) -and
            (($Owner -eq [IntPtr]::Zero -and -not $Frameless) -or $framed)) {
            $placed += [pscustomobject]@{ Name = $w.Name; Port = $w.Port; X = $x; Y = $cy; W = $w.Width; H = $w.Height }
            $i++
            continue
        }
        # Frame and owner before the move: dropping the title bar changes how much of the
        # window is the guest, and SWP_FRAMECHANGED below is what makes it take effect.
        # Only into a window that answers first, though: the style change is a blocking
        # SendMessage, and a guest in the middle of booting does not answer it for as long as
        # it is busy - the group screen sat there with no error and no way to click anything.
        # Skipped, not forced: the next tick is 3 s away and the cell stays reserved for it.
        if ($Owner -ne [IntPtr]::Zero -or $Frameless) {
            if (-not [Tiles.Win]::Responds($w.Hwnd, 200)) {
                $script:TilesSkipped += $w.Name
                $i++
                continue
            }
            Set-EmulatorFrame $w.Hwnd ([bool]$Frameless) $Owner
        }
        # SetWindowPos, not MoveWindow: it also raises the window, or the ones started
        # first sit behind this window and the grid looks half empty. SWP_ASYNCWINDOWPOS
        # (0x4000) is not decoration: a synchronous SetWindowPos into ANOTHER process's
        # window blocks the caller until that window's thread answers, and a booting or busy
        # emulator does not answer for seconds - which froze the group screen mid-layout.
        [void][Tiles.Win]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $x, $cy, $wd, $h, 0x4060)  # ASYNC|FRAMECHANGED|SHOWWINDOW
        $script:TilesMoved += $w.Name
        if (-not $KeepToolbars) {
            # Same reason: SetWindowPos SWP_HIDEWINDOW instead of ShowWindow, which is also
            # synchronous into the other process.
            foreach ($t in $w.Toolbars) { if ($t.Visible) { [void][Tiles.Win]::SetWindowPos($t.Hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x4087) } }  # ASYNC|HIDE|NOZORDER|NOMOVE|NOSIZE
        }
        $placed += [pscustomobject]@{ Name = $w.Name; Port = $w.Port; X = $x; Y = $cy; W = $wd; H = $h }
        $i++
    }
    # Plain, so it unrolls: every caller wraps the result in @() anyway, and returning
    # ,$placed instead hands them ONE element that happens to be an array - which read as
    # "arranged 1 window(s)" with two on the screen.
    return $placed
}

# The docked toolbar is tall and narrow (measured 54x508); the emulator's tooltip and popup
# windows share its class but are wide and flat, so shape is what tells them apart - and
# this works from a fresh process too, not only from the one that hid them.
function Show-EmulatorToolbars {
    $n = 0
    foreach ($w in (Get-EmulatorWindows)) {
        foreach ($t in $w.Toolbars) {
            if (-not $t.Visible -and $t.W -lt 120 -and $t.H -gt (2 * $t.W)) {
                # ASYNC|SHOWWINDOW|NOZORDER|NOMOVE|NOSIZE, for the same reason as the hide.
                [void][Tiles.Win]::SetWindowPos($t.Hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x4047)
                $n++
            }
        }
    }
    return $n
}

# ============================================================ screen -> guest camera
# "when an app asks for the camera, let me draw a rectangle on MY screen and let the guest
# see that" - i.e. scan the WhatsApp Web QR that is on the host monitor from inside the
# emulator, with no webcam and no virtual-camera driver installed.
#
# What the emulator gives us, all probed on wa02 before any of this was written:
#   emulator -help-camera-back  ->  emulated | webcam<N> | environment | imagefile:<f>
#                                   | videofile:<f> | image360:<f> | none
#   imagefile:<f> is re-read at every CAMERA SESSION START, not per frame: swapping the
#   file while the camera app was open changed nothing, force-stopping and reopening the
#   app showed the new picture. So the feeder below keeps the file fresh and the guest
#   picks it up whenever something opens the camera - which is exactly when it matters.
#   The path is passed at launch, so an instance has to be (re)started once to point its
#   camera at this file. `adb emu virtualscene-image wall <f>` can swap an image at
#   runtime, but only in the 3D virtual-scene camera, where the picture is a poster on a
#   wall the guest has to be aimed at - useless for an unattended QR scan.
#   A 1280x960 source came through crisp but downscaled; 640x480 is what the device
#   reports, so that is the frame size.
#
# The picture does NOT live next to the scripts here, and that is not a preference: the
# emulator cannot take a camera image whose path contains a space. Measured on wa02, same
# instance, same picture, twice -
#   -camera-back "imagefile:C:\Users\user\Downloads\andriod sum\camera.png"
#        qemu.sf.fake_camera=front (so the flag WAS accepted), and every open of the back
#        camera fails: "Can't connect to the camera", logcat CAM_CaptureModule "Could not
#        open camera", Camera2OneCameraOpenerImpl onError.
#   -camera-back imagefile:C:\Users\user\camtest.png
#        the preview shows the screen region.
# Quoting does not save it, and neither does the 8.3 short name: 8dot3 is off for this very
# folder, GetShortPathName returns "C:\Users\user\DOWNLO~1\andriod sum\camera.png" - still a
# space. So the frame is written to a path that cannot have one. camera.ini stays next to the
# scripts either way: only these scripts read it, and it is the thing worth editing by hand.
$CamFile = Join-Path $PSScriptRoot 'camera.png'
if ($CamFile -match ' ') {
    # LOCALAPPDATA first (per user, no elevation); ProgramData is the guaranteed fallback -
    # it is fixed at C:\ProgramData on every Windows, so this loop always ends with a
    # space-free path even for a user profile that has a space in it.
    foreach ($alt in @((Join-Path $env:LOCALAPPDATA 'avd-screencam'), 'C:\ProgramData\avd-screencam')) {
        if ($alt -notmatch ' ') { $CamFile = Join-Path $alt 'camera.png'; break }
    }
}
$CamIni  = Join-Path $PSScriptRoot 'camera.ini'

# WinForms lays this project's dialogs out in logical pixels and this box runs 2560x1440 at
# 150%, so the scripts are deliberately NOT DPI aware (see the group-view notes). Capturing
# is the one thing that must be: Graphics.CopyFromScreen reads PHYSICAL pixels, so a region
# picked in logical ones lands on the wrong part of the screen, 1.5x off. Both the picker
# and the feeder run in their own process and call this before creating any window, so the
# rectangle they store and the pixels they copy are in the same coordinate space.
function Set-DpiAware {
    try {
        Add-Type -Name Dpi -Namespace Cam -MemberDefinition @'
[DllImport("shcore.dll")]  public static extern int SetProcessDpiAwareness(int v);
[DllImport("user32.dll")]  public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
        # 2 = PER_MONITOR_DPI_AWARE. Fails on anything older than 8.1, hence the fallback.
        if ([Cam.Dpi]::SetProcessDpiAwareness(2) -ne 0) { [void][Cam.Dpi]::SetProcessDPIAware() }
        return $true
    } catch { return $false }
}

function Get-CamRegion {
    $h = Read-Ini $CamIni
    if (-not $h.W -or [int] $h.W -lt 8 -or [int] $h.H -lt 8) { return $null }
    [pscustomobject]@{
        X = [int] $h.X; Y = [int] $h.Y; W = [int] $h.W; H = [int] $h.H
        # Fraction of the frame the capture is scaled to fill. The QR has to be COMPLETE in
        # the frame to decode, so it is fitted with a margin rather than cropped to fill -
        # and it is a knob because how much of the frame a scanner actually looks at is the
        # app's business, not ours (the stock camera app's preview crops from the left).
        Fit    = $(if ($h.Fit)    { [double] $h.Fit } else { 0.92 })
        FrameW = $(if ($h.FrameW) { [int] $h.FrameW } else { 640 })
        FrameH = $(if ($h.FrameH) { [int] $h.FrameH } else { 480 })
    }
}

function Save-CamRegion([int] $x, [int] $y, [int] $w, [int] $h, $keep) {
    $out = @(
        '# The screen rectangle the guest camera shows (physical pixels, set by'
        '# android.ps1 -PickRegion / the manager window > Screen scan). Delete this file'
        '# to give the instances their plain emulated camera back on the next start.'
        '#   Fit             how much of the camera frame the capture fills (0.5-1.0).'
        '#                   Lower it if a scanner only looks at the middle of the frame.'
        '#   FrameW/FrameH   camera frame size. The device reports 640x480.'
        ''
        "X = $x", "Y = $y", "W = $w", "H = $h"
        "Fit = $(if ($keep) { $keep.Fit } else { 0.92 })"
        "FrameW = $(if ($keep) { $keep.FrameW } else { 640 })"
        "FrameH = $(if ($keep) { $keep.FrameH } else { 480 })"
    )
    $out | Set-Content -LiteralPath $CamIni -Encoding ASCII
    return $CamIni
}

# Pure, so manager.ps1 -SelfTest can assert it: where a $srcW x $srcH capture lands inside a
# $dstW x $dstH frame when it is scaled to fill $fit of it, aspect kept, centred.
function Get-CamFit([int] $srcW, [int] $srcH, [int] $dstW, [int] $dstH, [double] $fit = 0.92) {
    if ($srcW -le 0 -or $srcH -le 0) { return $null }
    if ($fit -le 0 -or $fit -gt 1)   { $fit = 0.92 }
    $scale = [math]::Min(($dstW * $fit) / $srcW, ($dstH * $fit) / $srcH)
    $w = [int][math]::Max(1, [math]::Round($srcW * $scale))
    $h = [int][math]::Max(1, [math]::Round($srcH * $scale))
    [pscustomobject]@{
        X = [int][math]::Round(($dstW - $w) / 2); Y = [int][math]::Round(($dstH - $h) / 2)
        W = $w; H = $h
    }
}

# One frame: copy the region off the screen, letterbox it onto a white frame, replace
# $CamFile atomically-ish. Written to a temp name and moved because the emulator opens the
# file itself; a half-written PNG would be a dead camera instead of a stale one.
function Write-CamFrame($region) {
    if (-not $region) { return $false }
    Add-Type -AssemblyName System.Drawing
    # $CamFile may be outside the project (see the space-in-the-path note above), so its
    # folder is this function's job - nothing else creates it.
    $camDir = Split-Path -Parent $CamFile
    if (-not (Test-Path -LiteralPath $camDir)) { New-Item -ItemType Directory -Force $camDir | Out-Null }
    $box = Get-CamFit $region.W $region.H $region.FrameW $region.FrameH $region.Fit
    $shot = $null; $frame = $null
    try {
        $shot = New-Object System.Drawing.Bitmap $region.W, $region.H
        $g1   = [System.Drawing.Graphics]::FromImage($shot)
        try { $g1.CopyFromScreen($region.X, $region.Y, 0, 0, $shot.Size) } finally { $g1.Dispose() }
        $frame = New-Object System.Drawing.Bitmap $region.FrameW, $region.FrameH
        $g2    = [System.Drawing.Graphics]::FromImage($frame)
        try {
            $g2.Clear([System.Drawing.Color]::White)
            # A QR wants the sharpest downscale available: bicubic blurs module edges into
            # grey, NearestNeighbor keeps black black.
            $g2.InterpolationMode = 'NearestNeighbor'
            $g2.PixelOffsetMode   = 'Half'
            $g2.DrawImage($shot, $box.X, $box.Y, $box.W, $box.H)
        } finally { $g2.Dispose() }
        $tmp = "$CamFile.tmp"
        $frame.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        Move-Item -LiteralPath $tmp -Destination $CamFile -Force
        return $true
    } catch { return $false }
    finally {
        if ($shot)  { $shot.Dispose() }
        if ($frame) { $frame.Dispose() }
    }
}

# ============================================================ .xapk / .apks bundles
# An XAPK (and an APKS, and an APKM) is a plain zip: one base .apk, the split .apk parts
# next to it, and sometimes an Android/obb/<pkg>/*.obb tree the app expects on the sdcard.
# `adb install` refuses all of it; `adb install-multiple` takes the parts.
function Test-AppBundle([string] $path) { return ($path -match '\.(xapk|apks|apkm|zip)$') }

# The .apk parts and .obb files inside $path, extracted under $dest. Pure zip work, no adb,
# so -SelfTest can unpack a bundle it built itself and assert the lists.
function Expand-AppBundle([string] $path, [string] $dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force $dest | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $path).Path, $dest)
    # Biggest first: install-multiple wants the base apk as the first part.
    $apks = @(Get-ChildItem -LiteralPath $dest -Recurse -Filter '*.apk' -File | Sort-Object Length -Descending)
    $obbs = @(Get-ChildItem -LiteralPath $dest -Recurse -Filter '*.obb' -File)
    [pscustomobject]@{
        Apks   = @($apks | ForEach-Object { $_.FullName })
        Obbs   = @($obbs | ForEach-Object { $_.FullName })
        # <pkg> out of Android/obb/<pkg>/x.obb, so the push target needs no aapt.
        ObbPkg = $(if ($obbs.Count) { Split-Path -Leaf (Split-Path -Parent $obbs[0].FullName) } else { '' })
        Dir    = $dest
    }
}

# Pure: which of $apks to hand install-multiple. Several ABI splits in one bundle is the
# common real failure - this image lists x86_64, x86, arm64-v8a and armeabi-v7a, so nothing
# filters them out by itself and adb answers with a mismatch instead. Keep the base,
# everything that is not an ABI split, and exactly ONE ABI, preferred in the order the guest
# runs best (native x86_64 first, then translated arm64).
# ponytail: matched by file name, because reading the ABI out of a split needs aapt and the
# SDK does not guarantee it. Bundles from apkpure/apkmirror all name them config.<abi>.apk.
function Select-BundleApks([string[]] $apks) {
    $abiRe     = '(?i)(x86_64|x86|arm64[_-]v8a|armeabi[_-]v7a|armeabi|mips)'
    $abiSplits = @($apks | Where-Object { (Split-Path -Leaf $_) -match "config\.$abiRe\.apk$" })
    if ($abiSplits.Count -le 1) { return @($apks) }
    $keep = $null
    foreach ($pref in @('x86_64', 'arm64[_-]v8a', 'armeabi[_-]v7a', 'x86', 'armeabi')) {
        $hit = @($abiSplits | Where-Object { (Split-Path -Leaf $_) -match "config\.$pref\.apk$" })
        if ($hit.Count) { $keep = $hit[0]; break }
    }
    if (-not $keep) { $keep = $abiSplits[0] }
    return @($apks | Where-Object { $abiSplits -notcontains $_ -or $_ -eq $keep })
}
