# Engine behind new-instance.bat and the generated run-<name>.bat launchers.
# Not meant to be double-clicked directly.
#
#   -New <name>     create an AVD, tune it, assign a port, write run-<name>.bat
#   -Name <name>    boot that instance. It does NOT open WhatsApp - see the "no automation"
#                   note at the bottom of this file - tap the icon in the window yourself.
#   -Check          device identity, Google Play, capabilities
#   -Net            network diagnostics inside the guest
#   -Paste          paste the Windows clipboard into the focused guest field
#   -ClipboardBridge  make Ctrl+C / Ctrl+V / Ctrl+X work inside the emulator windows.
#                   Runs hidden for as long as any instance is up; a boot starts it.
#   -Stop           graceful shutdown; waits until it is really down
#   -Cold           ignore the snapshot and cold boot (already the default)
#   -Snapshot       resume from / save the quick-boot snapshot. Slower on this box, by a
#                   lot: see the -Snapshot note in param() for the measurements.
#   -FileBackedRam  put guest RAM back in a file on disk. This is what froze everything.
#   -Retune         re-apply the tuned config.ini values
#   -Identity       give this instance its own screen size, timezone, region, phone
#                   number and device name (derived from its name; identity.ini)
#   -Device/-Region/-Phone   pick that profile instead of deriving it (with -New or
#                   -Identity). The manager window asks for these in a dialog.
#   -Tile           arrange every running emulator window into a grid, sized by how many
#                   are up (-Toolbars keeps the side toolbars; on its own it restores them)
#   -Apk <file>     install that APK into -Name (boots it first if it is not up). An
#                   .xapk/.apks/.apkm bundle is unpacked and installed with its splits,
#                   and any Android/obb payload inside it is pushed to the sdcard.
#   -PickRegion     drag a rectangle on the Windows screen; every instance's camera then
#                   shows that region, so a QR on the host screen can be scanned from
#                   inside the guest. Starts the feeder below and needs one restart of an
#                   instance that is already up.
#   -ScreenCam      the feeder that keeps that picture fresh. Runs hidden while any
#                   instance is up; a boot starts it. -PickRegion is what you call.
#                   -ScreenCam -Check writes one frame and prints where it landed.
#   -ResetApp       wipe WhatsApp's data in -Name and start it fresh, for when it is
#                   stuck on "Download the official WhatsApp to continue". Needs -Force:
#                   it erases that instance's session and its local chat history.
#   -Requirements   what is installed / missing / too slow on this machine, then stop
#   -Install        download the emulator + system image now
#   -Ram / -Cores   override per instance (needs -Retune or -New to take effect)
#   -Dns            override DNS (default 8.8.8.8,1.1.1.1)
#   -KillAll        stop every instance and kill anything this project left running
#                   (-Force skips the graceful shutdown, and so loses the snapshots)
#   -Launchers      rewrite every run-<name>.bat
#
# Nothing here prints to a console any more - every run appends to logs\<name>.log and
# a failure also raises one dialog. The manager window has a live log viewer.

param(
    [string] $New,
    [string] $Clone,
    [string] $As,
    [string] $Rename,
    [switch] $Delete,
    [switch] $Force,
    [string] $Name  = 'wa01',
    # 2048, not 1536: this image has a floor and the emulator silently raises anything
    # lower ("INFO | Increasing RAM size to 2048MB"), so a 1536 config.ini was a lie -
    # ram.img on disk measured 2048 MB either way. Asking for less saves nothing.
    [int]    $Ram   = 2048,
    # 2, not 4. This box has 6 physical cores, so at 4 vCPU each two instances already
    # oversubscribe it and three fight; a chat app needs neither. Free to change now that
    # nothing resumes from a snapshot - a core count change used to invalidate it.
    [int]    $Cores = 2,
    # The emulator otherwise inherits whichever DNS server Windows lists first. This box
    # has two live adapters with different servers (Ethernet 192.168.5.30/172.20.x and
    # Wi-Fi 192.168.1.1), so inheriting picks the wrong one and the guest ends up
    # "connected, no internet". Pinning it is the fix. Use -Dns 192.168.1.1 if the
    # router intercepts outbound port 53.
    [string] $Dns   = '8.8.8.8,1.1.1.1',
    # 'host' + -NoVulkan. The emulator rejects only the VULKAN half of this driver -
    #   "hasSufficientHostVulkanDriver: unsupported driver version (457.51.0,
    #    min required: 553.35.0)"
    # - and its reaction is to drop the whole renderer to lavapipe + SwiftShader, i.e.
    # CPU. Plain 'host' is worse still: it keeps Vulkan on, the driver wedges, and the
    # guest blocks on the dead renderer forever (black screen, adb stuck at "offline").
    # Turning Vulkan OFF takes the broken half out and leaves OpenGL, which this driver
    # runs fine. Measured on 3794xa, cold boot to sys.boot_completed:
    #     auto (lavapipe + SwiftShader)  64 s
    #     host + Vulkan                  never - wedges black
    #     host, Vulkan off               15 s   <- and the log then reads
    #        "OpenGL ES Translator (GeForce RTX 2080/PCIe/SSE2)" instead of SwiftShader
    # Android 11 does not need Vulkan; SurfaceFlinger and WhatsApp are GLES.
    #
    # ValidateSet is not decoration. `-gpu angle_indirect` is NOT a mode in 37.1.11
    # and the emulator only whispers about it -
    #   "ERROR | gpuChoiceBasedOnGpuOptions: Selected GPU option '...' is not valid,
    #    switching to 'auto' mode"
    # - then boots on the software renderer, so a typo costs 4x speed and nothing
    # visibly fails. These six are what `emulator -help-gpu` actually accepts.
    [ValidateSet('auto', 'host', 'software', 'lavapipe', 'swiftshader', 'swangle')]
    [string] $Gpu   = 'host',
    # Drop this switch once the NVIDIA driver is past 553.35 - then host Vulkan is
    # supported and worth having back.
    [switch] $Vulkan,
    # THE fix for "the emulators do not work, they freeze". QuickbootFileBacked (on by
    # default in the emulator) does not merely save the snapshot to ram.img - it makes
    # ram.img the guest's RAM, a file mapping. On D:, an ST2000DM008, which is an SMR
    # drive, that means every guest memory access that is not resident is a random read
    # on the worst possible disk. Measured with three instances idle and 20 GB of host
    # RAM free:
    #     qemu working set   2-48 MB  (of ~800 MB committed - trimmed continuously)
    #     page faults        ~1500/s each, 2.6 MILLION lifetime
    #     Memory\Pages Input 184/s     (hard faults, so real disk reads)
    #     Avg. Disk sec/Read 0.43 s    at 21 reads/s - the disk is the whole ceiling
    # An `adb shell getprop` never returned in five minutes. With the feature off, guest
    # RAM is ordinary private memory and stays in the 20 GB that is free anyway; the
    # snapshot becomes one sequential read at start and one sequential write at -Stop,
    # which is exactly what a spinning disk is good at.
    # The cost is honest: -Stop goes from ~3 s back to ~30-60 s, because the RAM really
    # has to be written now. Pass -FileBackedRam to go back to instant saves and a
    # frozen emulator.
    [switch] $FileBackedRam,
    # Quick-boot is OFF by default here, which sounds backwards until it is measured.
    # With the file-backed trick gone (see above), resuming means really reading
    # hw.ramSize bytes off an SMR disk, and writing them back on every shutdown. Same
    # box, same instance, three runs each:
    #     resume from snapshot   114 s, 127 s, 220 s   + a ~60 s write on -Stop
    #     full cold boot         27.6 s                + nothing to write on -Stop
    # So the "5.7 s quick boot" measured before was never free - it was instant because
    # the disk reads were deferred into the running guest, which is precisely the freeze.
    # A cold boot loses only the RAM state: userdata, the Google account and every
    # WhatsApp session live in userdata.img and are untouched.
    # Pass -Snapshot to go back to save-and-resume (and put the 2 GB of I/O back).
    [switch] $Snapshot,
    [switch] $Check,
    [switch] $Net,
    [switch] $Paste,
    # The keyboard bridge, see the -ClipboardBridge section. Started by a boot, one per
    # desktop; running it by hand a second time exits straight away.
    [switch] $ClipboardBridge,
    [switch] $Cold,
    [switch] $Stop,
    [switch] $Retune,
    # Write identity.ini and push the screen part of it into config.ini. Runtime parts
    # (timezone, region, phone number, device name) are applied on every boot anyway.
    [switch] $Identity,
    # Panic button - see kill-all.bat. Needs no -Name: it sweeps every instance.
    [switch] $KillAll,
    # Rewrite every run-<name>.bat. Needed once after the launchers changed shape (they
    # are hidden now), and any time one is deleted.
    [switch] $Launchers,
    # The profile of a NEW instance, or of an existing one together with -Identity. All
    # three empty = derive everything from the instance name, which is what it always did.
    #   -Device 'Redmi Note 9'  one of $Screens in common.ps1: screen w/h/dpi plus the name
    #                           Android and Bluetooth report. Any other text only renames.
    #   -Region 964-770         <country code>-<operator prefix> of one of $Personas;
    #                           timezone, locale and the SIM number all follow from it.
    #   -Phone 9647515404553    the exact number this instance's SIM answers. Wins over
    #                           -Region, which would otherwise generate one.
    [string] $Device,
    [string] $Region,
    [string] $Phone,
    # Arrange every emulator window that is up into a grid on the primary screen, sized by
    # how many there are, then stop. Needs no -Name and no booted instance: it is window
    # placement (see the "group view" section of common.ps1), so it also works on an
    # instance that is still booting. -Name limits it to one, -Toolbars keeps the side
    # toolbars visible (they overlap the neighbour in a tight grid, so they are hidden by
    # default; -Toolbars on its own with no -Tile puts them all back).
    [switch] $Tile,
    [switch] $Toolbars,
    # Install this APK into -Name, then stop. The group screen runs one of these per checked
    # instance, which is "upload an app and it lands on all of them". An instance that is
    # not up boots first. An .xapk / .apks / .apkm bundle is unpacked first and installed
    # with `adb install-multiple`; see the -Apk section.
    [string] $Apk,
    # Screen -> guest camera. -PickRegion draws the selector and stores the rectangle,
    # -ScreenCam is the hidden feeder that keeps the picture fresh (a boot starts it).
    # Both need no -Name: one region serves every instance.
    [switch] $PickRegion,
    [switch] $ScreenCam,
    # Wipe WhatsApp's data in this instance (adb shell pm clear) before launching it -
    # the way out of the "Download the official WhatsApp to continue" screen. See the
    # -ResetApp section further down for what that screen actually is. -Force required.
    [switch] $ResetApp,
    # Download the emulator + system image now, instead of on the first boot that needs
    # them. Nothing else here can install the command-line tools themselves.
    [switch] $Install,
    # What is installed, missing or too slow on this machine, then stop. Same rows the
    # manager window shows under Requirements; safe to run when nothing is installed yet.
    [switch] $Requirements
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Paths, device profiles and the requirements check are shared with manager.ps1 and live in
# common.ps1. This runs before the trap further down exists, and a hidden launcher has no
# console, so it reports itself or the failure would be completely silent.
try { . (Join-Path $here 'common.ps1') }
catch {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [void][System.Windows.Forms.MessageBox]::Show(
            "common.ps1 has to sit next to android.ps1 and it is missing or broken:`n`n$($_.Exception.Message)",
            'Android instances', 'OK', 'Error')
    } catch { }
    throw
}

# Every path now comes from settings.ini (manager window > Settings), defaulting to what
# this project was measured on. D: is a 7200rpm ST2000DM008, C: is the NVMe but has ~6 GB
# free. Snapshot resume reads hw.ramSize bytes off this disk, so moving AvdHome to an SSD is
# the biggest single speed win available - see the note at the bottom of this file.
$Settings = Get-Settings
$Sdk      = $Settings.SdkRoot
$Jdk      = $Settings.JdkRoot
$AvdHome  = $Settings.AvdHome
# android-30 is the oldest Play-certified image that ships arm64 translation, so
# arm64-only APKs like WhatsApp install with no translator hack, and it boots lighter
# than 33/34. "playstore" (not plain "google_apis") is what makes the device
# Play-certified, so the Play Store app is present and sign-in works.
$Image    = $Settings.Image
# 'android-30' out of the package id, so a different image in settings.ini also writes the
# right target into every <name>.ini instead of claiming 30 for ever.
$Target   = Get-ImageTarget $Settings
$Pkg      = 'com.whatsapp'

$emulator   = "$Sdk\emulator\emulator.exe"
$adb        = "$Sdk\platform-tools\adb.exe"
$sdkmanager = "$Sdk\cmdline-tools\latest\bin\sdkmanager.bat"
$avdmanager = "$Sdk\cmdline-tools\latest\bin\avdmanager.bat"
$imageDir   = Get-ImageDir $Settings

$env:JAVA_HOME        = $Jdk
$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_HOME     = $Sdk
$env:ANDROID_AVD_HOME = $AvdHome
$env:Path             = "$Jdk\bin;$Sdk\emulator;$Sdk\platform-tools;$env:Path"

# ============================================================ logging
# The launchers open no console any more, so anything that is not in this file is lost.
# Start-Transcript rather than a Write-Host wrapper: it also captures the ~50 Write-Host
# calls already in this file, native command output and the exception text, for free.
$LogDir = Join-Path $here 'logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null

# One file per instance, because "which emulator is broken" is the first question.
$LogName = $Name
if     ($KillAll)      { $LogName = '_killall' }
elseif ($Launchers)    { $LogName = '_launchers' }
elseif ($Requirements) { $LogName = '_requirements' }
elseif ($Tile -or $Toolbars) { $LogName = '_tile' }
elseif ($ClipboardBridge)    { $LogName = '_clipboard' }
elseif ($PickRegion -or $ScreenCam) { $LogName = '_camera' }
elseif ($Install)      { $LogName = '_install' }
elseif ($New)          { $LogName = $New }
elseif ($Clone)        { $LogName = $Clone }
$LogName = $LogName -replace '[^A-Za-z0-9_.-]', '_'
$LogFile = Join-Path $LogDir "$LogName.log"

# One rollover, not a rotation scheme: 4 MB is hundreds of boots, and the viewer still
# opens it instantly.
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 4MB) {
    Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force -ErrorAction SilentlyContinue
}
# Two launchers for one instance cannot append to the same transcript, and losing the log
# is not a reason to refuse to boot: fall back to a per-process file, then to no file.
try { Start-Transcript -LiteralPath $LogFile -Append -Force | Out-Null }
catch {
    $LogFile = Join-Path $LogDir "$LogName.$PID.log"
    try { Start-Transcript -LiteralPath $LogFile -Append -Force | Out-Null } catch { }
}

# Write-Log lives in common.ps1 (dot-sourced above): the manager window logs with the same
# timestamps, and one format means the viewer's WARN/ERROR colouring matches both files.

# The emulator holds its redirected log open for writing, so plain Get-Content fails with
# "being used by another process" exactly when the contents matter most.
function Read-SharedText([string] $path, [int] $tailLines = 0) {
    if (-not (Test-Path $path)) { return '' }
    $text = ''
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try { $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
    if ($tailLines -le 0) { return $text }
    $lines = $text -split "`r?`n"
    # The file ends in a newline, so the last element is empty and would cost one real
    # line of the tail.
    if ($lines.Count -gt 1 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    if ($lines.Count -le $tailLines) { return $text }
    return (($lines[($lines.Count - $tailLines)..($lines.Count - 1)]) -join "`n")
}

# The rows Test-Requirements produces, into the log. Same report the manager window shows
# under Requirements, so "it does not start" can be answered from the log alone.
function Write-Requirements {
    Write-Log "=== requirements (settings: $SettingsFile) ==="
    foreach ($k in $Settings.Keys) { Write-Log ('  {0,-8} {1}' -f $k, $Settings[$k]) }
    $bad = 0
    foreach ($r in (Test-Requirements $Settings)) {
        $lvl = 'OK'
        if     ($r.State -eq 'warn') { $lvl = 'WARN' }
        elseif ($r.State -ne 'ok')   { $lvl = 'ERROR'; $bad++ }
        Write-Log ('  {0,-18} {1,-8} {2}' -f $r.Item, $r.State, $r.Detail) $lvl
        if ($r.Hint) { Write-Log "      -> $($r.Hint)" }
    }
    Write-Log ('{0} requirement(s) not met' -f $bad) $(if ($bad) { 'WARN' } else { 'OK' })
    return $bad
}

# Every host condition that has actually made an instance freeze on this box, in one line.
function Write-HostState([string] $tag) {
    try {
        $os     = Get-CimInstance Win32_OperatingSystem
        $freeMb = [int]($os.FreePhysicalMemory / 1KB)
        $drv    = $AvdHome.Substring(0, 2)
        $disk   = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drv'"
        $freeGb = [math]::Round($disk.FreeSpace / 1GB, 1)
        $cpu    = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $qemus  = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue)
        Write-Log ("host {0}: cpu {1}% | RAM free {2} MB | {3} free {4} GB | emulators up {5}" -f
                   $tag, $cpu, $freeMb, $drv, $freeGb, $qemus.Count)
        if ($freeMb -lt 1500) { Write-Log '  RAM is nearly gone - the guest swaps and looks frozen' 'WARN' }
        # Guest RAM is real host RAM now instead of a file on the disk, which is the whole
        # fix - but it also means each instance costs ~3 GB of commit that used to be free.
        # On 32 GB that is the new ceiling: about 7 instances at once, not 13.
        $commitMb = [int](($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1KB)
        $limitMb  = [int]($os.TotalVirtualMemorySize / 1KB)
        Write-Log ('  committed {0} MB of {1} MB' -f $commitMb, $limitMb)
        if ($commitMb -gt ($limitMb * 0.8)) {
            Write-Log '  commit is over 80% - stop an instance before starting another, or Windows starts paging guests out' 'WARN'
        }
        if ($freeGb -lt 5)    { Write-Log "  under 5 GB left on $drv - a cold boot has nowhere to write ram.img" 'WARN' }
        $logical = [int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
        if ($qemus.Count * $Cores -gt $logical) {
            Write-Log ("  {0} emulators x {1} vCPU exceeds {2} logical CPUs - guests fight over the host and stutter. Retune the busy ones to 2 cores." -f
                       $qemus.Count, $Cores, $logical) 'WARN'
        }
    } catch { Write-Log "host state unavailable: $($_.Exception.Message)" 'WARN' }
}

# Every failure signature this project has actually hit, with what it means. Matched
# against the emulator's own output, which used to be thrown away entirely.
$EmuSignatures = [ordered]@{
    'hasSufficientHostVulkanDriver'       = 'the NVIDIA driver is too old for Vulkan. Harmless here - this script already boots with Vulkan off; pass -Vulkan only after the driver is past 553.35.'
    'Google SwiftShader'                  = 'rendering fell back to the CPU: 4x slower boot and a crawling UI. Check the -Gpu value and the driver.'
    "is not valid, switching to 'auto'"   = 'an invalid -Gpu name was passed, so the emulator silently used the software renderer.'
    'Error -1 from the snapshot callback' = 'the quick-boot snapshot does not match the current settings, so this was really a cold boot. Boot once with -Cold, then -Stop, to rewrite it.'
    'Increasing RAM size'                 = 'hw.ramSize is below the floor of this system image and was raised silently - asking for less saves nothing.'
    'Failed to load opengl32sw'           = 'the software OpenGL fallback DLL is missing from the emulator install.'
    'UpdateLayeredWindowIndirect failed'  = 'the host renderer is wedged. This is the black window; adb stays at "offline" forever.'
    'requires hardware acceleration'      = 'no CPU acceleration: Windows Hypervisor Platform is off, or another hypervisor took it.'
    'Not enough disk space'               = 'the AVD disk is full.'
    'Address already in use'              = 'something else already holds this console port.'
    'Failed to open the HAX device'       = 'HAXM is absent. Harmless while WHPX works.'
    'Failed to create Vulkan instance'    = 'Vulkan init failed. Boot with Vulkan off (the default here).'
    'out of memory'                       = 'the host ran out of RAM for this guest.'
}

# Called only after something failed, so it can afford to be slow and loud.
function Write-Diagnosis([string] $avd) {
    Write-Log '---- diagnosis ---------------------------------------------------' 'WARN'
    Write-HostState 'at failure'
    try {
        $av = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(360|ZhuDongFangYu|QHSafe|QHActiveDefense)' })
        if ($av.Count) {
            Write-Log ("360 Total Security is running ({0}). It hooks qemu file I/O - whitelist {1} and {2} if boots stall." -f
                       (($av | ForEach-Object Name | Select-Object -Unique) -join ', '), $Sdk, $AvdHome) 'WARN'
        }
    } catch { }
    # These four are what identified the freeze once and would identify it again: a guest
    # that is hard-faulting its own RAM off the disk shows a huge Pages Input/sec and a
    # read latency in hundreds of milliseconds, while RAM is free and the CPU is idle.
    try {
        $c = (Get-Counter -Counter '\PhysicalDisk(_total)\Current Disk Queue Length',
                                   '\PhysicalDisk(_total)\Avg. Disk sec/Read',
                                   '\Memory\Pages Input/sec',
                                   '\Memory\Available MBytes' -MaxSamples 1 -ErrorAction Stop).CounterSamples
        foreach ($s in $c) { Write-Log ('{0} = {1:N2}' -f ($s.Path -replace '^.*\\([^\\]+\\[^\\]+)$', '$1'), $s.CookedValue) }
        $lat = ($c | Where-Object { $_.Path -like '*sec/read*' }).CookedValue
        $pin = ($c | Where-Object { $_.Path -like '*pages input*' }).CookedValue
        if ($lat -gt 0.05) { Write-Log ('disk reads are taking {0:N0} ms each (healthy is 5-15 ms) - the disk is the ceiling, nothing else' -f ($lat * 1000)) 'WARN' }
        if ($pin -gt 50)   { Write-Log 'the guests are paging their own RAM off the disk. Boot without -FileBackedRam (the default now) so guest RAM stays in host memory.' 'WARN' }
    } catch { }

    foreach ($suffix in @('-emulator.log', '-emulator.err.log')) {
        $f    = Join-Path $LogDir "$avd$suffix"
        $text = Read-SharedText $f
        if (-not $text.Trim()) { Write-Log "nothing in $suffix" ; continue }
        $hits = @()
        foreach ($k in $EmuSignatures.Keys) { if ($text -like "*$k*") { $hits += $k } }
        if ($hits.Count) {
            Write-Log "known problems in $avd$suffix :" 'WARN'
            foreach ($h in $hits) { Write-Log "  * $h" 'WARN'; Write-Log "      -> $($EmuSignatures[$h])" 'WARN' }
        } else {
            Write-Log "no known failure signature in $avd$suffix"
        }
        Write-Log "last 25 lines of $avd$suffix :"
        foreach ($l in ((Read-SharedText $f 25) -split "`r?`n")) { if ($l.Trim()) { Write-Log "  | $l" } }
    }
    Write-Log "full log: $LogFile" 'WARN'
    Write-Log '-----------------------------------------------------------------' 'WARN'
}

# A hidden launcher has no console to print a stack trace to, so the only two places a
# failure can still be seen are this log and one dialog.
# Shown from ANOTHER process, and this one does not wait for it. A modal dialog here keeps
# the launcher alive, and "is anything starting?" is answered by looking for live launcher
# processes - so an unanswered dialog about a boot that was already over left the group
# screen answering "Nothing to start. already starting: 3794xa, wa01" to every click. The
# text goes through a file because it contains quotes and newlines that a -Command line
# would mangle.
function Show-Fatal([string] $msg) {
    try {
        $f = Join-Path $env:TEMP "android-fatal-$PID.txt"
        Set-Content -LiteralPath $f -Value "$msg`r`n`r`nLog: $LogFile" -Encoding UTF8
        $title = ("Android instance '$LogName' failed") -replace "'", "''"
        $cmd   = "Add-Type -AssemblyName System.Windows.Forms; " +
                 "[void][System.Windows.Forms.MessageBox]::Show((Get-Content -Raw -LiteralPath '$f'), '$title', 'OK', 'Error'); " +
                 "Remove-Item -LiteralPath '$f' -ErrorAction SilentlyContinue"
        # Start-Process quotes NOTHING: the whole -Command payload is one argument only if it
        # is quoted here, otherwise the child gets it split on every space and shows nothing.
        # It contains no double quotes of its own (single quotes inside on purpose), so this
        # pair is enough.
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "`"$cmd`"")
    } catch { }
}

$script:BootStarted = $false
$script:GateHeld    = $false

trap {
    $e = $_
    # FIRST, before anything slow or blocking: Write-Diagnosis takes ~3 s and Show-Fatal waits
    # for a human to click OK, and until this process exits it still owns the boot gate mutex.
    # Measured on 2026-08-26: 3794xa failed, its dialog sat unanswered, and wa01 stayed at
    # "still queued" until the 600 s give-up - one failed boot froze the whole group.
    # try/catch because a failure this early can happen before the function is even defined.
    try { Exit-BootGate } catch { }
    Write-Log "FATAL: $($e.Exception.Message)" 'ERROR'
    if ($e.InvocationInfo) { Write-Log ('  at' + ($e.InvocationInfo.PositionMessage -replace "`r?`n", ' ')) 'ERROR' }
    # A diagnosis block on "instance already exists" would be noise; on a failed boot it
    # is the whole point.
    if ($script:BootStarted) { try { Write-Diagnosis $Name } catch { } }
    else { Write-Log "full log: $LogFile" 'ERROR' }
    try { Stop-Transcript | Out-Null } catch { }
    Show-Fatal $e.Exception.Message
    break
}

# ============================================================ -Requirements
# Deliberately above the "missing: ..." checks below: this is the one command that has to
# work when nothing is installed yet, because it is what says so.
if ($Requirements) {
    [void](Write-Requirements)
    Write-Log "full report: $LogFile"
    try { Stop-Transcript | Out-Null } catch { }
    return
}

# ============================================================ -Tile: group view
# Above the path checks for the same reason as -Requirements: arranging windows that are
# already on the screen needs nothing installed and no instance to answer adb, so it must
# not be able to fail on a missing SDK. The manager's Group window calls this too.
if ($Tile -or $Toolbars) {
    if ($Tile) {
        # $Name has a default, so "did the caller ask for one instance" is a bound-parameter
        # question - not "is $Name set", which is always true.
        $only   = if ($PSBoundParameters.ContainsKey('Name')) { @($Name) } else { @() }
        $placed = @(Set-EmulatorGrid -Only $only -KeepToolbars:$Toolbars)
        if (-not $placed.Count) { Write-Log 'no emulator window is up - nothing to arrange' 'WARN' }
        foreach ($p in $placed) { Write-Log ('  {0,-14} {1}x{2} at {3},{4}' -f $p.Name, $p.W, $p.H, $p.X, $p.Y) }
        Write-Log "arranged $($placed.Count) window(s)"
    } else {
        Write-Log "put back $(Show-EmulatorToolbars) side toolbar(s)"
    }
    try { Stop-Transcript | Out-Null } catch { }
    return
}

foreach ($p in @($Jdk, $Sdk, $sdkmanager)) {
    if (-not (Test-Path $p)) { throw "missing: $p (manager window > Requirements says what to do about it)" }
}
New-Item -ItemType Directory -Force $AvdHome | Out-Null
# $MyInvocation.Line is empty when the script is started with -File, so log the bound
# parameters instead - that is what "what did this run actually ask for" means.
Write-Log ("=== {0} : {1}" -f $LogName,
           (($PSBoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '))

# Returns adb's stdout only, or '' when the command failed. Discarding the stderr
# ErrorRecords matters twice over: an unregistered device must read as "no answer"
# rather than as a string that callers then pattern-match against, and adb's chatty
# "daemon not running; starting now" also arrives on stderr and must not be mistaken
# for a result.
function Adb {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $adb $args 2>&1
        $stdout = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        return (($stdout -join "`n").Trim())
    }
    finally {
        $ErrorActionPreference = $prev
        # A miss is normal here ("pm path com.whatsapp" on an instance without WhatsApp
        # exits 1), but PowerShell keeps the last native exit code as the SCRIPT's exit
        # code, so run-<name>.bat printed "---- exit code: 1 ----" after a perfectly good
        # boot. Failure is already reported by returning '' - do not leak it twice.
        $global:LASTEXITCODE = 0
    }
}

# The console port is stored per AVD instead of derived from the position in
# `emulator -list-avds`: that list is ordered, so deleting one instance would silently
# renumber every other one and each run-*.bat would start talking to the wrong device.
function Get-PortFile([string] $avd) { Join-Path (Join-Path $AvdHome "$avd.avd") 'port.txt' }

function Get-AvdPort([string] $avd) {
    $f = Get-PortFile $avd
    if (Test-Path $f) { return [int](Get-Content $f -First 1).Trim() }
    # Pre-existing AVD from before port.txt: fall back to list order, then pin it.
    $avds  = @(& $emulator -list-avds)
    $index = [array]::IndexOf($avds, $avd)
    if ($index -lt 0) { throw "AVD '$avd' not found. Have: $($avds -join ', ')" }
    $port  = 5554 + 2 * $index
    Set-Content -Path $f -Value $port -Encoding ASCII
    return $port
}

function New-AvdPort {
    # Valid emulator console ports are the even numbers in 5554..5682.
    $taken = @()
    foreach ($d in Get-ChildItem $AvdHome -Filter '*.avd' -Directory -ErrorAction SilentlyContinue) {
        $f = Join-Path $d.FullName 'port.txt'
        if (Test-Path $f) { $taken += [int](Get-Content $f -First 1).Trim() }
    }
    for ($p = 5554; $p -le 5682; $p += 2) { if ($taken -notcontains $p) { return $p } }
    throw "no free console port left (5554..5682 all assigned)"
}

function Assert-Name([string] $n) {
    if ($n -notmatch '^[A-Za-z0-9_-]+$') { throw "instance name must be letters/digits/-/_ only: '$n'" }
}

function Assert-NotRunning([string] $avd) {
    $f = Get-PortFile $avd
    if (-not (Test-Path $f)) { return }
    $s = "emulator-$([int](Get-Content $f -First 1).Trim())"
    if ((Adb devices) -match [regex]::Escape($s)) { throw "'$avd' is running ($s). Stop it first." }
}

# A launch that stalls in renderer init (the log stops right after "hasSufficientDiskSpace
# ... are met", before "Initializing gfxstream backend") leaves a live
# qemu-system-x86_64.exe that NEVER opens its console port. adb never sees it, so
# `adb emu kill` cannot reach it, and it keeps holding the AVD - so the next start stalls
# too and the failure looks permanent. The command line is the only handle on it.
# Only ever called when adb has no trace of this AVD, so a match here is by definition
# a leftover and never a healthy instance.
function Stop-StaleEmulator([string] $avd) {
    $pattern = "-avd\s+$([regex]::Escape($avd))(\s|$)"
    $stale = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe' OR Name='emulator.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -match $pattern })
    # Same trap as the Adb helper: taskkill writes to stderr, PowerShell turns that into
    # an ErrorRecord, and $ErrorActionPreference='Stop' makes it terminating. One of the
    # errors here is EXPECTED - the tree kill from the parent already reaped the child,
    # so aiming at the child afterwards reports "Access is denied" on a corpse.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($p in $stale) {
            Write-Host "  killing stale emulator pid $($p.ProcessId) - it never opened its port" -ForegroundColor Yellow
            # /T because the stuck qemu spawns a child that cannot be killed on its own.
            & taskkill /T /F /PID $p.ProcessId 2>&1 | Out-Null
        }
    }
    finally {
        $ErrorActionPreference = $prev
        $global:LASTEXITCODE   = 0
    }
    $w = [Diagnostics.Stopwatch]::StartNew()
    while ($w.Elapsed.TotalSeconds -lt 30 -and
           @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -match $pattern }).Count) {
        Start-Sleep -Milliseconds 400
    }
    return $stale.Count
}

# "Is the emulator I just started still there?" - asked during the boot wait, where the
# answer decides between "slow" and "gone". Two independent signals have to agree, because
# either one alone lies: adb drops a serial for a second under load, and the WMI query comes
# back empty when the process list is momentarily unavailable. The serial WAS listed before
# this wait began (the console port answered), so losing it AND the qemu process is the
# emulator exiting - a window X, a -Stop, kill-all, or a crash.
function Test-EmulatorGone([string] $avd, [string] $serial) {
    if ((Adb devices) -match [regex]::Escape($serial)) { return $false }
    try {
        return -not @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue |
                      Where-Object { $_.CommandLine -match "-avd\s+$([regex]::Escape($avd))(\s|$)" }).Count
    } catch { return $false }
}

# Everything this project can leave behind. Matched by executable path under the SDK, so
# an adb.exe or a qemu belonging to some other tool is never collateral, plus the
# PowerShell windows sitting in a boot wait for these scripts. $PID is excluded or the
# sweep kills itself half way through.
# Resolved once: the loop below calls this every 500 ms and the answer cannot change.
$ownParent = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
function Get-ProjectProcesses {
    $sdkPrefix = $Sdk.TrimEnd('\') + '\'
    $mine = @()
    foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if ($p.ProcessId -eq $PID -or $p.ProcessId -eq $ownParent) { continue }
        if ($p.ExecutablePath -and $p.ExecutablePath.StartsWith($sdkPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $mine += $p
        }
        elseif ($p.Name -eq 'powershell.exe' -and $p.CommandLine -and
                ($p.CommandLine -like "*$here\android.ps1*" -or $p.CommandLine -like "*$here\manager.ps1*")) {
            $mine += $p
        }
        # Killing the PowerShell leaves its run-<name>.bat window behind, parked on
        # `pause` and printing an exit code for a boot that no longer exists - one dead
        # window per instance after a sweep that just said "all clear". The panic button
        # is one click, so the window goes with it. Own parent is skipped above, or
        # `run-wa01.bat -KillAll` would kill the console it is printing to.
        elseif ($p.Name -eq 'cmd.exe' -and $p.CommandLine -and $p.CommandLine -like "*$here\run-*.bat*") {
            $mine += $p
        }
    }
    return $mine
}

# ============================================================ boot gate
# THE fix for "the emulators freeze". Three instances resuming at once never finished at
# all - measured: all three still `offline` after 180 s - because a resume is hw.ramSize
# bytes read off a 7200 rpm disk and three of those thrash the head. Serialised, the same
# three come up in seconds each. Held only across a boot, never for the life of an
# instance: they still RUN in parallel, they just do not START in parallel.
function Enter-BootGate {
    $script:BootGate = New-Object System.Threading.Mutex($false, 'Local\AndroidAvdBootGate')
    $got = $false
    # An abandoned mutex means the previous holder died - the panic button kills launchers
    # mid-boot. The wait still succeeds and ownership passes here, so treat it as acquired
    # instead of letting it surface as an error.
    try { $got = $script:BootGate.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) {
        Write-Log 'another instance is booting - queued (the disk can only resume one at a time)' 'WARN'
        $w    = [Diagnostics.Stopwatch]::StartNew()
        $next = 30
        while (-not $got -and $w.Elapsed.TotalSeconds -lt 600) {
            try { $got = $script:BootGate.WaitOne(2000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
            if (-not $got -and $w.Elapsed.TotalSeconds -ge $next) {
                Write-Log ('  still queued, {0:N0}s' -f $w.Elapsed.TotalSeconds)
                $next += 30
            }
        }
        if ($got) { Write-Log ('gate free after {0:N0}s queued' -f $w.Elapsed.TotalSeconds) }
        # Never deadlock on the gate: a stuck queue must not be the reason nothing boots.
        else      { Write-Log 'gate still busy after 600s - booting anyway rather than never' 'WARN' }
    }
    $script:GateHeld = $got
}

function Exit-BootGate {
    if (-not $script:GateHeld) { return }
    try { $script:BootGate.ReleaseMutex() } catch { }
    $script:GateHeld = $false
    Write-Log 'boot gate released - the next queued instance can start'
}

# ============================================================ per-instance identity
# $Personas, $Screens and the resolution rules live in common.ps1: the manager window
# offers the same two lists in its New / Identity dialog, and one copy is what stops the
# dialog offering a device this script would then ignore. The measured note on what CAN and
# CANNOT differ between instances is there too.
function Get-IdentityFile([string] $avd) { Join-Path (Join-Path $AvdHome "$avd.avd") 'identity.ini' }

# Written to identity.ini on first use so it can be hand-edited afterwards and still be
# stable. $over is what -Device / -Region / -Phone asked for: with an override the file is
# rewritten, without one an existing file is returned untouched - a number an instance is
# already registered with must never move because someone opened a dialog.
function Get-Identity([string] $avd, $over = $null) {
    $f  = Get-IdentityFile $avd
    $ov = @{}
    if ($over) {
        foreach ($k in @($over.Keys)) { if ("$($over[$k])".Trim()) { $ov[$k] = "$($over[$k])".Trim() } }
    }

    $existing = $null
    if (Test-Path $f) {
        $parsed = Read-Ini $f
        if ($parsed.Count -ge 7) { $existing = $parsed }
    }
    if ($existing -and -not $ov.Count) { return $existing }

    $id = Resolve-Identity $avd $existing $ov
    if (Test-Path (Split-Path $f -Parent)) {
        @(
            "# Identity of instance '$avd'. Derived from its name, so deleting this file"
            '# regenerates exactly the same values. Edit any line to override it; the'
            '# screen size only takes effect after Retune or Identity rewrites config.ini.'
            "Phone    = $($id.Phone)"
            "Timezone = $($id.Timezone)"
            "Locale   = $($id.Locale)"
            "Device   = $($id.Device)"
            "Width    = $($id.Width)"
            "Height   = $($id.Height)"
            "Dpi      = $($id.Dpi)"
        ) | Set-Content -Path $f -Encoding ASCII
    }
    return $id
}

# What -Device / -Region / -Phone asked for, in the shape Get-Identity wants. Empty values
# are dropped in there, so passing none of them means "leave this instance's identity alone".
$IdOverrides = @{ Device = $Device; Region = $Region; Phone = $Phone }

function Write-Launcher([string] $avd, [int] $port) {
    $path = Join-Path $here "run-$avd.bat"
    @"
@echo off
rem Auto-generated launcher for instance "$avd" (console port $port).
rem Regenerate all of them from the manager window > Launchers.
rem
rem   run-$avd.bat            boot it (does NOT open WhatsApp - tap the icon yourself)
rem   run-$avd.bat -Stop      graceful shutdown (lets Android flush userdata)
rem   run-$avd.bat -Snapshot  resume from a saved snapshot instead of booting fresh
rem                           (measured 4-8x SLOWER on this disk - see android.ps1)
rem   run-$avd.bat -Net       network diagnostics
rem   run-$avd.bat -Check     device identity / Google Play / capabilities / integrity
rem                           (integrity = why WhatsApp registration blocks on an emulator)
rem   run-$avd.bat -Paste     paste the Windows clipboard into the focused field
rem                           (Ctrl+V inside the emulator window does the same thing)
rem   run-$avd.bat -ResetApp -Force
rem                           wipe WhatsApp's data here and start it fresh - the way out
rem                           of "Download the official WhatsApp to continue". Erases
rem                           this instance's session and local chat history.
rem
rem NO console window: PowerShell starts hidden and this file exits immediately.
rem Everything it would have printed is in logs\$avd.log - read it in the manager
rem window > Logs, which also tails it live. A failed boot still raises a dialog.
cd /d "%~dp0"
start "" powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%~dp0android.ps1" -Name $avd %*
"@ | Set-Content -Path $path -Encoding ASCII
    return $path
}

# The per-AVD .ini in AvdHome is the only file that carries the instance name, so a
# clone or rename is: move/copy the .avd directory, then rewrite this one file.
function Write-AvdIni([string] $avd) {
    @(
        'avd.ini.encoding=UTF-8'
        "path=$(Join-Path $AvdHome "$avd.avd")"
        "target=$Target"
    ) | Set-Content -Path (Join-Path $AvdHome "$avd.ini") -Encoding ASCII
}

function Set-Config([string] $cfgPath, $pairs) {
    $lines = @(Get-Content $cfgPath)
    foreach ($key in $pairs.Keys) {
        $escaped = [regex]::Escape($key)
        $hit     = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*$escaped\s*=") { $lines[$i] = "$key=$($pairs[$key])"; $hit = $true }
        }
        if (-not $hit) { $lines += "$key=$($pairs[$key])" }
    }
    # skin.path would re-impose the pixel_2 1080x1920 skin over skin.name
    $lines = $lines | Where-Object { $_ -notmatch '^\s*skin\.path' }
    Set-Content -Path $cfgPath -Value $lines -Encoding ASCII
}

function Get-Tuning([int] $ramMb, [int] $cores, [bool] $includeDiskSize, $id) {
    $t = [ordered]@{
        # --- speed ---------------------------------------------------------------
        # Low resolution is the single biggest in-guest win: the pixel_2 profile
        # defaults to 1080x1920 @420dpi, four times the pixels for no benefit in a
        # chat app. Every size in $Screens is in that cheap range; which one this
        # instance gets comes from its identity, so two instances do not measure the
        # same screen.
        'hw.lcd.width'           = $id.Width
        'hw.lcd.height'          = $id.Height
        'hw.lcd.density'         = $id.Dpi
        'skin.name'              = "$($id.Width)x$($id.Height)"
        'skin.dynamic'           = 'yes'
        'showDeviceFrame'        = 'no'
        # ram.img in the snapshot is exactly hw.ramSize, and resume speed is that many
        # bytes off disk. 2048 is the floor this image accepts; raise to 2560 only on an
        # instance that stacks WhatsApp + Business + work profile.
        'hw.ramSize'             = "$ramMb"
        'hw.cpu.ncore'           = "$cores"
        'hw.gpu.enabled'         = 'yes'
        'hw.gpu.mode'            = $Gpu      # see the -Gpu note in param(): 'host' hangs the boot
        'fastboot.forceColdBoot' = 'no'     # quick-boot snapshot = seconds to resume
        # --- behave like a real phone --------------------------------------------
        'hw.keyboard'            = 'yes'    # host keyboard, and host Ctrl+V into a field
        'hw.mainKeys'            = 'no'     # on-screen nav bar, like a modern phone
        'hw.dPad'                = 'no'
        'hw.trackBall'           = 'no'
        'hw.audioInput'          = 'yes'    # voice notes
        'hw.audioOutput'         = 'yes'
        'hw.gps'                 = 'yes'    # location sharing
        'hw.battery'             = 'yes'
        'hw.accelerometer'       = 'yes'
        'hw.sensors.orientation' = 'yes'
        'hw.sensors.proximity'   = 'yes'
        # ponytail: 'emulated' is a synthetic test pattern - fine for the camera
        # permission prompt and for sending a picture, but it CANNOT scan a real QR
        # code. Switch either to webcam0 to use the PC webcam (emulator -webcam-list).
        'hw.camera.back'         = 'emulated'
        'hw.camera.front'        = 'emulated'
    }
    # Shrinking this on an existing AVD does not shrink the already-allocated
    # userdata-qemu.img and risks a size mismatch, so it is only written at creation.
    if ($includeDiskSize) { $t['disk.dataPartition.size'] = '4G' }
    return $t
}

# ============================================================ install (once, or -Install)
if ($Install -or -not (Test-Path $emulator) -or -not (Test-Path $imageDir)) {
    Write-Host "== installing emulator + system image (~1.5 GB download) ==" -ForegroundColor Cyan
    ((,'y' * 40) -join "`n") | & $sdkmanager --sdk_root="$Sdk" 'emulator' 'platform-tools' $Image
    if ($LASTEXITCODE -ne 0) { throw "sdkmanager failed ($LASTEXITCODE)" }

    setx JAVA_HOME        $Jdk     | Out-Null
    setx ANDROID_SDK_ROOT $Sdk     | Out-Null
    setx ANDROID_HOME     $Sdk     | Out-Null
    setx ANDROID_AVD_HOME $AvdHome | Out-Null

    # Asked for explicitly, so report and stop instead of falling through into a boot -
    # and the report is the only way to see whether the download actually landed.
    if ($Install) {
        [void](Write-Requirements)
        return
    }
}

# ============================================================ -ClipboardBridge
# Ctrl+C / Ctrl+V inside an emulator window did nothing except type the letter. Measured on
# wa01 by sending real Ctrl+A / Ctrl+C to the window with SendInput and reading the field
# back: "GUESTCOPY456" became "GUESTac2COPY456" - the guest got the LETTERS and never saw
# the Ctrl modifier, because the emulator's Qt window keeps Ctrl for its own shortcuts.
#
# What is NOT broken, so this bridge does not try to fix it (all verified on this box):
#   host -> guest   Windows clipboard reaches the guest by itself. Set 'CLIPTEST123' in
#                   Windows, KEYCODE_PASTE in the guest, the field showed CLIPTEST123.
#   guest -> host   guest KEYCODE_COPY put 'ZEBRA789' straight into the Windows clipboard.
#   two instances   both guests received the same clip, zero "Retrying to obtain clipboard"
#                   warnings in either emulator log.
# So the clipboard itself is fine and only the keystroke is missing: the bridge swallows the
# Ctrl combination on the host and sends the guest the keycode it never got.
#
# A low-level keyboard hook sees EVERY keystroke on the desktop, so the hook callback has a
# hard budget (Windows silently drops a hook that is too slow) and must never block:
#   - the callback is C#, never a PowerShell scriptblock - the same lesson as Tiles.Win.List
#     in common.ps1, where a PowerShell callback cost 130-250 ms per call.
#   - GetWindowText on ANOTHER process's window is a SendMessage and blocks on a busy guest,
#     so the hwnd -> serial map is built on a background thread once a second and the
#     callback only does GetForegroundWindow + a dictionary lookup.
#   - adb runs on a worker thread. A round-trip is ~100-250 ms, which is 1000x the budget.
if ($ClipboardBridge) {
    # One hook for the whole desktop: a second copy would swallow the same keystroke twice
    # and paste twice. Not abandoned-safe on purpose - if the holder died, the hook died too.
    # -Check hooks nothing, so it must not compete for the mutex either, or the self-check
    # would refuse to run exactly when there IS a bridge to check.
    $bridgeLock = $null
    if (-not $Check) {
        $bridgeLock = New-Object System.Threading.Mutex($false, 'Local\AndroidAvdClipboardBridge')
        $held = $false
        try { $held = $bridgeLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { Write-Log 'another clipboard bridge is already running - nothing to do'; return }
    }

    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Clip {
public class Bridge {
    const int WH_KEYBOARD_LL = 13;
    const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    const int WM_QUIT = 0x0012;
    const int VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C;
    const int VK_C = 0x43, VK_V = 0x56, VK_X = 0x58;
    // Android KeyEvent: 278 COPY, 279 PASTE, 277 CUT. There is no select-all keycode, so
    // Ctrl+A is deliberately left alone and still reaches the guest as a plain "a".
    const string K_COPY = "278", K_PASTE = "279", K_CUT = "277";

    public delegate IntPtr HookProc(int code, IntPtr w, IntPtr l);
    public delegate bool EnumProc(IntPtr h, IntPtr p);

    [DllImport("user32.dll", EntryPoint = "SetWindowsHookExW", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string n);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll", EntryPoint = "GetMessageW")] static extern int GetMessage(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll", EntryPoint = "PostThreadMessageW")] static extern bool PostThreadMessage(uint tid, uint msg, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public int x, y; }

    static string _adb;
    static IntPtr _hook;
    static HookProc _proc;          // a field, not a local: the GC collects a callback that
                                    // only Windows still holds, and the hook then crashes.
    static uint _tid;
    static volatile bool _running;
    // Replaced whole, never mutated in place, so the hook can read it with no lock. volatile
    // because the writer is the watcher thread and the reader is the hook thread.
    static volatile Dictionary<IntPtr, string> _map = new Dictionary<IntPtr, string>();
    static readonly bool[] _held = new bool[256];
    static readonly Queue<string[]> _work = new Queue<string[]>();
    static readonly List<string> _log = new List<string>();

    public static bool Running { get { return _running; } }
    public static string[] TakeLog() { lock (_log) { string[] a = _log.ToArray(); _log.Clear(); return a; } }
    static void Log(string m) { lock (_log) { if (_log.Count < 200) _log.Add(m); } }

    // ---- the hot path. Everything here is O(1) and touches no other process.
    static IntPtr Proc(int code, IntPtr w, IntPtr l) {
        if (code == 0) {
            int vk = Marshal.ReadInt32(l);
            if (vk == VK_C || vk == VK_V || vk == VK_X) {
                int msg = (int)w;
                if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN) {
                    // Held down: the guest already got one keycode, and a repeat would
                    // paste again for every repeat Windows generates.
                    if (_held[vk]) return (IntPtr)1;
                    if ((GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 &&
                        (GetAsyncKeyState(VK_MENU)    & 0x8000) == 0 &&
                        (GetAsyncKeyState(VK_LWIN)    & 0x8000) == 0 &&
                        (GetAsyncKeyState(VK_RWIN)    & 0x8000) == 0) {
                        Dictionary<IntPtr, string> map = _map;
                        string serial;
                        if (map.TryGetValue(GetForegroundWindow(), out serial)) {
                            _held[vk] = true;
                            Enqueue(serial, vk);
                            return (IntPtr)1;   // swallowed, or the guest also types the letter
                        }
                    }
                } else if (msg == WM_KEYUP || msg == WM_SYSKEYUP) {
                    // Ctrl is usually released first, so the matching release is tracked by
                    // the flag rather than re-tested - a lone key-up would reach the guest.
                    if (_held[vk]) { _held[vk] = false; return (IntPtr)1; }
                }
            }
        }
        return CallNextHookEx(_hook, code, w, l);
    }

    static void Enqueue(string serial, int vk) {
        string keycode = vk == VK_C ? K_COPY : (vk == VK_V ? K_PASTE : K_CUT);
        string what    = vk == VK_C ? "copy" : (vk == VK_V ? "paste" : "cut");
        lock (_work) {
            // A wedged adb must not build a backlog that fires minutes later.
            if (_work.Count >= 8) return;
            _work.Enqueue(new string[] { serial, keycode, what });
            Monitor.Pulse(_work);
        }
    }

    static void Worker() {
        while (_running) {
            string[] job = null;
            lock (_work) {
                if (_work.Count == 0) Monitor.Wait(_work, 500);
                if (_work.Count > 0) job = _work.Dequeue();
            }
            if (job == null) continue;
            int t0 = Environment.TickCount;
            string err = Send(job[0], job[1]);
            Log(string.Format("{0} {1} in {2} ms{3}", job[2], job[0], Environment.TickCount - t0, err));
        }
    }

    static string Send(string serial, string keycode) {
        try {
            ProcessStartInfo psi = new ProcessStartInfo(_adb, "-s " + serial + " shell input keyevent " + keycode);
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
            using (Process p = Process.Start(psi)) {
                string e = p.StandardError.ReadToEnd();
                p.StandardOutput.ReadToEnd();
                if (!p.WaitForExit(5000)) return "  - adb did not answer in 5s";
                e = e.Trim();
                return e.Length == 0 ? "" : "  - " + e.Replace("\r", " ").Replace("\n", " ");
            }
        } catch (Exception ex) { return "  - " + ex.Message; }
    }

    // ---- the map, rebuilt on a background thread so the hook never calls into Qt.
    static Dictionary<IntPtr, string> _building;
    static List<IntPtr[]> _owned;
    static bool Collect(IntPtr h, IntPtr p) {
        StringBuilder sb = new StringBuilder(512);
        GetWindowTextW(h, sb, 512);
        string t = sb.ToString();
        if (t.StartsWith("Android Emulator - ", StringComparison.Ordinal)) {
            // "Android Emulator - <avd>:<port>". The AVD name may contain anything, so the
            // port comes from the LAST colon - same rule as Tiles.Win.
            int c = t.LastIndexOf(':');
            int port;
            if (c > 0 && int.TryParse(t.Substring(c + 1), out port)) _building[h] = "emulator-" + port;
            return true;
        }
        // The 54 px side toolbar is a separate OWNED window and can hold the focus, so a
        // Ctrl+V aimed at it has to reach the same instance.
        StringBuilder cb = new StringBuilder(256);
        GetClassNameW(h, cb, 256);
        if (cb.ToString().IndexOf("ToolSaveBits", StringComparison.Ordinal) >= 0) {
            IntPtr owner = GetWindow(h, 4);   // GW_OWNER
            if (owner != IntPtr.Zero) _owned.Add(new IntPtr[] { h, owner });
        }
        return true;
    }

    static Dictionary<IntPtr, string> BuildMap() {
        _building = new Dictionary<IntPtr, string>();
        _owned    = new List<IntPtr[]>();
        EnumWindows(new EnumProc(Collect), IntPtr.Zero);
        Dictionary<IntPtr, string> m = _building;
        foreach (IntPtr[] pair in _owned) {
            string serial;
            if (m.TryGetValue(pair[1], out serial)) m[pair[0]] = serial;
        }
        _building = null; _owned = null;
        return m;
    }

    static void Watcher() {
        int empty = 0;
        while (_running) {
            Dictionary<IntPtr, string> m = BuildMap();
            // Toolbar entries do not count: they cannot outlive their owner anyway.
            _map = m;
            empty = m.Count == 0 ? empty + 1 : 0;
            if (empty >= 5) { Log("no emulator window left for 5s - stopping"); Stop(); return; }
            Thread.Sleep(1000);
        }
    }

    static void Pump() {
        _tid  = GetCurrentThreadId();
        _proc = new HookProc(Proc);
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
        if (_hook == IntPtr.Zero) {
            Log("SetWindowsHookEx failed with Win32 error " + Marshal.GetLastWin32Error());
            _running = false;
            return;
        }
        MSG m;
        while (_running && GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
        UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    // Only for the self-check: the same map the hook consults, built on demand.
    public static Dictionary<IntPtr, string> MapForCheck() { return BuildMap(); }

    public static int Start(string adbPath) {
        _adb = adbPath;
        _running = true;
        _map = BuildMap();
        Thread a = new Thread(new ThreadStart(Pump));    a.IsBackground = true; a.Start();
        Thread b = new Thread(new ThreadStart(Worker));  b.IsBackground = true; b.Start();
        Thread c = new Thread(new ThreadStart(Watcher)); c.IsBackground = true; c.Start();
        return _map.Count;
    }

    public static void Stop() {
        _running = false;
        if (_tid != 0) PostThreadMessage(_tid, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        lock (_work) { Monitor.PulseAll(_work); }
    }
}
}
'@ -ErrorAction Stop

    # `-ClipboardBridge -Check` is the runnable self-check: it compiles the class and proves
    # the window -> serial map still agrees with the list the group view uses, and it hooks
    # nothing. That map is the part that can rot in silence - it depends on the emulator's
    # window title staying "Android Emulator - <avd>:<port>", which is not a contract. A
    # wrong map means Ctrl+V lands in the wrong instance, or in none.
    if ($Check) {
        $mapped = [Clip.Bridge]::MapForCheck()
        $wins   = @(Get-EmulatorWindows | Where-Object { $_.Name })
        Write-Host '== clipboard bridge self-check ==' -ForegroundColor Cyan
        Write-Host "  class compiled : $([bool]('Clip.Bridge' -as [type]))"
        Write-Host "  device windows : $($wins.Count)  (from Get-EmulatorWindows)"
        Write-Host "  mapped windows : $($mapped.Count)  (device windows plus their toolbars)"
        $bad = 0
        foreach ($w in $wins) {
            $want = "emulator-$($w.Port)"
            $got  = $mapped[$w.Hwnd]
            $ok   = ($got -eq $want)
            if (-not $ok) { $bad++ }
            Write-Host ("  {0} {1,-12} hwnd=0x{2:X} expected {3}, bridge says {4}" -f `
                        $(if ($ok) { 'OK  ' } else { 'FAIL' }), $w.Name, [int64]$w.Hwnd, $want,
                        $(if ($got) { $got } else { '<not mapped>' })) `
                        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        }
        if (-not $wins.Count) { Write-Host '  (nothing running - start an instance to check the mapping)' -ForegroundColor Yellow }
        Write-Host "  $bad failure(s)" -ForegroundColor $(if ($bad) { 'Red' } else { 'Green' })
        return
    }

    $seen = [Clip.Bridge]::Start($adb)
    Write-Log "clipboard bridge up - Ctrl+C / Ctrl+V / Ctrl+X now reach the guest ($seen emulator window(s) mapped)" 'OK'
    Write-Log '  the clipboard itself is the emulator''s own sharing; this only supplies the keystroke'
    # The hook lives on its own thread, so this loop exists purely to drain what it logged
    # and to end the process when the last instance closes.
    while ([Clip.Bridge]::Running) {
        foreach ($m in [Clip.Bridge]::TakeLog()) { Write-Log "  $m" }
        Start-Sleep -Milliseconds 500
    }
    foreach ($m in [Clip.Bridge]::TakeLog()) { Write-Log "  $m" }
    Write-Log 'clipboard bridge stopped'
    try { $bridgeLock.ReleaseMutex() } catch { }
    return
}

# ============================================================ -PickRegion / -ScreenCam
# Draw a rectangle on the Windows screen; the guest camera shows that rectangle. See the
# "screen -> guest camera" section of common.ps1 for what the emulator actually supports and
# why it is an image file rather than a fake webcam.
#
# Same shape as Start-ClipboardBridge: probe the mutex first so a boot does not pay for a
# PowerShell start that would exit immediately, and never let a failure here stop a boot.
# Defined above its callers because a script runs top down - -PickRegion below calls it.
function Start-ScreenCam {
    if (-not (Get-CamRegion)) { return }
    try {
        $existing = [System.Threading.Mutex]::OpenExisting('Local\AndroidAvdScreenCam')
        $existing.Close()
        return
    } catch [System.Threading.WaitHandleCannotBeOpenedException] { }
      catch { return }
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-ExecutionPolicy', 'Bypass', '-NoProfile', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`"", '-ScreenCam')
        Write-Log 'screen camera feeder started (the guest camera shows the picked screen region)'
    } catch {
        Write-Log "could not start the screen camera feeder: $($_.Exception.Message)" 'WARN'
    }
}

if ($PickRegion) {
    # BEFORE any window is created, and this is a separate process for exactly that reason:
    # the manager's dialogs are laid out in logical pixels and must stay DPI-unaware, while a
    # region that CopyFromScreen can use has to be physical.
    [void](Set-DpiAware)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $vs   = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $keep = Get-CamRegion   # Fit / FrameW / FrameH survive a re-pick
    # Assigned one at a time, not with -Property @{...}: a hashtable has no order, and
    # Bounds set before StartPosition = 'Manual' is ignored.
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition   = 'Manual'
    $f.Bounds          = $vs
    $f.BackColor       = 'Black'
    $f.Opacity         = 0.4
    $f.TopMost         = $true
    $f.ShowInTaskbar   = $false
    $f.Cursor          = [System.Windows.Forms.Cursors]::Cross
    $f.KeyPreview      = $true
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize  = $false
    $hint.SetBounds(0, 40, $vs.Width, 60)
    $hint.TextAlign = 'MiddleCenter'
    $hint.ForeColor = 'White'
    $hint.BackColor = 'Black'
    $hint.Font      = New-Object System.Drawing.Font('Segoe UI', 14)
    $hint.Text      = 'Drag a box around the QR code (or whatever the guest camera should see).   Esc / right-click = cancel'
    $f.Controls.Add($hint)

    # DrawReversibleFrame paints straight onto the desktop with XOR, so the previous frame is
    # erased by drawing it again - no Invalidate, and a full-screen repaint per mouse move
    # (2560x1440 through a translucent form) is what that would have cost.
    $st = @{ Down = $false; Start = $null; Last = $null; Rect = $null }
    $draw = {
        param($r)
        [System.Windows.Forms.ControlPaint]::DrawReversibleFrame(
            $r, [System.Drawing.Color]::White, [System.Windows.Forms.FrameStyle]::Thick)
    }
    $rectOf = {
        param($a, $b)
        New-Object System.Drawing.Rectangle(
            [math]::Min($a.X, $b.X), [math]::Min($a.Y, $b.Y),
            [math]::Abs($a.X - $b.X), [math]::Abs($a.Y - $b.Y))
    }
    $f.Add_MouseDown({
        if ($_.Button -eq 'Right') { $f.Close(); return }
        if ($_.Button -ne 'Left')  { return }
        $st.Down  = $true
        $st.Start = $f.PointToScreen($_.Location)
        $st.Last  = $null
    })
    $f.Add_MouseMove({
        if (-not $st.Down) { return }
        if ($st.Last) { & $draw $st.Last }
        $st.Last = & $rectOf $st.Start ($f.PointToScreen($_.Location))
        & $draw $st.Last
        $hint.Text = "$($st.Last.Width) x $($st.Last.Height) px   -   release to use this box, Esc to cancel"
    })
    $f.Add_MouseUp({
        if (-not $st.Down) { return }
        $st.Down = $false
        if ($st.Last) { & $draw $st.Last }
        $st.Rect = & $rectOf $st.Start ($f.PointToScreen($_.Location))
        $f.Close()
    })
    $f.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $st.Rect = $null; $f.Close() } })
    [void]$f.ShowDialog()
    $f.Dispose()

    $r = $st.Rect
    if (-not $r -or $r.Width -lt 16 -or $r.Height -lt 16) {
        Write-Log 'region pick cancelled (nothing selected)'
        return
    }
    [void](Save-CamRegion $r.X $r.Y $r.Width $r.Height $keep)
    # $camRegion, NOT $region: this script already has a [string] $Region parameter (the
    # identity one, "964-751"), and PowerShell variable names are case-insensitive - so
    # $region = Get-CamRegion assigned an object to a [string] variable, which silently
    # stringified it to "@{X=1380; Y=254; ...}" and every .W read back empty.
    $camRegion = Get-CamRegion
    $ok        = Write-CamFrame $camRegion
    $box       = Get-CamFit $camRegion.W $camRegion.H $camRegion.FrameW $camRegion.FrameH $camRegion.Fit
    Write-Log ("camera region: {0}x{1} at {2},{3} -> {4}x{5} inside a {6}x{7} frame, written to {8}" -f
               $r.Width, $r.Height, $r.X, $r.Y, $box.W, $box.H, $camRegion.FrameW, $camRegion.FrameH, $CamFile) $(if ($ok) { 'OK' } else { 'ERROR' })
    Start-ScreenCam

    # The launch flag carries the path, so an instance that is already up still has the plain
    # emulated camera - that restart is the one thing the user has to be told.
    $up  = @(Get-EmulatorWindows | ForEach-Object Name)
    $msg = "Camera region saved: $($r.Width) x $($r.Height) px.`n`n" +
           "The picture refreshes about once a second, and the guest re-reads it every time " +
           "something opens the camera - so if a QR expires, just close and reopen the scanner.`n`n"
    if ($up.Count) {
        $msg += "Restart these instances once so their camera points at it: $($up -join ', ')."
    } else {
        $msg += 'Every instance you start from now on will use it.'
    }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Screen scan', 'OK', 'Information')
    return
}

# The feeder. imagefile: is re-read when a camera session starts, so "keep the file fresh"
# is all that is needed for the guest to see the current screen whenever it looks.
if ($ScreenCam) {
    [void](Set-DpiAware)
    # $camRegion, never $region - see the note in -PickRegion above: $Region is already a
    # [string] parameter of this script, so the object would arrive here as its own ToString().
    $camRegion = Get-CamRegion
    if (-not $camRegion) { Write-Log 'no camera region set yet - run -PickRegion first' 'WARN'; return }

    if ($Check) {
        # Runnable self-check: one frame, and where inside it the capture landed.
        $ok  = Write-CamFrame $camRegion
        $box = Get-CamFit $camRegion.W $camRegion.H $camRegion.FrameW $camRegion.FrameH $camRegion.Fit
        Write-Host ("region {0}x{1} at {2},{3} -> {4}x{5} at {6},{7} in a {8}x{9} frame: {10}" -f
                    $camRegion.W, $camRegion.H, $camRegion.X, $camRegion.Y, $box.W, $box.H, $box.X, $box.Y,
                    $camRegion.FrameW, $camRegion.FrameH, $(if ($ok) { 'written' } else { 'FAILED' }))
        Write-Host "  $CamFile"
        return
    }

    # One feeder per desktop: two would fight over the same file for the same picture.
    $camLock = New-Object System.Threading.Mutex($false, 'Local\AndroidAvdScreenCam')
    $heldCam = $false
    try { $heldCam = $camLock.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $heldCam = $true }
    if (-not $heldCam) { Write-Log 'another screen-camera feeder is already running - nothing to do'; return }

    Write-Log ("screen camera feeding {0}x{1} at {2},{3} into {4}" -f
               $camRegion.W, $camRegion.H, $camRegion.X, $camRegion.Y, (Split-Path -Leaf $CamFile)) 'OK'
    $idle = 0; $fails = 0; $frames = 0
    try {
        while ($true) {
            # Re-read every pass: a new -PickRegion only rewrites the ini, and deleting it is
            # how the cameras are given back to the emulated test pattern.
            $camRegion = Get-CamRegion
            if (-not $camRegion) { Write-Log 'camera.ini is gone - feeder stopping'; break }
            if (Write-CamFrame $camRegion) { $frames++; $fails = 0 }
            elseif (++$fails -eq 3)     { Write-Log 'cannot capture the screen (3 tries) - still trying' 'WARN' }

            # Nothing to feed once every instance is closed. 60 s of grace so a restart in
            # between does not have to start it again.
            if (@(Get-EmulatorWindows).Count) { $idle = 0 } else { $idle++ }
            if ($idle -ge 60) { Write-Log "no emulator window for 60s - feeder stopping after $frames frame(s)"; break }
            Start-Sleep -Milliseconds 1000
        }
    } finally { try { $camLock.ReleaseMutex() } catch { } }
    return
}

# Started after a boot, never before: the bridge exits on its own once no emulator window is
# left, so it must not come up while the first one is still a black rectangle. Cheap to call
# on every boot - a second copy sees the mutex and exits immediately - but the mutex is
# probed first so a busy box does not pay for a PowerShell start it does not need.
function Start-ClipboardBridge {
    try {
        $existing = [System.Threading.Mutex]::OpenExisting('Local\AndroidAvdClipboardBridge')
        $existing.Close()
        return
    } catch [System.Threading.WaitHandleCannotBeOpenedException] { }
      catch { return }
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-ExecutionPolicy', 'Bypass', '-NoProfile', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`"", '-ClipboardBridge')
        Write-Log 'clipboard bridge started (Ctrl+C / Ctrl+V inside the emulator window)'
    } catch {
        # A boot is worth more than a keyboard shortcut.
        Write-Log "could not start the clipboard bridge: $($_.Exception.Message)" 'WARN'
    }
}

# ============================================================ -Launchers
if ($Launchers) {
    foreach ($d in (Get-ChildItem $AvdHome -Filter '*.avd' -Directory -ErrorAction SilentlyContinue)) {
        # Not $d.BaseName - on a DirectoryInfo that keeps the ".avd" suffix.
        $n = $d.Name -replace '\.avd$', ''
        Write-Log ("launcher: {0}" -f (Write-Launcher $n (Get-AvdPort $n))) 'OK'
    }
    return
}

# ============================================================ -KillAll: panic button
if ($KillAll) {
    # Graceful first, and not out of politeness: `emu kill` lets Android flush userdata -
    # the WhatsApp sessions - instead of having the disk image cut off mid-write, and on a
    # -Snapshot instance it is also what writes the snapshot. It costs a few seconds per
    # instance. -Force skips it when something is so wedged that waiting is pointless.
    if (-not $Force) {
        # Re-polled rather than listed once: a single `adb devices` sample is a lie the
        # moment an instance is mid-registration - one run here saw 1 of 3 and hard-killed
        # the other two, losing their snapshots. Ask again every pass, skip what was
        # already asked, and only leave when the list is genuinely empty.
        $asked = @{}
        $sw    = [Diagnostics.Stopwatch]::StartNew()
        $late  = $false
        while ($true) {
            # "Is it gone yet" is answered by the process list, not by adb: `adb devices`
            # takes seconds to answer while instances are dying, and polling it every
            # round turned a 30 s shutdown into 240 s. adb is only consulted while some
            # live qemu has not been asked yet.
            $qemus = @(Get-ProjectProcesses | Where-Object { $_.Name -eq 'qemu-system-x86_64.exe' })
            if (-not $qemus.Count) { break }

            if ($asked.Count -lt $qemus.Count) {
                foreach ($line in ((Adb devices) -split "`n")) {
                    if ($line -match '^(emulator-\d+)\s' -and -not $asked.ContainsKey($Matches[1])) {
                        $s = $Matches[1]
                        Write-Host "  asking $s to shut down cleanly ..."
                        Adb -s $s emu kill | Out-Null
                        $asked[$s] = $true
                    }
                }
            }

            # Generous, because cutting a snapshot write short is what corrupts it - but
            # not unbounded, because this is the button someone presses when stuck.
            if ($sw.Elapsed.TotalSeconds -gt 120) { $late = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if ($late) { Write-Host "  still shutting down after 120s - killing whatever is left" -ForegroundColor Yellow }
        elseif ($asked.Count) {
            Write-Host ("  {0} instance(s) down cleanly in {1:N1}s" -f $asked.Count, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        }
        $summary = 'no instance was running'
        if ($late) { $summary = 'still shutting down after 120s - killed the rest' }
        elseif ($asked.Count) { $summary = '{0} instance(s) shut down cleanly in {1:N0}s' -f $asked.Count, $sw.Elapsed.TotalSeconds }
    } else {
        $summary = 'forced: killed immediately, snapshots lost'
    }

    $left = @(Get-ProjectProcesses)
    if (-not $left.Count) {
        Write-Host "nothing left running" -ForegroundColor Green
        $summary += "`nnothing else was left running"
    } else {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            foreach ($p in $left) {
                Write-Host ("  killing {0} (pid {1})" -f $p.Name, $p.ProcessId) -ForegroundColor Yellow
                & taskkill /T /F /PID $p.ProcessId 2>&1 | Out-Null
            }
        }
        finally { $ErrorActionPreference = $prev; $global:LASTEXITCODE = 0 }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (@(Get-ProjectProcesses).Count -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 400 }
        $still = @(Get-ProjectProcesses)
        if ($still.Count) {
            Write-Host "STILL ALIVE after 30s: $(($still | ForEach-Object { "$($_.Name)/$($_.ProcessId)" }) -join ', ')" -ForegroundColor Red
            Write-Host "run this again as Administrator." -ForegroundColor Red
            $summary += "`nSTILL ALIVE after 30s: $(($still | ForEach-Object { "$($_.Name)/$($_.ProcessId)" }) -join ', ')`nrun kill-all.bat again as Administrator."
        } else {
            Write-Host "killed $($left.Count) process(es) - all clear" -ForegroundColor Green
            $summary += "`nkilled $($left.Count) leftover process(es) - all clear"
        }
    }

    # The lock files are only meaningful while a process holds them; a killed emulator
    # leaves them behind and they would be mistaken for a live launcher.
    foreach ($d in (Get-ChildItem $AvdHome -Filter '*.avd' -Directory -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath (Join-Path $d.FullName 'launch.lock') -Force -ErrorAction SilentlyContinue
    }
    # kill-all.bat runs hidden like everything else now, so this dialog is the only
    # confirmation that the panic button did anything at all.
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [void][System.Windows.Forms.MessageBox]::Show("$summary`n`nLog: $LogFile", 'Android - stop everything', 'OK', 'Information')
    } catch { }
    return
}

# ============================================================ -New: create instance
if ($New) {
    Assert-Name $New
    $avdDir = Join-Path $AvdHome "$New.avd"
    if (Test-Path $avdDir) { throw "'$New' already exists. Pick another name, or delete it first." }

    Write-Host "== creating instance '$New' ==" -ForegroundColor Cyan
    'no' | & $avdmanager create avd -n $New -k $Image -d pixel_2
    if ($LASTEXITCODE -ne 0) { throw "avdmanager failed ($LASTEXITCODE)" }

    # -Device / -Region / -Phone if the caller picked a profile, otherwise derived from the
    # name exactly as before.
    $newId = Get-Identity $New $IdOverrides
    Set-Config (Join-Path $avdDir 'config.ini') (Get-Tuning $Ram $Cores $true $newId)
    $port = New-AvdPort
    Set-Content -Path (Get-PortFile $New) -Value $port -Encoding ASCII
    $launcher = Write-Launcher $New $port

    Write-Host "`ninstance : $New" -ForegroundColor Green
    Write-Host "port     : $port"
    Write-Host "ram/cores: $Ram MB / $Cores"
    Write-Host "profile  : $($newId.Device) $($newId.Width)x$($newId.Height)@$($newId.Dpi) | +$($newId.Phone) | $($newId.Timezone) | $($newId.Locale)"
    Write-Host "launcher : $launcher" -ForegroundColor Green
    return
}

# ============================================================ -Clone
if ($Clone) {
    if (-not $As) { throw "-Clone <source> also needs -As <newname>" }
    Assert-Name $Clone; Assert-Name $As
    $src = Join-Path $AvdHome "$Clone.avd"
    $dst = Join-Path $AvdHome "$As.avd"
    if (-not (Test-Path $src)) { throw "source instance '$Clone' does not exist" }
    if (Test-Path $dst)        { throw "'$As' already exists" }
    Assert-NotRunning $Clone

    # Skipped on purpose: snapshots hold the SOURCE's RAM image and absolute paths, so
    # the clone cold-boots once and writes its own; hardware-qemu.ini and the lock/
    # bootstrap files all point at the source directory; port.txt must be reissued or
    # both instances would fight over one console port.
    Write-Host "== cloning '$Clone' -> '$As' (copying several GB, this is the slow part) ==" -ForegroundColor Cyan
    robocopy $src $dst /E /NFL /NDL /NJH /NJS `
        /XD snapshots tmpAdbCmds `
        /XF hardware-qemu.ini port.txt multiinstance.lock launch.lock emu-launch-params.txt bootcompleted.ini read-snapshot.txt quickbootChoice.ini AVD.conf
    # robocopy exit codes below 8 are success (1 = files copied, 2 = extra, 3 = both).
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    $global:LASTEXITCODE = 0   # or a successful clone still ends the script with code 1

    Write-AvdIni $As
    $port = New-AvdPort
    Set-Content -Path (Get-PortFile $As) -Value $port -Encoding ASCII
    $launcher = Write-Launcher $As $port

    Write-Host "`ncloned   : $Clone -> $As" -ForegroundColor Green
    Write-Host "port     : $port"
    Write-Host "launcher : $launcher" -ForegroundColor Green
    Write-Host "`nNOTE: the clone carries the source's Google account, installed apps and"
    Write-Host "Android ID. Clone BEFORE registering a WhatsApp number, never after."
    return
}

# ============================================================ -Rename
if ($Rename) {
    Assert-Name $Name; Assert-Name $Rename
    $src = Join-Path $AvdHome "$Name.avd"
    $dst = Join-Path $AvdHome "$Rename.avd"
    if (-not (Test-Path $src)) { throw "instance '$Name' does not exist" }
    if (Test-Path $dst)        { throw "'$Rename' already exists" }
    Assert-NotRunning $Name

    Move-Item -LiteralPath $src -Destination $dst
    Write-AvdIni $Rename
    Remove-Item -LiteralPath (Join-Path $AvdHome "$Name.ini") -Force -ErrorAction SilentlyContinue
    # Absolute paths to the old directory; regenerated on the next boot.
    Remove-Item -LiteralPath (Join-Path $dst 'hardware-qemu.ini') -Force -ErrorAction SilentlyContinue

    $port = Get-AvdPort $Rename
    Remove-Item -LiteralPath (Join-Path $here "run-$Name.bat") -Force -ErrorAction SilentlyContinue
    $launcher = Write-Launcher $Rename $port

    Write-Host "renamed  : $Name -> $Rename (port $port kept)" -ForegroundColor Green
    Write-Host "launcher : $launcher" -ForegroundColor Green
    return
}

# ============================================================ -Delete
if ($Delete) {
    Assert-Name $Name
    $dir = Join-Path $AvdHome "$Name.avd"
    if (-not (Test-Path $dir)) { throw "instance '$Name' does not exist" }
    if (-not $Force) { throw "deleting '$Name' erases its WhatsApp session permanently. Re-run with -Force." }
    Assert-NotRunning $Name

    # Belt and braces before a recursive delete: the path must sit directly under
    # AvdHome and carry the .avd suffix.
    $expected = Join-Path $AvdHome "$Name.avd"
    if ((Resolve-Path $dir).Path -ne (Resolve-Path $expected).Path) { throw "refusing to delete $dir" }

    Remove-Item -LiteralPath $dir -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $AvdHome "$Name.ini") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $here "run-$Name.bat") -Force -ErrorAction SilentlyContinue
    Write-Host "deleted  : $Name" -ForegroundColor Green
    return
}

# ============================================================ boot
$avdDir = Join-Path $AvdHome "$Name.avd"
if (-not (Test-Path $avdDir)) { throw "instance '$Name' does not exist - run new-instance.bat first" }

$port   = Get-AvdPort $Name
$serial = "emulator-$port"

# Returns instead of falling through to the boot: a config change is not a request to
# start an emulator, and the Retune button in the manager would otherwise launch one.
if ($Retune -or $Identity) {
    # With no -Device/-Region/-Phone this returns the existing identity.ini untouched, so
    # Retune stays what it always was: a config.ini rewrite, nothing about the identity.
    $id = Get-Identity $Name $IdOverrides
    Set-Config (Join-Path $avdDir 'config.ini') (Get-Tuning $Ram $Cores $false $id)
    Write-Log "retuned $Name to $Ram MB / $Cores cores, screen $($id.Width)x$($id.Height)@$($id.Dpi)" 'OK'
    Write-Log "identity: $($id.Device) | $($id.Phone) | $($id.Timezone) | $($id.Locale)"
    Write-Log "  (edit $(Get-IdentityFile $Name) to change it; delete it to regenerate)"
    if ((Adb devices) -match [regex]::Escape($serial)) {
        Write-Log "$Name is running - the new settings apply after you Stop and start it again." 'WARN'
    }
    return
}

if ($Stop) {
    if ((Adb devices) -notmatch [regex]::Escape($serial)) {
        # Nothing on adb also means "queued behind another boot", and that launcher does not
        # care that it was stopped: it waits its turn and starts the emulator minutes later,
        # long after the user was told it was down. Measured 2026-08-26: wa01 was stopped at
        # 17:54 and booted itself at 18:04. Only in this branch - once the instance IS on
        # adb, its launcher is past the boot and may be mid-install, and `emu kill` below
        # plus the boot-wait's own "it is gone" check end it cleanly a few seconds later.
        foreach ($p in (Get-LauncherProcesses $Name)) {
            Write-Log "cancelling the queued launcher for $Name (pid $($p.ProcessId)) - it had not started an emulator yet" 'WARN'
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & taskkill /T /F /PID $p.ProcessId 2>&1 | Out-Null } finally { $ErrorActionPreference = $prev; $global:LASTEXITCODE = 0 }
        }
        # Not on adb is not the same as not running: a launch that stalled before opening
        # its port leaves a black window with a live process behind it, and Stop is
        # exactly the button someone presses when staring at that window.
        if ((Stop-StaleEmulator $Name) -gt 0) { Write-Host "$Name was stuck before it opened its port - killed it (no snapshot to save)" -ForegroundColor Yellow }
        else { Write-Host "$Name is not running" }
        return
    }
    Adb -s $serial emu kill | Out-Null
    # Waiting on THIS serial, not on "any qemu process": with several instances up,
    # a global process check would block until an unrelated instance also exited.
    # Returning before the device is really gone makes the next boot collide with the
    # dying one. No timeout on purpose - a shutdown cut short is how userdata (and, on a
    # -Snapshot instance, the snapshot) gets corrupted.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $next = 10
    while ((Adb devices) -match [regex]::Escape($serial)) {
        Start-Sleep -Milliseconds 500
        if ($sw.Elapsed.TotalSeconds -ge $next) {
            Write-Log ('  still shutting down... {0:N0}s' -f $sw.Elapsed.TotalSeconds)
            $next += 10
        }
    }
    Write-Log ("$Name down cleanly in {0:N1}s" -f $sw.Elapsed.TotalSeconds) 'OK'
    return
}

# The "is it already running?" check below reads `adb devices`, but a freshly launched
# emulator takes ~10 s to register its console port. In that window a second Start - or
# ONE double-click in the manager, which fires Start twice - sees an idle AVD and boots
# a SECOND emulator on the same port. Verified: both processes printed "booting wa02 on
# port 5556" and only one qemu survived, leaving the other window waiting on a boot that
# had already died. adb cannot close that window, so an exclusive file lock does; it is
# held only across the launch, not for the life of the emulator.
$lockPath = Join-Path $avdDir 'launch.lock'
$lock     = $null
try { $lock = [System.IO.File]::Open($lockPath, 'Create', 'ReadWrite', 'None') } catch { }

try {
    $devices = Adb devices
    if ($devices -match "$([regex]::Escape($serial))\s+device") {
        Write-Host "$Name already running on $serial"
    } elseif ($devices -match [regex]::Escape($serial)) {
        # Present but offline/booting - launching a second emulator would fight over the port.
        Write-Host "$serial is present but not ready yet; waiting instead of launching"
    } elseif (-not $lock) {
        Write-Host "another launcher is already starting $Name - waiting for it" -ForegroundColor Yellow
    } else {
        $id = Get-Identity $Name
        $flags = @(
            '-avd', $Name,
            '-port', $port,
            '-dns-server', $Dns,
            '-gpu', $Gpu,
            '-no-boot-anim',
            # Nothing to report home about, one less thread and one less connection.
            '-no-metrics',
            '-netdelay', 'none',
            '-netspeed', 'full',
            # The two identity bits the emulator itself can set, both verified to stick:
            # the SIM really answers this number (`service call iphonesubinfo 19`) and the
            # guest clock really moves. The region/locale is set over adb after boot -
            # `-prop persist.sys.locale` was tried first and left the prop empty.
            '-timezone', $id.Timezone,
            '-phone-number', $id.Phone
        )
        # Screen -> camera, when a region has been picked (manager > Screen scan, or
        # -PickRegion). The FILE is re-read by the guest at every camera session, but the
        # PATH is only read here - which is why an instance that is already up has to be
        # restarted once. Unquoted on purpose: $CamFile is guaranteed space-free by
        # common.ps1, and a camera path with a space is what the emulator cannot open at all
        # (the whole story is in the "screen -> guest camera" note there).
        if (Test-Path -LiteralPath $CamFile) {
            $flags += @('-camera-back', "imagefile:$CamFile")
        }

        # Two flags, not one: '-feature' takes the list as the NEXT argument, and several
        # features go in one comma-separated list ("-Vulkan,-QuickbootFileBacked"), never
        # as a second -feature (the last one would win and the first would be lost).
        $featOff = @()
        if (-not $Vulkan)        { $featOff += '-Vulkan' }
        if (-not $FileBackedRam) { $featOff += '-QuickbootFileBacked' }
        if ($featOff.Count)      { $flags += @('-feature', ($featOff -join ',')) }

        # -no-snapshot is load AND save: no 2 GB read at start, nothing to write at
        # shutdown. -Cold only ever meant "ignore the snapshot", so it is already implied.
        $bootMode = 'cold boot (no snapshot)'
        if (-not $Snapshot) { $flags += '-no-snapshot' }
        elseif ($Cold)      { $flags += '-no-snapshot-load'; $bootMode = 'cold boot, saves a snapshot on exit' }
        else                { $bootMode = 'resume from snapshot' }

        # adb has no trace of this AVD, so anything still holding it is a corpse.
        [void](Stop-StaleEmulator $Name)

        $script:BootStarted = $true
        Write-HostState 'before boot'
        Enter-BootGate

        # The emulator's own output is where every renderer, snapshot and acceleration
        # failure is explained, and it used to go nowhere at all. Truncated per boot, with
        # the interesting lines copied into this log by Write-Diagnosis when it matters.
        $emuOut = Join-Path $LogDir "$Name-emulator.log"
        $emuErr = Join-Path $LogDir "$Name-emulator.err.log"

        # The stall is intermittent - 6 consecutive launches came up in 1.5 s each, then
        # one hung forever - so it cannot be configured away, only recovered from. A
        # healthy launch opens the port in ~1.5 s; 45 s means it is never coming.
        $attempt = 0
        while ($true) {
            $attempt++
            Write-Log "booting $Name on port $port - $bootMode (gpu $Gpu, features off:$(if ($featOff.Count) { " $($featOff -join ' ')" } else { ' none' }), dns $Dns, ram $Ram MB)$(if ($attempt -gt 1) { " - try $attempt" })"
            Write-Log "  emulator.exe $($flags -join ' ')"
            try {
                # -WindowStyle Hidden hides the console emulator.exe would otherwise get
                # (the black "D:\Android\Sdk\emulator\emulator.exe" box). It does NOT hide
                # the device window: that belongs to the qemu child process, which is
                # created by emulator.exe with its own flags and does not inherit SW_HIDE.
                Start-Process -FilePath $emulator -ArgumentList $flags -WindowStyle Hidden `
                    -RedirectStandardOutput $emuOut -RedirectStandardError $emuErr
            } catch {
                # Only reachable when a previous emulator still holds these files open, so
                # keep booting - a boot is worth more than a tidy log file name.
                Write-Log "cannot redirect the emulator log ($($_.Exception.Message)) - using a per-process copy" 'WARN'
                $emuOut = Join-Path $LogDir "$Name-emulator.$PID.log"
                $emuErr = Join-Path $LogDir "$Name-emulator.$PID.err.log"
                Start-Process -FilePath $emulator -ArgumentList $flags `
                    -RedirectStandardOutput $emuOut -RedirectStandardError $emuErr
            }

            # Hold the lock until the port is actually claimed, otherwise releasing it
            # here just moves the double-launch race a few milliseconds later.
            $reg = [Diagnostics.Stopwatch]::StartNew()
            while ((Adb devices) -notmatch [regex]::Escape($serial) -and $reg.Elapsed.TotalSeconds -lt 45) {
                Start-Sleep -Milliseconds 500
            }
            if ((Adb devices) -match [regex]::Escape($serial)) {
                Write-Log ('console port {0} answered after {1:N1}s' -f $port, $reg.Elapsed.TotalSeconds) 'OK'
                break
            }

            Write-Log 'stalled in renderer init - no console port after 45s' 'WARN'
            Write-Diagnosis $Name
            [void](Stop-StaleEmulator $Name)
            if ($attempt -ge 3) {
                throw "$Name never opened port $port in 3 tries. The host GL context is refusing to come up - retry with -Gpu swangle (software, slower but always starts)."
            }
        }
    }
}
finally { if ($lock) { $lock.Close() } }

# sys.boot_completed is the only reliable ready signal; `adb wait-for-device` returns
# while the framework is still starting and app launches get silently dropped.
# Compared for equality, never pattern-matched: any stray text (an adb error, a warning)
# containing the digit 1 would otherwise read as "booted" and every check after this
# would run against a device that is not up yet.
$sw   = [Diagnostics.Stopwatch]::StartNew()
$next = 10
while ((Adb -s $serial shell getprop sys.boot_completed) -ne '1') {
    if ($sw.Elapsed.TotalSeconds -gt 300) {
        # A wedged host renderer looks exactly like this: adb stuck at "offline", black
        # window, boot_completed never set. Say so, or the next person re-runs it forever.
        # The trap writes the diagnosis (it does it for every fatal); doing it here as well
        # printed the whole block twice, 3 s apart, in the one log someone is trying to read.
        throw ("$Name did not finish booting in 300s (gpu $Gpu). If the window is black " +
               "and ``adb devices`` says offline, the renderer is the cause: retry with " +
               "-Gpu swangle -Cold.")
    }
    # "It is taking long" is useless on its own; every 10 s says WHAT it is doing - the adb
    # state, whether the guest has claimed its RAM yet, and how hard the box is working.
    if ($sw.Elapsed.TotalSeconds -ge $next) {
        $state = 'not listed'
        foreach ($l in ((Adb devices) -split "`n")) { if ($l -match "^$([regex]::Escape($serial))\s+(\S+)") { $state = $Matches[1] } }
        $ws = 0
        try {
            $q = @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -match "-avd\s+$([regex]::Escape($Name))(\s|$)" })
            if ($q.Count) { $ws = [int]($q[0].WorkingSetSize / 1MB) }
        } catch { }
        Write-Log ('  booting {0:N0}s: adb {1}, qemu {2} MB resident' -f $sw.Elapsed.TotalSeconds, $state, $ws)
        # Gone is not slow. This loop used to log "it died after opening the port" every 10 s
        # and then keep waiting the full 300 s anyway - holding the boot gate the whole time,
        # so closing one booting window meant nothing else in the group could start for five
        # minutes, and the dialog afterwards held it for five more. Confirmed 2 s later
        # before it is believed, so one missed poll never aborts a healthy boot.
        if ($state -eq 'not listed' -and $ws -eq 0) {
            Start-Sleep -Seconds 2
            if (Test-EmulatorGone $Name $serial) {
                Write-Log ('{0} stopped while booting - its emulator process is gone after {1:N0}s' -f $Name, $sw.Elapsed.TotalSeconds) 'WARN'
                # Before the diagnosis and before any dialog: the next queued instance is
                # waiting on this, and it has nothing to do with why this one went away.
                Exit-BootGate
                # A shutdown ON REQUEST (window X, -Stop, kill-all) says so in the emulator's
                # own log on the way out. That is a decision, not a failure, so it gets a log
                # line and no red dialog - the dialog it used to get blamed the GPU and sent
                # the next person chasing a renderer bug that was never there. Anything else
                # really is a crash and still gets the full diagnosis and the dialog, because
                # a hidden launcher that disappears in silence is worse.
                # $emuOut is only set by the branch that launched; a process that came in behind
                # another launcher still has the same log to read, at its usual name.
                $bye = Read-SharedText $(if ($emuOut) { $emuOut } else { Join-Path $LogDir "$Name-emulator.log" }) 8
                if ($bye -match 'shutdown gracefully|Saving snapshot') {
                    Write-Log 'it was shut down on request, not a boot failure - start it again when you want it' 'OK'
                    try { Stop-Transcript | Out-Null } catch { }
                } else {
                    Write-Diagnosis $Name
                    try { Stop-Transcript | Out-Null } catch { }
                    Show-Fatal ("$Name's emulator exited during boot, after {0:N0}s. Nothing of it is left running, and the boot gate is free, so you can start it again. The emulator's own log above says what it printed on the way out." -f $sw.Elapsed.TotalSeconds)
                }
                return
            }
        }
        if ($next % 30 -eq 0) { Write-HostState 'while booting' }
        $next += 10
    }
    Start-Sleep -Milliseconds 800
}
Write-Log ('ready in {0:N1}s' -f $sw.Elapsed.TotalSeconds) 'OK'
# Resume is over, so the disk is free: let the next queued instance start even though
# this script still has app launching and checks to do.
Exit-BootGate

# There is a window to hook now. One bridge serves every instance, so this is a no-op for
# all but the first boot.
Start-ClipboardBridge
# Same: one feeder for every instance, and it does nothing at all until a region is picked.
Start-ScreenCam

# Persisted in the guest, so this only ever costs one adb round-trip to confirm.
# Zeroing the three animation scales is the largest perceived-speed change in the UI, and
# the two network knobs stop the framework waking up to scan for Wi-Fi it will never use.
# One shell call, not five: each adb round-trip is ~100 ms of boot time.
$idNow = Get-Identity $Name
if ((Adb -s $serial shell settings get global window_animation_scale) -ne '0.0') {
    Adb -s $serial shell ("settings put global window_animation_scale 0.0; " +
                          "settings put global transition_animation_scale 0.0; " +
                          "settings put global animator_duration_scale 0.0; " +
                          "settings put global wifi_scan_always_enabled 0; " +
                          "settings put global network_recommendations_enabled 0") | Out-Null
    Write-Log 'animations off, wifi background scanning off (one-off)'
}
# The rest of the identity: what Settings shows and what the phone answers over Bluetooth.
# Shell is allowed to write these; ro.product.* it is not - see the $Personas note.
if ((Adb -s $serial shell settings get global device_name) -ne $idNow.Device) {
    # Backslash-escaped spaces, NOT quotes. PowerShell mangles a double quote inside an
    # argument on its way to a native exe, so `device_name "Redmi Note 9"` reached the
    # guest as three arguments and `settings put` answered "Argument expected to be
    # 'default'" - on stderr, which the Adb helper drops, so it failed in silence. The
    # guest shell unescapes `\ ` itself and the name keeps its real spaces.
    $dev = $idNow.Device -replace ' ', '\ '
    # system_locales, not -prop persist.sys.locale: the -prop never stuck (verified empty
    # in the guest), this is the value Android actually reads back.
    Adb -s $serial shell ("settings put global device_name $dev; " +
                          "settings put secure bluetooth_name $dev; " +
                          "settings put system system_locales $($idNow.Locale)") | Out-Null
    Write-Log "identity applied: $($idNow.Device) | $($idNow.Phone) | $($idNow.Timezone) | $($idNow.Locale)"
}

# ============================================================ installing an app
# Shared by -Apk (the batch path the group screen uses) and by the first-run install of
# settings.ini's Apk further down, so a bundle works in both places.
#
# .xapk / .apks / .apkm are zips: a base .apk, the split parts next to it, and sometimes an
# Android/obb/<pkg> tree the app expects on the sdcard. `adb install` refuses the lot; the
# parts go in together with `adb install-multiple` and the obb is pushed afterwards.
# .aab is NOT one of them: it is a build artefact and needs bundletool plus a signing key to
# become installable at all, so it is refused by name instead of failing obscurely.
function Install-AppFile([string] $file, [string] $serial, [string] $label) {
    if (-not (Test-Path -LiteralPath $file)) { throw "app file not found: $file" }
    $path = (Resolve-Path -LiteralPath $file).Path
    if ($path -match '\.aab$') {
        throw "an .aab is a build artefact, not an installable app: $path - it needs bundletool and a signing key. Download the .apk or .xapk instead."
    }
    $mb = [math]::Round((Get-Item -LiteralPath $path).Length / 1MB, 1)
    Write-Log "installing $(Split-Path -Leaf $path) ($mb MB) into $label"
    $sw      = [Diagnostics.Stopwatch]::StartNew()
    $tmpDir  = ''
    $bundle  = $null
    # NOT the Adb helper: it drops stderr, and the reason an install failed
    # (INSTALL_FAILED_*) is exactly what arrives there. -r replaces an existing copy, -g
    # pre-grants the runtime permissions the app declares so the first run does not open a
    # permission dialog on every single instance.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (Test-AppBundle $path) {
            # Under TEMP and per process: two instances installing the same bundle at once
            # must not unpack into the same folder.
            $tmpDir = Join-Path $env:TEMP ("avd-bundle-$PID-" + [IO.Path]::GetFileNameWithoutExtension($path))
            $bundle = Expand-AppBundle $path $tmpDir
            if (-not $bundle.Apks.Count) {
                Write-Log "  no .apk inside $(Split-Path -Leaf $path) - is it really an XAPK?" 'ERROR'
                return $false
            }
            $parts   = Select-BundleApks $bundle.Apks
            $dropped = @($bundle.Apks | Where-Object { $parts -notcontains $_ })
            Write-Log "  bundle: $($parts.Count) part(s) - $(($parts | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')"
            if ($dropped.Count) {
                Write-Log "  skipped other-ABI split(s): $(($dropped | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')"
            }
            if ($bundle.Obbs.Count) { Write-Log "  plus $($bundle.Obbs.Count) .obb for $($bundle.ObbPkg)" }
            $out = ((& $adb -s $serial install-multiple -r -g $parts 2>&1 | ForEach-Object { "$_" }) -join "`n").Trim()
        } else {
            $out = ((& $adb -s $serial install -r -g $path 2>&1 | ForEach-Object { "$_" }) -join "`n").Trim()
        }
        # Read before the finally below zeroes it - adb's exit code is the only thing left to
        # report when it fails and prints no reason. See the empty-reason branch further down.
        $code = $LASTEXITCODE

        if ($out -match 'Success') {
            Write-Log ("installed into $label in {0:N0}s" -f $sw.Elapsed.TotalSeconds) 'OK'
            # The obb only matters once the package is in: its folder is named after it.
            if ($bundle -and $bundle.Obbs.Count -and $bundle.ObbPkg) {
                $dst = "/sdcard/Android/obb/$($bundle.ObbPkg)"
                Adb -s $serial shell mkdir -p $dst | Out-Null
                foreach ($o in $bundle.Obbs) {
                    $po = ((& $adb -s $serial push $o $dst 2>&1 | ForEach-Object { "$_" }) -join ' ').Trim()
                    if ($po -match 'error|failed') { Write-Log "  obb push FAILED: $po" 'ERROR' }
                    else { Write-Log "  pushed $(Split-Path -Leaf $o) to $dst" 'OK' }
                }
            }
            # The package name is what makes it launchable later, and aapt is not guaranteed to
            # be here, so it is read back from the guest instead: newest package wins.
            $pkg = Adb -s $serial shell "pm list packages -3 --user 0 | tail -3"
            if ($pkg) { Write-Log "  third-party packages now: $($pkg -replace 'package:', '' -replace "`n", ', ')" }
            return $true
        }

        Write-Log "install FAILED on $label (adb exit $code)" 'ERROR'
        foreach ($l in ($out -split "`n")) { if ($l.Trim()) { Write-Log "  $l" 'ERROR' } }
        # adb prints "failed to install <file>:" and then NOTHING when the install did not get
        # far enough to be given a reason. Measured on wa07: that exact line, 3m38s into a
        # 135 MB stream, while com.whatsapp was already up from a Play Store install of the
        # same app - the package manager was busy with the other installer. So an empty reason
        # is not "unknown error", it is "ask the guest", and the guest is asked here: a package
        # that is present now got installed by whoever won, and reporting FAILED for that sent
        # the last three hours chasing a broken APK that was never broken.
        if ($out -notmatch 'INSTALL_FAILED|INSTALL_PARSE_FAILED|Failure|Exception|Error:') {
            $have = @((Adb -s $serial shell 'pm list packages -3 --user 0') -split "`n" |
                      ForEach-Object { ($_ -replace 'package:', '').Trim() } | Where-Object { $_ })
            if ($have.Count) { Write-Log "  third-party packages in the guest right now: $($have -join ', ')" 'WARN' }
            Write-Log '  adb gave no reason at all. Something else held the package manager - the Play Store' 'WARN'
            Write-Log '  installing the same app is the usual one - or the stream was cut (window closed,' 'WARN'
            Write-Log '  -Stop, kill-all). Look at the list above before retrying: if the app is there, it' 'WARN'
            Write-Log '  IS installed and this was a race, not a failure.' 'WARN'
        }
        foreach ($sig in @(
            @{ M = 'INSTALL_FAILED_MISSING_SPLIT'
               W = 'the app wants a split this bundle does not carry - install the whole .xapk, not one .apk out of it' }
            @{ M = 'INSTALL_FAILED_INVALID_APK.*split|Split .* not found'
               W = 'the bundle mixes ABI splits - Select-BundleApks keeps one, so this is a bundle whose parts do not belong together' }
            @{ M = 'INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match'
               W = 'a different build of the same app is already installed - uninstall it in the guest first (its data goes with it)' }
            @{ M = 'INSTALL_FAILED_VERSION_DOWNGRADE'
               W = 'the installed copy is NEWER than this APK - uninstall it first, or install a newer APK' }
            @{ M = 'INSTALL_FAILED_NO_MATCHING_ABIS'
               W = 'this APK has no x86_64 or arm64 code. android-30 playstore translates arm64, so the APK is probably armeabi-v7a only' }
            @{ M = 'INSTALL_FAILED_INSUFFICIENT_STORAGE'
               W = 'the guest data partition is full - disk.dataPartition.size is 6 GB by default' }
            @{ M = 'INSTALL_FAILED_OLDER_SDK'
               W = 'the APK needs a newer Android than 11 (API 30) - a newer system image is needed in settings.ini' }
            @{ M = 'device unauthorized|device offline|device .* not found'
               W = 'the instance is not answering adb - start it first' }
        )) { if ($out -match $sig.M) { Write-Log "  -> $($sig.W)" 'WARN' } }
        return $false
    }
    finally {
        $ErrorActionPreference = $prev
        # adb exits non-zero on a failed install and PowerShell hands the last native exit
        # code back as the script's, so run-<name>.bat would print "exit code: 1".
        $global:LASTEXITCODE = 0
        if ($tmpDir -and (Test-Path -LiteralPath $tmpDir)) {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================ -Apk: install an app
# One app into this instance, then stop - no WhatsApp launch, because this is the batch
# path: the group screen calls it once per checked instance, so each install is logged in
# its own instance log and none of them freezes the window. An instance that is off boots
# first (the boot section above already ran), which is what "install on all of them" has to
# mean when only some are up.
if ($Apk) {
    [void](Install-AppFile $Apk $serial $Name)
    try { Stop-Transcript | Out-Null } catch { }
    return
}

# ============================================================ -Paste
if ($Paste) {
    # KEYCODE_PASTE, not `input text`. This used to type the clipboard out character by
    # character, which cannot carry anything outside ASCII - and this is a WhatsApp box, so
    # most of what gets pasted is Arabic. Measured on wa01, same field, same clipboard:
    #     adb shell input text 'مرحبا'   java.lang.NullPointerException in Input.sendText,
    #                                    nothing typed at all
    #     adb shell input keyevent 279   field showed "مرحبا 👋 سطر", newline and emoji intact
    # It works because host->guest clipboard sharing already does its half by itself
    # (verified: 'CLIPTEST123' set in Windows came back out of the guest), so by the time
    # this runs the guest clipboard already holds the Windows text. The old escaping, the %
    # workaround and the per-line KEYCODE_ENTER all go with it - a real paste needs none.
    $text = Get-Clipboard -Raw
    if (-not $text) {
        Write-Host "Windows clipboard is empty" -ForegroundColor Yellow
    } else {
        Adb -s $serial shell input keyevent 279 | Out-Null
        Write-Host "pasted $($text.Length) chars into the focused field"
    }
}

# ============================================================ capability check
if ($Check) {
    Write-Host "`n== identity (differs per instance) ==" -ForegroundColor Cyan
    Write-Host "  device name  : $(Adb -s $serial shell settings get global device_name)"
    Write-Host "  phone number : $($idNow.Phone)"
    Write-Host "  timezone     : $(Adb -s $serial shell getprop persist.sys.timezone)  ($(Adb -s $serial shell date))"
    Write-Host "  region       : $(Adb -s $serial shell settings get system system_locales)  (bluetooth name: $(Adb -s $serial shell settings get secure bluetooth_name))"
    Write-Host "  screen       : $(Adb -s $serial shell wm size) / $(Adb -s $serial shell wm density)"
    Write-Host "  identity file: $(Get-IdentityFile $Name)"
    Write-Host "  NOTE model/brand/fingerprint/IMEI below are the SAME on every instance:" -ForegroundColor Yellow
    Write-Host "  one read-only system image is shared, and -prop cannot override a ro.* it set." -ForegroundColor Yellow

    Write-Host "`n== device ==" -ForegroundColor Cyan
    Write-Host "  android      : $(Adb -s $serial shell getprop ro.build.version.release) (API $(Adb -s $serial shell getprop ro.build.version.sdk))"
    Write-Host "  model        : $(Adb -s $serial shell getprop ro.product.brand) / $(Adb -s $serial shell getprop ro.product.model)"
    Write-Host "  abis         : $(Adb -s $serial shell getprop ro.product.cpu.abilist)"
    Write-Host "  fingerprint  : $(Adb -s $serial shell getprop ro.build.fingerprint)"

    Write-Host "`n== google play ==" -ForegroundColor Cyan
    foreach ($p in @(
        @('com.android.vending',    'Play Store  '),
        @('com.google.android.gms', 'Play Services'),
        @('com.google.android.gsf', 'Services Fwk')
    )) {
        $ver = Adb -s $serial shell "dumpsys package $($p[0]) | grep -m1 versionName"
        if ($ver) { Write-Host "  OK   $($p[1]) : $($ver.Trim())" } else { Write-Host "  FAIL $($p[1]) : not installed" -ForegroundColor Yellow }
    }
    Write-Host "  certification: Play Store > Settings > About > 'Play Protect certification'"
    Write-Host "                 (the 'playstore' image is certified; 'google_apis' would not be)"

    # The one question this project kept re-answering out of logcat by hand, printed instead
    # of argued about. Read the measured wa07 column below before theorising: everything a
    # user can configure is already right there, and it still fails.
    #
    #   property                   wa07 (playstore image)   a real certified phone
    #   ro.build.tags              release-keys      OK     release-keys
    #   installerPackageName       com.android.vending OK   com.android.vending
    #   Play Services              26.32.34          OK     current
    #   ro.kernel.qemu             1                 <-     absent
    #   ro.boot.verifiedbootstate  (empty)           <-     green
    #   ro.boot.flash.locked       (empty)           <-     1
    #   strongbox_keystore         absent            <-     present
    #   ro.build.fingerprint       google/sdk_gphone_x86_64/...  the real model
    #
    # release-keys is NOT the good news it looks like - the playstore image really is signed
    # release-keys and Play-Protect certified, and that only ever gets you PLAY_RECOGNIZED.
    # The four marked rows are MEETS_DEVICE_INTEGRITY, and none of them is a setting: the
    # verdict is a token minted by GOOGLE's servers from a key whose certificate chain roots
    # in an attestation key burned into a real TEE at the factory, then read by WHATSAPP's
    # servers. Editing ro.* changes what apps inside the guest see and changes nothing about
    # what that token says, because a signature cannot be produced without the private key.
    # That is why no Android version, no fingerprint, no model name and no amount of
    # "make it look like a real phone" moves this line.
    Write-Host "`n== integrity (why registration blocks here) ==" -ForegroundColor Cyan
    $tags    = Adb -s $serial shell getprop ro.build.tags
    $qemu    = Adb -s $serial shell getprop ro.kernel.qemu
    $vbstate = Adb -s $serial shell getprop ro.boot.verifiedbootstate
    $locked  = Adb -s $serial shell getprop ro.boot.flash.locked
    $fp      = Adb -s $serial shell getprop ro.build.fingerprint
    $strong  = $(if ((Adb -s $serial shell pm list features) -match 'strongbox_keystore') { 'present' } else { 'absent' })
    Write-Host "  build tags   : $tags$(if ($tags -match 'release-keys') { '   (expected here - and not enough on its own)' })"
    Write-Host "  kernel.qemu  : $qemu$(if ($qemu -eq '1') { '   <- emulator, and the guest says so itself' })"
    Write-Host "  verified boot: $(if ($vbstate) { $vbstate } else { '(empty)   <- no verified boot chain' })"
    Write-Host "  flash.locked : $(if ($locked) { $locked } else { '(empty)   <- no locked bootloader' })"
    Write-Host "  strongbox    : $strong$(if ($strong -eq 'absent') { '    <- no hardware-backed attestation' })"
    Write-Host "  fingerprint  : $fp"
    $inst = Adb -s $serial shell "dumpsys package $Pkg | grep -m1 installerPackageName"
    if ($inst) { Write-Host "  installed by : $($inst.Trim())  (com.android.vending = from the Play Store)" }
    # -t implies -d, and 4000 lines is far enough back to catch a block from this boot
    # without dumping the whole ring buffer through adb.
    $blocked = Adb -s $serial shell "logcat -t 4000 | grep -m1 -E 'CustomRegistrationBlockActivity|parole'"
    if ($blocked) { Write-Host "  parole block : SEEN in this boot's logcat - $($blocked.Trim())" -ForegroundColor Yellow }
    if ($qemu -eq '1' -or -not $vbstate -or -not $locked -or $strong -eq 'absent' -or $tags -match 'test-keys') {
        Write-Host "  VERDICT: this device cannot return MEETS_DEVICE_INTEGRITY. That is hardware-backed" -ForegroundColor Yellow
        Write-Host "  key attestation - a real TEE and a verified boot chain - which no emulator has, at any" -ForegroundColor Yellow
        Write-Host "  API level and with any fingerprint. Measured here: WhatsApp installed BY THE PLAY" -ForegroundColor Yellow
        Write-Host "  STORE (com.android.vending, 2.26.33.74) on this certified image still shows 'Download" -ForegroundColor Yellow
        Write-Host "  the official WhatsApp to continue' with zero interaction. Everything configurable is" -ForegroundColor Yellow
        Write-Host "  already correct, so there is nothing left to fix on this side - register on a" -ForegroundColor Yellow
        Write-Host "  Play-certified phone. Why properties cannot help: the comment above this block." -ForegroundColor Yellow
    }

    Write-Host "`n== capabilities ==" -ForegroundColor Cyan
    $feat = Adb -s $serial shell pm list features
    foreach ($f in @(
        @('android.software.managed_users', 'work profile (Shelter/Island) -> 4 accounts/instance'),
        @('android.hardware.camera',        'camera'),
        @('android.hardware.telephony',     'telephony / SIM'),
        @('android.hardware.location.gps',  'GPS'),
        @('android.hardware.microphone',    'microphone (voice notes)')
    )) {
        if ($feat -match [regex]::Escape($f[0])) { Write-Host "  OK   $($f[1])" } else { Write-Host "  FAIL $($f[1])" -ForegroundColor Yellow }
    }
    Write-Host "  users        : $((Adb -s $serial shell pm list users) -replace '\s+', ' ')"
}

# ============================================================ network diagnostics
if ($Net) {
    Write-Host "`n== guest network ==" -ForegroundColor Cyan
    # Android keeps the default route in a per-network table, not in `main`, so a bare
    # `ip route` looks routeless even on a healthy device. Always look at all tables.
    Write-Host "  default routes :"
    (Adb -s $serial shell "ip route show table all | grep default") -split "`n" | ForEach-Object { Write-Host "    $_" }
    Write-Host "  dns servers    : $(Adb -s $serial shell 'getprop | grep -i net.dns')"
    Write-Host "  resolver       : $(Adb -s $serial shell 'dumpsys dns | grep -m2 -i server')"

    Write-Host "  gateway 10.0.2.2 :"
    (Adb -s $serial shell "ping -c 2 -W 2 10.0.2.2 | tail -2") -split "`n" | ForEach-Object { Write-Host "    $_" }
    Write-Host "  ping 8.8.8.8   :"
    (Adb -s $serial shell "ping -c 3 -W 2 8.8.8.8 | tail -2") -split "`n" | ForEach-Object { Write-Host "    $_" }

    $dnsTest = Adb -s $serial shell "ping -c 2 -W 3 www.google.com | tail -2"
    if ($dnsTest) { Write-Host "  resolve google :"; $dnsTest -split "`n" | ForEach-Object { Write-Host "    $_" } }
    else          { Write-Host "  resolve google : FAILED (DNS is the problem, not routing)" -ForegroundColor Yellow }

    # A 204 here is exactly what Android itself uses to decide whether to show the
    # "connected, no internet" warning.
    $http = Adb -s $serial shell "curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://connectivitycheck.gstatic.com/generate_204"
    Write-Host "  captive check  : HTTP $http  (204 = real internet)"
    if ($http -ne '204') {
        Write-Host "`n  ping works but this does not -> host firewall or 360 Total Security blocking qemu." -ForegroundColor Yellow
        Write-Host "  nothing works -> retry with -Cold (a resumed snapshot keeps the network state it" -ForegroundColor Yellow
        Write-Host "  was saved with), or with -Dns 192.168.1.1 if the router intercepts port 53." -ForegroundColor Yellow
    }
}

# ============================================================ -ResetApp
# The way out of WhatsApp's "Download the official WhatsApp to continue / We couldn't verify
# that you're using the official WhatsApp app" screen, i.e.
# com.whatsapp.registration.app.parole.CustomRegistrationBlockActivity. "parole" is
# WhatsApp's server-side block system.
#
# ---- what that screen is NOT ----------------------------------------------------------
#   * not the APK, when it came from the Store. Measured on wa01: installerPackageName=
#     com.android.vending, versionName=2.26.33.74, one signer, PackageSignatures{version:3}.
#     Nothing re-signed, nothing modded. (A sideloaded copy is a different matter - the
#     installer package is then the shell, which is why settings.ini's Apk is off now.)
#   * not this machine's IP, and not merely "an emulator is running". Side by side, same
#     host, same minute, same APK: 3794xa with a fresh WhatsApp and no account sat on the
#     number screen for 200 s untouched and was never blocked, while wa01 - one account
#     signing back in - was blocked inside 120 s, every time.
#
# ---- what it IS: TWO gates, and only one of them is reachable from here ---------------
# An earlier version of this note said "not Play Integrity - the screen appears just the
# same after `pm disable-user com.android.vending`". That reasoning was wrong, and wrong in
# the expensive direction: with the Store disabled there is no token to be had, so the
# request fails and the block comes anyway. Same screen, different cause. With a Google
# account signed in on wa07 the timing is not ambiguous (logcat, one run, 4 s end to end):
#     15:54:29.702  START ...registration.app.verifyphone.VerifyPhoneNumber   number ACCEPTED
#     15:54:30.054  StandardIntegrity : requestExpressIntegrityToken(...)     token requested
#     15:54:33.563  START ...registration.app.parole.CustomRegistrationBlockActivity
#   gate 1 - ISSUING a token. Needs the Play Store plus a signed-in Google account. Passable
#            here, and it was passed: reaching VerifyPhoneNumber is the proof, and it also
#            proves the NUMBER itself was accepted.
#   gate 2 - the VERDICT inside that token, judged on WhatsApp's server. MEETS_DEVICE_
#            INTEGRITY is hardware-backed key attestation: a real TEE and a verified boot
#            chain. No AVD has either - test-keys, ro.kernel.qemu=1, no hardware keystore -
#            so the verdict comes back without device integrity and the server refuses.
#            `run-<name>.bat -Check` prints exactly those three lines under "integrity", so
#            this never has to be argued from logs again.
# Gate 2 is Google's design, not a setting: no APK version, no wipe, no Google account and
# no tuning in this project moves it. wa01 and wa05 registered before WhatsApp required this
# at sign-up, which is why they exist and a new one cannot be made the same way.
#
# The install-source theory is DEAD, and this is the measurement that killed it - do not
# spend another hour on it. wa07, read straight off the device:
#     installerPackageName = com.android.vending      <- the Play Store, not a sideload
#     versionName          = 2.26.33.74               <- the Store's own build
#     firstInstallTime     = 2026-08-27 17:55:09
#     ro.build.tags        = release-keys             <- certified image
#     Play Services        = 26.32.34                 <- current
# Official app, Store-installed, certified image, Google account signed in, everything a
# person can configure already correct - and it shows "Download the official WhatsApp to
# continue" at app START, with zero interaction, before a number can even be typed. The
# sideloads on 3794xa/wa02/wa05/wa06 were a real defect (fixed: settings.ini Apk is off) but
# they were never THE cause. What is left is only what cannot be configured: qemu, no
# verified boot, no locked bootloader, no strongbox. See the table in -Check.
#
# ---- "but it worked last night" - it did, and that is the point -----------------------
# Same box, same disk, same system image, same APK file, ONE day:
#     01:16-01:41  wa05 created, WhatsApp installed, registered BY HAND, stayed logged in
#     17:55-19:04  wa07, Play-Store-installed, blocked at app start with zero interaction
# Nothing on this side changed in those 17 hours - so nothing on this side is what broke.
# The gate is a THRESHOLD applied on WhatsApp's server when it reads the token: a certified
# emulator can reach MEETS_BASIC_INTEGRITY, and never MEETS_DEVICE_INTEGRITY. Accepting the
# first is what made last night work; requiring the second is what ends it. That threshold
# is theirs to set and it rolls out gradually, which is also why one number/region/account
# can still behave differently from another for a while. Inference from the evidence, not a
# document from WhatsApp - but the half that matters is measured: nothing local changed,
# so nothing local fixes it. Do not go looking for a setting that was never involved.
# The way through is a Play-certified physical phone (Play Store > Settings > About > Play
# Protect certification = certified) with WhatsApp installed FROM the Play Store.
# What is not worth trying: rooting an AVD with Magisk + a Play-Integrity-spoofing module.
# It forges an anti-fraud verdict, breaks on every WhatsApp or Play update, and the number
# pays for it - see the next paragraph for who the block actually follows.
#
# ---- and the block belongs to the ACCOUNT ---------------------------------------------
# Not to the instance. It is also what WhatsApp shows a number it has seen on a modified
# client (GB/Plus/...), which is why it follows that number onto a real phone too, and why
# it came back on wa01 an hour after a login that had already succeeded. So this switch is
# first aid, not a cure: it clears the stuck screen so the app can ask again, and a flagged
# number is told the same thing. Register fresh WITHOUT restoring a Drive backup (a backup
# made by a modified client re-flags it), and if it still blocks, appeal from the app under
# Settings > Help > Contact us.
#
# Retrying costs something: repeated registration attempts for one number are exactly what
# the abuse system is watching. Wipe, sign in, stop - never sit on a retry loop. This is
# also why nothing here opens WhatsApp for you any more; see the end of this file.
if ($ResetApp) {
    if (-not $Force) { throw "-ResetApp erases $Name's WhatsApp session and its local chat history (a Drive/email backup is the only way back). Re-run with -Force." }
    if ((Adb -s $serial shell pm path $Pkg) -notmatch 'package:') { throw "WhatsApp is not installed in $Name - nothing to reset." }
    # WHO INSTALLED IT decides whether this switch can help at all, so it is read before the
    # wipe instead of after the next hour of retrying. `pm clear` erases DATA; it cannot
    # change where the package came from, and "we couldn't verify that you're using the
    # official WhatsApp app" is a complaint about exactly that. Measured on 3794xa: WhatsApp
    # arrived by `-Apk C:\Users\user\Downloads\WhatsApp.apk` (its own log, 00:22:29), so the
    # installer is the shell; -ResetApp was then run against that screen at 15:43 and the
    # screen came back with zero interaction. It was never going to work, and nothing said so.
    $inst = Adb -s $serial shell "dumpsys package $Pkg | grep -m1 installerPackageName"
    Adb -s $serial shell "pm clear $Pkg" | Out-Null
    Write-Log "$Pkg data wiped - it starts at the language/EULA screen and has to sign in again"
    if ($inst -notmatch 'com\.android\.vending') {
        Write-Log "this copy was NOT installed by the Play Store ($($inst.Trim())) - a sideload." 'WARN'
        Write-Log 'So if the screen you are trying to clear is "Download the official WhatsApp to' 'WARN'
        Write-Log 'continue", this wipe cannot fix it: the complaint is about where the package came' 'WARN'
        Write-Log 'from, and pm clear only erases data. Remove it and let the Play Store install it:' 'WARN'
        Write-Log "    adb -s $serial uninstall $Pkg" 'WARN'
        Write-Log '    then, INSIDE the emulator window: Play Store > search WhatsApp > Install' 'WARN'
        Write-Log '(a Google account has to be signed in for that, and keep settings.ini Apk empty' 'WARN'
        Write-Log 'or the next boot silently sideloads it again.)' 'WARN'
    }
}

# ============================================================ first-run app install
# OFF unless settings.ini names an Apk, and it does not any more - the line is commented out
# there. It used to be the fast path: a fresh instance sideloads WhatsApp in 96 s (measured
# on wa05) and needs no Google account. What that buys is a copy whose installerPackageName
# is the shell instead of com.android.vending, and that is one of the signals WhatsApp reads
# before it registers a number, so the shortcut works against the only thing it was for.
# Uncomment Apk in settings.ini to bring it back knowing that; -Apk <file> is the explicit
# per-instance version and always works.
if ($Settings.Apk -and (Adb -s $serial shell pm path $Pkg) -notmatch 'package:') {
    if (-not (Test-Path -LiteralPath $Settings.Apk)) {
        Write-Log "settings.ini names an Apk that is not there: $($Settings.Apk)" 'WARN'
    } else {
        # Same installer as -Apk, so settings.ini can name an .xapk as well as an .apk and
        # the INSTALL_FAILED_* hints are written here too.
        Write-Log "$Pkg is missing"
        [void](Install-AppFile $Settings.Apk $serial $Name)
    }
}

# ============================================================ no automation, by design
# This used to end with
#     adb shell monkey -p com.whatsapp -c android.intent.category.LAUNCHER 1
# on EVERY boot. That is gone and is not coming back. Two reasons, in order:
#   * asked for. Nothing in this project may drive WhatsApp - no launch, no taps, no typing
#     into it. -Paste is the only thing that puts text in a field and a human presses it.
#   * it worked against the thing it was for. A registration that has not finished is
#     re-opened by every boot, and "the same number reaches the registration screen again
#     and again from the same machine" is precisely the pattern WhatsApp's abuse system
#     counts. Boot, then open it once, by hand, when you are ready to type the code.
# The two hidden helpers a boot still starts (clipboard bridge, screen-camera feeder) only
# ever react to your own keypress / repaint a picture; neither one touches an app. kill-all.bat
# sweeps them if you want them gone.
if ((Adb -s $serial shell pm path $Pkg) -notmatch 'package:') {
    Write-Log 'WhatsApp is not installed here. Install it INSIDE the emulator from the Play Store (Play-Store-installed is what its own checks look for), or, knowing that, sideload one with -Apk <file>.' 'WARN'
}

Write-Log "close with the window X (or -Stop, or kill-all.bat) - that lets Android flush"
Write-Log "userdata. Killing it from Task Manager risks the WhatsApp session, not just speed."

# ---------------------------------------------------------------------------------
# Biggest remaining speed win: $AvdHome is on D:, a 7200rpm spinning disk, and every
# resume reads hw.ramSize bytes from it. C: is an NVMe SSD but has ~6 GB free. Free
# up C: and move the instances there:
#     (stop everything first)
#     robocopy D:\Android\avd C:\Android\avd /E /MOVE
#     setx ANDROID_AVD_HOME C:\Android\avd
#     ... and point AvdHome there in settings.ini (manager window > Settings).
# At 1536 MB RAM and a 4 GB data partition each instance costs ~6 GB there.
