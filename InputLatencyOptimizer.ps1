<#
    Input Latency Optimizer 1.0
    Reversible Windows 10/11 tweaks that target input latency.

    * Start it with Start.cmd (it asks for administrator rights).
    * Before any value is changed, its original state is saved to
      %ProgramData%\InputLatencyOptimizer\backup.json. "Revert selected" or
      "Restore everything" in the app puts things back.
    * Read-only switches (they change nothing):
        -Status    print the state of every tweak and exit
        -SelfTest  build the window without showing it, run all checks, exit
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$AppName    = 'Input Latency Optimizer'
$AppVersion = '1.0'
$DataDir    = Join-Path $env:ProgramData 'InputLatencyOptimizer'
$BackupFile = Join-Path $DataDir 'backup.json'
$LogFile    = Join-Path $DataDir 'log.txt'
$ReadOnly   = [bool]($Status -or $SelfTest)

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $ReadOnly -and -not (Test-Admin)) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    } catch {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show('Administrator rights are needed to change system settings.', $AppName)
    }
    exit
}

# ------------------------------------------------------------------ native calls
if (-not ('ILO.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ILO {
    public static class Native {
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        public static extern bool SystemParametersInfo(uint action, uint param, int[] data, uint winIni);

        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        public static extern bool SystemParametersInfoNull(uint action, uint param, IntPtr data, uint winIni);

        [DllImport("ntdll.dll")]
        public static extern int NtQueryTimerResolution(out uint coarsest, out uint finest, out uint current);

        [DllImport("ntdll.dll")]
        public static extern int NtSetTimerResolution(uint desired, [MarshalAs(UnmanagedType.U1)] bool set, out uint current);

        [StructLayout(LayoutKind.Sequential)]
        public struct PowerThrottlingState { public uint Version; public uint ControlMask; public uint StateMask; }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetProcessInformation(IntPtr process, int infoClass, ref PowerThrottlingState info, uint size);

        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();

        // Windows 11 ignores timer requests from minimized/hidden windows unless the process
        // opts out of that throttling (PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION).
        public static bool HonorTimerResolutionWhenHidden() {
            PowerThrottlingState s = new PowerThrottlingState();
            s.Version = 1; s.ControlMask = 4; s.StateMask = 0;
            try { return SetProcessInformation(GetCurrentProcess(), 4, ref s, (uint)Marshal.SizeOf(typeof(PowerThrottlingState))); }
            catch { return false; }
        }
    }
}
'@
}

$SPI_SETMOUSE          = 0x0004
$SPI_SETKEYBOARDSPEED  = 0x000B
$SPI_SETKEYBOARDDELAY  = 0x0017
$SPI_SETANIMATION      = 0x0049
$SPI_SETMENUSHOWDELAY  = 0x006B
$SPIF_SENDCHANGE       = 2

# ------------------------------------------------------------------ registry
function Open-RegKey([string]$Path, [switch]$Write, [switch]$Create) {
    $hive, $sub = $Path -split '\\', 2
    $h = switch ($hive) {
        'HKLM'  { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKCU'  { [Microsoft.Win32.RegistryHive]::CurrentUser }
        default { throw "Unknown registry hive in $Path" }
    }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($h, [Microsoft.Win32.RegistryView]::Registry64)
    if ($Create) { return $base.CreateSubKey($sub) }
    return $base.OpenSubKey($sub, [bool]$Write)
}

function Read-RegValue([string]$Path, [string]$Name) {
    $k = Open-RegKey $Path
    if ($null -eq $k) { return @{ Exists = $false } }
    try {
        if (@($k.GetValueNames()) -notcontains $Name) { return @{ Exists = $false } }
        $kind = $k.GetValueKind($Name)
        $val  = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        return @{ Exists = $true; K = [string]$kind; V = $val }
    } finally { $k.Close() }
}

function Get-RegString([string]$Path, [string]$Name, [string]$Default) {
    $v = Read-RegValue $Path $Name
    if ($v.Exists -and "$($v.V)" -ne '') { return "$($v.V)" }
    return $Default
}

function ConvertTo-RegData([string]$Kind, $Value) {
    switch ($Kind) {
        'DWord'       { $n = [long]$Value; if ($n -gt [int]::MaxValue) { $n -= 4294967296 }; return [int]$n }
        'QWord'       { return [long]$Value }
        'Binary'      { return , ([byte[]]@($Value)) }
        'MultiString' { return , ([string[]]@($Value)) }
        default       { return [string]$Value }
    }
}

function Write-RegValue([string]$Path, [string]$Name, [string]$Kind, $Value) {
    $k = Open-RegKey $Path -Create
    try { $k.SetValue($Name, (ConvertTo-RegData $Kind $Value), [Microsoft.Win32.RegistryValueKind]$Kind) }
    finally { $k.Close() }
}

function Remove-RegValue([string]$Path, [string]$Name) {
    $k = Open-RegKey $Path -Write
    if ($null -eq $k) { return }
    try { $k.DeleteValue($Name, $false) } finally { $k.Close() }
}

function Remove-EmptyKey([string]$Path) {
    $k = Open-RegKey $Path
    if ($null -eq $k) { return }
    $empty = ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0)
    $k.Close()
    if (-not $empty) { return }
    $i = $Path.LastIndexOf('\')
    $parent = Open-RegKey $Path.Substring(0, $i) -Write
    try { $parent.DeleteSubKey($Path.Substring($i + 1), $false) } finally { $parent.Close() }
}

function RegValue([string]$Path, [string]$Name, [string]$Kind, $Value) {
    @{ P = $Path; N = $Name; K = $Kind; V = $Value }
}

function Test-RegMatch($Spec) {
    $cur = Read-RegValue $Spec.P $Spec.N
    if (-not $cur.Exists) { return $false }
    if ($Spec.K -eq 'DWord' -or $Spec.K -eq 'QWord') {
        try { return ((ConvertTo-RegData $Spec.K $cur.V) -eq (ConvertTo-RegData $Spec.K $Spec.V)) } catch { return $false }
    }
    return ([string]$cur.V -eq [string]$Spec.V)
}

# Records the original state of a value in a tweak's backup, once.
function Save-RegValueState($Data, [string]$Path, [string]$Name) {
    if ($null -eq $Data.reg) { $Data.reg = @() }
    foreach ($e in @($Data.reg)) { if ($e.P -eq $Path -and $e.N -eq $Name) { return } }
    $cur = Read-RegValue $Path $Name
    $Data.reg = @($Data.reg) + @(@{ P = $Path; N = $Name; Exists = [bool]$cur.Exists; K = $cur.K; V = $cur.V })
}

$script:Build = 0
try { $script:Build = [int](Read-RegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber').V } catch {}

# ------------------------------------------------------------------ power plans
$GuidRx        = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$UltimateGuid  = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighGuid      = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$BalancedGuid  = '381b4222-f694-41f0-9685-ff5bb260df2e'
$SaverGuid     = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$SubUsb        = '2a737441-1930-4402-8d77-b2bebba308a3'
$SetUsbSuspend = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$SubPcie       = '501a4d13-42af-4429-9fd1-a8218c268e20'
$SetPcieAspm   = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
$SubCpu        = '54533251-82be-4824-96c1-47b60b740d00'
$SetCpuMin     = '893dee8e-2bef-41e0-89c6-b55d0929964c'
$SetCpuEpp     = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'
$SetCpuPark    = '0cc5b647-c1df-4637-891a-dec35c318583'

function Get-ActiveScheme {
    $out = (& powercfg.exe /getactivescheme) -join ' '
    @{ Guid = [regex]::Match($out, $GuidRx).Value.ToLower(); Name = [regex]::Match($out, '\((.+)\)').Groups[1].Value.Trim() }
}

function Get-SchemeGuids {
    @(& powercfg.exe /list | ForEach-Object { [regex]::Match($_, $GuidRx).Value.ToLower() } | Where-Object { $_ })
}

# Returns the AC/DC index of a setting (plus Min/Max for range settings), or $null when the
# setting does not exist on this PC. Parses only the hex values, so any display language works.
function Get-PowerValue([string]$Scheme, [string]$Sub, [string]$Setting) {
    $out = & powercfg.exe /qh $Scheme $Sub $Setting
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    $hex = @([regex]::Matches(($out -join "`n"), '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) })
    if ($hex.Count -lt 2) { return $null }
    $r = @{ AC = $hex[-2]; DC = $hex[-1]; Min = $null; Max = $null }
    if ($hex.Count -ge 5) { $r.Min = $hex[-5]; $r.Max = $hex[-4] }   # min, max, increment, AC, DC
    $r
}

# False when the setting is missing or its allowed range (sometimes locked by other tools) excludes the target.
function Test-PowerSupported($Value, $Target) {
    if ($null -eq $Value) { return $false }
    if ($null -eq $Value.Max) { return $true }
    return ($Target -ge $Value.Min -and $Target -le $Value.Max)
}

function Test-PowerTweak($t) {
    $total = 0; $hit = 0
    foreach ($p in $t.Power) {
        $v = Get-PowerValue 'SCHEME_CURRENT' $p.Sub $p.Set
        if (-not (Test-PowerSupported $v $p.V)) { continue }
        $total++
        if ($v.AC -eq $p.V) { $hit++ }
    }
    if ($total -eq 0) { 'NA' } elseif ($hit -eq $total) { 'Applied' } elseif ($hit -gt 0) { 'Partial' } else { 'Default' }
}

# Plugged-in (AC) values only, so laptop battery life is untouched.
function Set-PowerTweak($t, $Data) {
    if ($null -eq $Data.schemes) { $Data.schemes = @{} }
    $scheme = (Get-ActiveScheme).Guid
    if (-not $Data.schemes.ContainsKey($scheme)) {
        $orig = foreach ($p in $t.Power) {
            $v = Get-PowerValue $scheme $p.Sub $p.Set
            if ($null -ne $v) { @{ Sub = $p.Sub; Set = $p.Set; AC = $v.AC } }
        }
        $Data.schemes[$scheme] = @($orig)
    }
    foreach ($p in $t.Power) {
        if (-not (Test-PowerSupported (Get-PowerValue $scheme $p.Sub $p.Set) $p.V)) {
            Write-Log "  '$($p.Label)' is missing or locked in this power plan - skipped"
            continue
        }
        & powercfg.exe /setacvalueindex $scheme $p.Sub $p.Set $p.V | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "powercfg refused to change '$($p.Label)'" }
    }
    & powercfg.exe /setactive $scheme | Out-Null
}

function Restore-PowerTweak($t, $Data) {
    if ($null -eq $Data.schemes) { return }
    $all = Get-SchemeGuids
    foreach ($g in @($Data.schemes.Keys)) {
        if ($all -notcontains $g) { continue }
        foreach ($e in @($Data.schemes[$g])) { & powercfg.exe /setacvalueindex $g $e.Sub $e.Set $e.AC | Out-Null }
    }
    & powercfg.exe /setactive SCHEME_CURRENT | Out-Null
}

# ------------------------------------------------------------------ USB device power
function Get-UsbPowerDevices {
    @(Get-WmiObject -Namespace 'root\wmi' -Class 'MSPower_DeviceEnable' | Where-Object { $_.InstanceName -match '^(USB|HID)\\' })
}

# ------------------------------------------------------------------ DirectX global settings
$DxPath = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'
$DxName = 'DirectXUserGlobalSettings'

# The value is a "key=value;key=value;" string shared with other Graphics settings, so merge.
function Set-DxGlobalSetting([string]$Key, [string]$Value) {
    $cur = Read-RegValue $DxPath $DxName
    $pairs = [ordered]@{}
    if ($cur.Exists -and $cur.V) {
        foreach ($part in ([string]$cur.V -split ';')) {
            if ($part -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$') { $pairs[$matches[1]] = $matches[2] }
        }
    }
    $pairs[$Key] = $Value
    $str = (@($pairs.Keys | ForEach-Object { "$_=$($pairs[$_])" }) -join ';') + ';'
    Write-RegValue $DxPath $DxName 'String' $str
}

# ------------------------------------------------------------------ tweaks
$Tweaks = @(
    @{
        Id = 'PowerPlan'; Cat = 'Power and CPU'; Impact = 'High'; Rec = $true; When = 'instant'
        Name = 'Ultimate Performance power plan'
        Desc = "Switches to Windows' hidden Ultimate Performance plan (or High performance if that is blocked), so the CPU and devices stop dropping into power-saving states between your inputs. Your current plan comes back when you revert."
        Test = {
            $a = (Get-ActiveScheme).Guid
            $b = $script:Backup.tweaks['PowerPlan']
            $created = if ($b -and $b.data) { $b.data.created } else { $null }
            if ($a -eq $UltimateGuid -or $a -eq $HighGuid -or ($created -and $a -eq $created)) { 'Applied' }
            elseif ($a -eq $BalancedGuid -or $a -eq $SaverGuid) { 'Default' }
            else { 'Custom' }   # a third-party / OEM plan: may already be tuned, so never auto-selected
        }
        Apply = {
            param($t, $d)
            if (-not $d.prev) { $d.prev = (Get-ActiveScheme).Guid }
            $schemes = Get-SchemeGuids
            $target = $null
            if ($d.created -and ($schemes -contains $d.created)) { $target = $d.created }
            if (-not $target) {
                $out = (& powercfg.exe /duplicatescheme $UltimateGuid) -join ' '
                $g = [regex]::Match($out, $GuidRx).Value.ToLower()
                if ($LASTEXITCODE -eq 0 -and $g) {
                    & powercfg.exe /changename $g 'Ultimate Performance (Latency Optimizer)' | Out-Null
                    $d.created = $g; $target = $g
                }
            }
            if (-not $target -and ($schemes -contains $HighGuid)) { $target = $HighGuid }
            if (-not $target) {
                $out = (& powercfg.exe /duplicatescheme $HighGuid) -join ' '
                $g = [regex]::Match($out, $GuidRx).Value.ToLower()
                if ($LASTEXITCODE -eq 0 -and $g) {
                    & powercfg.exe /changename $g 'High Performance (Latency Optimizer)' | Out-Null
                    $d.created = $g; $target = $g
                }
            }
            $blocked = 'Windows only allows the Balanced plan on this PC (common on Modern Standby laptops). Use Settings > System > Power > Power mode: Best performance instead.'
            if (-not $target) { throw $blocked }
            & powercfg.exe /setactive $target | Out-Null
            if ((Get-ActiveScheme).Guid -ne $target) {
                if ($d.created -eq $target) { & powercfg.exe /delete $target | Out-Null; $d.created = $null }
                throw $blocked
            }
        }
        Revert = {
            param($t, $d)
            $schemes = Get-SchemeGuids
            $back = if ($d.prev -and ($schemes -contains $d.prev)) { $d.prev } else { $BalancedGuid }
            & powercfg.exe /setactive $back | Out-Null
            if ($d.created -and ($schemes -contains $d.created) -and (Get-ActiveScheme).Guid -ne $d.created) {
                & powercfg.exe /delete $d.created | Out-Null
            }
        }
    }
    @{
        Id = 'DevicePower'; Cat = 'Power and CPU'; Impact = 'Medium'; Rec = $true; When = 'instant'
        Name = 'No USB / PCIe power saving'
        Desc = 'Turns off USB selective suspend and PCI Express link-state power management in the active plan (plugged in), so your mouse, keyboard and graphics card never have to wake up before they respond.'
        Power = @(
            @{ Sub = $SubUsb;  Set = $SetUsbSuspend; V = 0; Label = 'USB selective suspend' }
            @{ Sub = $SubPcie; Set = $SetPcieAspm;   V = 0; Label = 'PCIe link state power management' }
        )
    }
    @{
        Id = 'CpuPower'; Cat = 'Power and CPU'; Impact = 'Medium'; Rec = $true; When = 'instant'
        Name = 'CPU always ready'
        Desc = 'Minimum processor state 100%, energy preference at maximum performance and no core parking (plugged in), so the CPU does not have to ramp up when input arrives. More heat and power draw - ideal for desktops.'
        Power = @(
            @{ Sub = $SubCpu; Set = $SetCpuMin;  V = 100; Label = 'Minimum processor state' }
            @{ Sub = $SubCpu; Set = $SetCpuEpp;  V = 0;   Label = 'Energy performance preference' }
            @{ Sub = $SubCpu; Set = $SetCpuPark; V = 100; Label = 'Core parking minimum cores' }
        )
    }
    @{
        Id = 'UsbIdle'; Cat = 'Power and CPU'; Impact = 'Medium'; Rec = $true; When = 'instant'
        Name = 'Keep USB and input devices awake'
        Desc = "Unticks 'Allow the computer to turn off this device to save power' on every USB hub and HID device (mouse, keyboard, controller) - the Device Manager setting guides tell you to click through by hand."
        Test = {
            $d = @(Get-UsbPowerDevices)
            if ($d.Count -eq 0) { return 'NA' }
            $on = @($d | Where-Object { $_.Enable }).Count
            if ($on -eq 0) { 'Applied' } elseif ($on -lt $d.Count) { 'Partial' } else { 'Default' }
        }
        Apply = {
            param($t, $d)
            if ($null -eq $d.enabled) { $d.enabled = @() }
            $fail = 0
            foreach ($dev in @(Get-UsbPowerDevices | Where-Object { $_.Enable })) {
                if (@($d.enabled) -notcontains $dev.InstanceName) { $d.enabled = @($d.enabled) + $dev.InstanceName }
                try { $dev.Enable = $false; [void]$dev.Put() } catch { $fail++ }
            }
            if ($fail) { Write-Log "  $fail device(s) refused the change (normal for some built-in devices)." }
        }
        Revert = {
            param($t, $d)
            $names = @($d.enabled)
            foreach ($dev in @(Get-UsbPowerDevices)) {
                if ($names -contains $dev.InstanceName -and -not $dev.Enable) {
                    try { $dev.Enable = $true; [void]$dev.Put() } catch {}
                }
            }
        }
    }
    @{
        Id = 'MouseAccel'; Cat = 'Mouse and keyboard'; Impact = 'High'; Rec = $true; When = 'instant'
        Name = 'Turn off mouse acceleration'
        Desc = "Disables 'Enhance pointer precision' so the cursor moves exactly as far as your hand does. Raw-input games already bypass it; this fixes the desktop, menus and games that use the Windows cursor."
        Reg = @(
            RegValue 'HKCU\Control Panel\Mouse' 'MouseSpeed' 'String' '0'
            RegValue 'HKCU\Control Panel\Mouse' 'MouseThreshold1' 'String' '0'
            RegValue 'HKCU\Control Panel\Mouse' 'MouseThreshold2' 'String' '0'
        )
        Live = {
            $p = 'HKCU\Control Panel\Mouse'
            $a = [int[]]@([int](Get-RegString $p 'MouseThreshold1' '6'), [int](Get-RegString $p 'MouseThreshold2' '10'), [int](Get-RegString $p 'MouseSpeed' '1'))
            [void][ILO.Native]::SystemParametersInfo($SPI_SETMOUSE, 0, $a, $SPIF_SENDCHANGE)
        }
    }
    @{
        Id = 'AccessKeys'; Cat = 'Mouse and keyboard'; Impact = 'Low'; Rec = $true; When = 'signout'
        Name = 'No Sticky / Filter Keys'
        Desc = 'Disables the Sticky, Filter and Toggle Keys shortcuts (no pop-up when you tap Shift five times mid-game) and makes sure Filter Keys, which deliberately delays and filters keystrokes, stays off.'
        Reg = @(
            RegValue 'HKCU\Control Panel\Accessibility\StickyKeys' 'Flags' 'String' '506'
            RegValue 'HKCU\Control Panel\Accessibility\ToggleKeys' 'Flags' 'String' '58'
            RegValue 'HKCU\Control Panel\Accessibility\Keyboard Response' 'Flags' 'String' '122'
        )
    }
    @{
        Id = 'KeyRepeat'; Cat = 'Mouse and keyboard'; Impact = 'Low'; Rec = $false; When = 'instant'
        Name = 'Fastest key repeat'
        Desc = 'Shortest delay before a held key starts repeating and the fastest repeat rate. Snappier when holding keys in menus or text - purely a preference.'
        Reg = @(
            RegValue 'HKCU\Control Panel\Keyboard' 'KeyboardDelay' 'String' '0'
            RegValue 'HKCU\Control Panel\Keyboard' 'KeyboardSpeed' 'String' '31'
        )
        Live = {
            $delay = [uint32](Get-RegString 'HKCU\Control Panel\Keyboard' 'KeyboardDelay' '1')
            $speed = [uint32](Get-RegString 'HKCU\Control Panel\Keyboard' 'KeyboardSpeed' '31')
            [void][ILO.Native]::SystemParametersInfoNull($SPI_SETKEYBOARDDELAY, $delay, [IntPtr]::Zero, $SPIF_SENDCHANGE)
            [void][ILO.Native]::SystemParametersInfoNull($SPI_SETKEYBOARDSPEED, $speed, [IntPtr]::Zero, $SPIF_SENDCHANGE)
        }
    }
    @{
        Id = 'WindowedOpt'; Cat = 'Games and graphics'; Impact = 'High'; Rec = $true; When = 'game'; MinBuild = 22000
        Name = 'Optimizations for windowed games'
        Desc = 'Upgrades DirectX 10/11 games running windowed or borderless to the flip presentation model, giving them fullscreen-like latency and VRR support. Your other graphics settings are kept.'
        Test = {
            $cur = Read-RegValue $DxPath $DxName
            if ($cur.Exists -and ([string]$cur.V -match '(^|;)\s*SwapEffectUpgradeEnable\s*=\s*1\s*(;|$)')) { 'Applied' } else { 'Default' }
        }
        Apply = {
            param($t, $d)
            Save-RegValueState $d $DxPath $DxName
            Set-DxGlobalSetting 'SwapEffectUpgradeEnable' '1'
        }
    }
    @{
        Id = 'GameDVR'; Cat = 'Games and graphics'; Impact = 'Medium'; Rec = $true; When = 'game'
        Name = 'No background game recording'
        Desc = 'Turns off Xbox Game Bar capture and background recording, which keep a video encoder hooked into your game the whole time.'
        Reg = @(
            RegValue 'HKCU\System\GameConfigStore' 'GameDVR_Enabled' 'DWord' 0
            RegValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 'DWord' 0
            RegValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 'DWord' 0
        )
    }
    @{
        Id = 'GameMode'; Cat = 'Games and graphics'; Impact = 'Medium'; Rec = $true; When = 'instant'
        Name = 'Game Mode on'
        Desc = 'Makes sure Game Mode is enabled: Windows gives the game priority and holds back Windows Update driver installs and restart prompts while you play.'
        Reg = @(
            RegValue 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 'DWord' 1
            RegValue 'HKCU\Software\Microsoft\GameBar' 'AllowAutoGameMode' 'DWord' 1
        )
        Test = {
            $v = Read-RegValue 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
            if (-not $v.Exists -or [int]$v.V -eq 1) { 'Applied' } else { 'Default' }   # missing = Windows default (on)
        }
    }
    @{
        Id = 'Hags'; Cat = 'Games and graphics'; Impact = 'Varies'; Rec = $false; When = 'reboot'; MinBuild = 19041
        Name = 'Hardware-accelerated GPU scheduling'
        Desc = 'Lets the graphics card manage its own work queue. Needed for DLSS Frame Generation; the latency effect differs per system, so try it both ways. Only works on GPUs and drivers that support it.'
        Reg = @( RegValue 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 'DWord' 2 )
    }
    @{
        Id = 'Mmcss'; Cat = 'Games and graphics'; Impact = 'Low'; Rec = $true; When = 'reboot'
        Name = 'Game scheduling priority (MMCSS)'
        Desc = "Tunes the Multimedia Class Scheduler: background tasks get a smaller guaranteed CPU share and the 'Games' task gets higher CPU and I/O priority. Only affects games that register with MMCSS."
        Reg = @(
            RegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 'DWord' 10
            RegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority' 'DWord' 8
            RegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority' 'DWord' 6
            RegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category' 'String' 'High'
            RegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority' 'String' 'High'
        )
    }
    @{
        Id = 'UiSnappy'; Cat = 'Desktop'; Impact = 'Low'; Rec = $true; When = 'instant'
        Name = 'Instant menus and windows'
        Desc = 'Removes the 400 ms delay before menus open and the minimize/maximize animations. The desktop feels instant; no effect inside games.'
        Reg = @(
            RegValue 'HKCU\Control Panel\Desktop' 'MenuShowDelay' 'String' '0'
            RegValue 'HKCU\Control Panel\Desktop\WindowMetrics' 'MinAnimate' 'String' '0'
        )
        Live = {
            $delay = [uint32](Get-RegString 'HKCU\Control Panel\Desktop' 'MenuShowDelay' '400')
            [void][ILO.Native]::SystemParametersInfoNull($SPI_SETMENUSHOWDELAY, $delay, [IntPtr]::Zero, $SPIF_SENDCHANGE)
            $min = [int](Get-RegString 'HKCU\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '1')
            [void][ILO.Native]::SystemParametersInfo($SPI_SETANIMATION, 8, [int[]]@(8, $min), $SPIF_SENDCHANGE)
        }
    }
    @{
        Id = 'NetThrottle'; Cat = 'Network'; Impact = 'Low'; Rec = $true; When = 'reboot'
        Name = 'No multimedia network throttling'
        Desc = 'Stops Windows from throttling network packet processing while audio or video apps run in the background (Discord, a stream, music).'
        Reg = @( RegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' 'DWord' 4294967295 )
    }
    @{
        Id = 'Nagle'; Cat = 'Network'; Impact = 'Low'; Rec = $false; When = 'reboot'
        Name = "Disable Nagle's algorithm"
        Desc = 'Sends small TCP packets immediately instead of bundling them, on every connected network adapter. Only helps games that use TCP (mostly older MMOs); most shooters use UDP and are unaffected.'
        Reg = {
            $base = 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
            $k = Open-RegKey $base
            if ($null -eq $k) { return }
            try {
                foreach ($g in $k.GetSubKeyNames()) {
                    $p = "$base\$g"
                    $dhcp = [string](Read-RegValue $p 'DhcpIPAddress').V
                    $static = @(@((Read-RegValue $p 'IPAddress').V) | Where-Object { $_ -and $_ -ne '0.0.0.0' })
                    if (($dhcp -and $dhcp -ne '0.0.0.0') -or $static.Count) {
                        RegValue $p 'TcpAckFrequency' 'DWord' 1
                        RegValue $p 'TCPNoDelay' 'DWord' 1
                    }
                }
            } finally { $k.Close() }
        }
    }
    @{
        Id = 'GlobalTimer'; Cat = 'Experimental'; Impact = 'Experimental'; Rec = $false; When = 'reboot'; MinBuild = 22000
        Name = 'Global timer resolution requests'
        Desc = "Windows 11 only. Lets a high timer-resolution request (like 'Hold finest timer resolution' in Live tools) apply system-wide again, as before Windows 10 2004. Can tighten frame pacing in games that sleep between frames; costs a little power. Evidence is mixed."
        Reg = @( RegValue 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 'DWord' 1 )
    }
)

$ImpactStyle = @{
    'High'         = @('HIGH IMPACT',   '#10301F', '#3DDC84')
    'Medium'       = @('MEDIUM IMPACT', '#132840', '#6AA9FF')
    'Low'          = @('LOW IMPACT',    '#1D2129', '#9AA3B5')
    'Varies'       = @('VARIES',        '#33260F', '#F2B33D')
    'Experimental' = @('EXPERIMENTAL',  '#33260F', '#F2B33D')
}
$StateStyle = @{
    'Applied' = @('ACTIVE',     '#10301F', '#3DDC84')
    'Default' = @('NOT ACTIVE', '#1D2129', '#9AA3B5')
    'Partial' = @('PARTIAL',    '#33260F', '#F2B33D')
    'Custom'  = @('CUSTOM PLAN', '#33260F', '#F2B33D')
    'NA'      = @('N/A',        '#15181F', '#5D6575')
    'Error'   = @('ERROR',      '#3A1717', '#F06565')
}
$WhenText = @{
    instant = 'Takes effect instantly'
    game    = 'Restart the game to take effect'
    signout = 'Takes effect after you sign out'
    reboot  = 'Takes effect after a reboot'
}

$IfeoPath     = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
$ProtectedExe = @('system.exe', 'smss.exe', 'csrss.exe', 'wininit.exe', 'winlogon.exe', 'lsass.exe', 'services.exe',
                  'svchost.exe', 'dwm.exe', 'audiodg.exe', 'explorer.exe', 'fontdrvhost.exe', 'conhost.exe', 'ntoskrnl.exe')

$Overlays = [ordered]@{
    'Discord' = 'Discord'; 'obs64' = 'OBS Studio'; 'RTSS' = 'RivaTuner'; 'MSIAfterburner' = 'MSI Afterburner'
    'iCUE' = 'Corsair iCUE'; 'lghub' = 'Logitech G HUB'; 'RazerAppEngine' = 'Razer Synapse'; 'SteelSeriesGG' = 'SteelSeries GG'
    'ArmouryCrate' = 'Armoury Crate'; 'NVIDIA Overlay' = 'NVIDIA overlay'; 'NVIDIA Share' = 'GeForce overlay'
    'GameBar' = 'Xbox Game Bar'; 'wallpaper32' = 'Wallpaper Engine'; 'wallpaper64' = 'Wallpaper Engine'
    'Overwolf' = 'Overwolf'; 'Medal' = 'Medal.tv'; 'SignalRgb' = 'SignalRGB'; 'OpenRGB' = 'OpenRGB'; 'NZXT CAM' = 'NZXT CAM'
}

$Tips = @(
    @{ Title = 'Biggest wins (outside Windows settings)'; Items = @(
        'Run your monitor at its highest refresh rate: Settings > System > Display > Advanced display. Going from 60 Hz to 144 Hz cuts more latency than every tweak in this app combined.'
        'Turn on NVIDIA Reflex, AMD Anti-Lag 2 or Intel XeLL in every game that has it. For games without it, set Low Latency Mode = On (NVIDIA Control Panel) or Anti-Lag (AMD Adrenalin).'
        'With G-Sync / FreeSync: V-Sync on in the driver, off in the game, and cap FPS 3-4 below your refresh rate (Reflex does the cap for you).'
        'Without G-Sync / FreeSync: keep V-Sync off. A stable FPS cap your PC always hits feels better than a fluctuating uncapped frame rate.'
        'If the GPU sits at 99% usage, latency goes up. Lower settings or cap FPS so it has a little headroom (Reflex / Anti-Lag also fix this).'
    ) }
    @{ Title = 'Mouse and keyboard'; Items = @(
        'Set mouse polling to 1000 Hz or more in its software. If a game stutters at 4000-8000 Hz, go back to 1000-2000 Hz.'
        'Plug the mouse and keyboard straight into the rear motherboard USB ports - not hubs, monitor ports or the front panel.'
        'Wireless 2.4 GHz dongles are as fast as a cable today; Bluetooth is not. Put the dongle close to the mouse with the extension cable.'
        'Most gaming mice store DPI and polling on-board, so after setting them you can usually close the vendor app while playing.'
    ) }
    @{ Title = 'System'; Items = @(
        'Keep GPU and chipset drivers up to date.'
        'Enable XMP / EXPO in the BIOS so your RAM runs at its rated speed.'
        'Still getting random hitches? Run LatencyMon (free) to find drivers with high DPC/ISR latency - often Wi-Fi, Bluetooth, audio or RGB software.'
        'Close overlays and recorders you do not use. The Diagnostics tab lists the common ones it finds running.'
    ) }
)

# ------------------------------------------------------------------ backup store
$script:Backup     = @{ version = 1; tweaks = @{}; priority = @{} }
$script:LastState  = @{}
$script:TestErrors = @{}
$script:LogBox     = $null

function ConvertTo-PlainObject($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-PlainObject $p.Value }
        return $h
    }
    if ($o -is [System.Collections.IList]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in $o) { [void]$list.Add((ConvertTo-PlainObject $i)) }
        return , $list.ToArray()
    }
    return $o
}

function Import-Backup {
    if (-not (Test-Path $BackupFile)) { return }
    try {
        $o = ConvertTo-PlainObject (Get-Content -Path $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        if ($o -isnot [hashtable]) { throw 'unexpected format' }
        if ($null -eq $o.tweaks)   { $o.tweaks = @{} }
        if ($null -eq $o.priority) { $o.priority = @{} }
        $script:Backup = $o
    } catch {
        Write-Log "Backup file could not be read ($($_.Exception.Message)). It was left untouched."
        if (-not $ReadOnly) { Copy-Item $BackupFile "$BackupFile.unreadable" -Force -ErrorAction SilentlyContinue }
    }
}

function Save-Backup {
    if (-not (Test-Path $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir -Force) }
    $script:Backup.updated = (Get-Date).ToString('s')
    $script:Backup | ConvertTo-Json -Depth 12 | Set-Content -Path $BackupFile -Encoding UTF8
}

function Write-Log([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
        $script:LogBox.ScrollToEnd()
    } else { Write-Host $line }
    if (-not $ReadOnly) {
        try {
            if (-not (Test-Path $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir -Force) }
            Add-Content -Path $LogFile -Value ('{0}  {1}' -f (Get-Date -Format 's'), $Message) -Encoding UTF8
        } catch {}
    }
}

# ------------------------------------------------------------------ tweak engine
function Get-TweakValues($t) {
    if ($t.Reg -is [scriptblock]) { return @(& $t.Reg) }
    return @($t.Reg)
}

function Test-Tweak($t) {
    try {
        if ($t.MinBuild -and $script:Build -lt $t.MinBuild) { return 'NA' }
        if ($t.Test)  { return [string](@(& $t.Test $t)[-1]) }
        if ($t.Power) { return [string](Test-PowerTweak $t) }
        $vals = @(Get-TweakValues $t)
        if ($vals.Count -eq 0) { return 'NA' }
        $hit = @($vals | Where-Object { Test-RegMatch $_ }).Count
        if ($hit -eq $vals.Count) { 'Applied' } elseif ($hit -gt 0) { 'Partial' } else { 'Default' }
    } catch {
        $script:TestErrors[$t.Id] = $_.Exception.Message
        'Error'
    }
}

function Invoke-TweakPart($t, [string]$Part, $Data) {
    if ($t.ContainsKey($Part)) { [void](& $t[$Part] $t $Data); return }
    if ($Part -eq 'Apply') {
        if ($t.Power) { Set-PowerTweak $t $Data }
        else {
            foreach ($s in @(Get-TweakValues $t)) {
                Save-RegValueState $Data $s.P $s.N
                Write-RegValue $s.P $s.N $s.K $s.V
            }
        }
    } else {
        if ($t.Power) { Restore-PowerTweak $t $Data }
        else {
            foreach ($e in @($Data.reg)) {
                if ($e.Exists) { Write-RegValue $e.P $e.N $e.K $e.V } else { Remove-RegValue $e.P $e.N }
            }
        }
    }
    if ($t.Live) {
        try { [void](& $t.Live) } catch { Write-Log "  (could not refresh live: $($_.Exception.Message))" }
    }
}

function Invoke-TweakApply($t) {
    $state = Test-Tweak $t
    if ($state -eq 'Applied') { Write-Log "$($t.Name): already active"; return $false }
    if ($state -eq 'NA') { Write-Log "$($t.Name): not available on this PC - skipped"; return $false }
    $entry = $script:Backup.tweaks[$t.Id]
    if ($null -eq $entry) { $entry = @{ time = (Get-Date).ToString('s'); data = @{} } }
    if ($null -eq $entry.data) { $entry.data = @{} }
    try {
        Invoke-TweakPart $t 'Apply' $entry.data
    } finally {
        # saved even if the apply failed half-way, so whatever did change can be reverted
        $script:Backup.tweaks[$t.Id] = $entry
        Save-Backup
    }
    $after = Test-Tweak $t
    if ($after -eq 'Applied') { Write-Log "$($t.Name): applied" }
    else { Write-Log "$($t.Name): done, status now '$($StateStyle[$after][0])'" }
    return $true
}

function Invoke-TweakRevert($t) {
    $entry = $script:Backup.tweaks[$t.Id]
    if ($null -eq $entry) {
        Write-Log "$($t.Name): nothing to revert (no backup - this app did not change it)"
        return $false
    }
    Invoke-TweakPart $t 'Revert' $entry.data
    $script:Backup.tweaks.Remove($t.Id)
    Save-Backup
    Write-Log "$($t.Name): reverted to how it was"
    return $true
}

# ------------------------------------------------------------------ game CPU priority (IFEO)
function Get-PriorityName([int]$Class) {
    switch ($Class) { 1 { 'Idle' } 2 { 'Normal' } 3 { 'High' } 4 { 'Realtime' } 5 { 'Below normal' } 6 { 'Above normal' } default { "Class $Class" } }
}

function Get-PriorityEntries {
    $k = Open-RegKey $IfeoPath
    if ($null -eq $k) { return }
    try {
        foreach ($exe in $k.GetSubKeyNames()) {
            try {
                $v = Read-RegValue "$IfeoPath\$exe\PerfOptions" 'CpuPriorityClass'
                if ($v.Exists) { @{ Exe = $exe; Class = [int]$v.V } }
            } catch {}
        }
    } finally { $k.Close() }
}

function Add-PriorityEntry([string]$Exe, [int]$Class) {
    $Exe = [IO.Path]::GetFileName($Exe.Trim().Trim('"'))
    if (-not $Exe) { throw 'Type the game''s program file name first, for example cs2.exe.' }
    if ($Exe -notmatch '\.exe$') { $Exe += '.exe' }
    if ($Exe -notmatch '^[\w\-\. ()+&]+\.exe$') { throw "'$Exe' does not look like a program file name." }
    if ($ProtectedExe -contains $Exe.ToLower()) { throw "$Exe is part of Windows - leave its priority alone." }
    $key = "$IfeoPath\$Exe"
    if (-not $script:Backup.priority.ContainsKey($Exe)) {
        $script:Backup.priority[$Exe] = @{ old = (Read-RegValue "$key\PerfOptions" 'CpuPriorityClass') }
    }
    Write-RegValue "$key\PerfOptions" 'CpuPriorityClass' 'DWord' $Class
    Save-Backup
    Write-Log ('{0} will start at {1} priority from its next launch.' -f $Exe, (Get-PriorityName $Class))
}

function Remove-PriorityEntry([string]$Exe) {
    $key = "$IfeoPath\$Exe"
    Remove-RegValue "$key\PerfOptions" 'CpuPriorityClass'
    Remove-EmptyKey "$key\PerfOptions"
    Remove-EmptyKey $key
    if ($script:Backup.priority.ContainsKey($Exe)) { $script:Backup.priority.Remove($Exe); Save-Backup }
    Write-Log "$Exe will start at normal priority again."
}

function Restore-PriorityBackup([string]$Exe) {
    $b = $script:Backup.priority[$Exe]
    $key = "$IfeoPath\$Exe"
    if ($b -and $b.old -and $b.old.Exists) {
        Write-RegValue "$key\PerfOptions" 'CpuPriorityClass' $b.old.K $b.old.V
    } else {
        Remove-RegValue "$key\PerfOptions" 'CpuPriorityClass'
        Remove-EmptyKey "$key\PerfOptions"
        Remove-EmptyKey $key
    }
    $script:Backup.priority.Remove($Exe)
    Save-Backup
    Write-Log "$Exe priority restored"
}

# ------------------------------------------------------------------ timer resolution
function Get-TimerResolution {
    $a = [uint32]0; $b = [uint32]0; $c = [uint32]0
    [void][ILO.Native]::NtQueryTimerResolution([ref]$a, [ref]$b, [ref]$c)
    $fine = [Math]::Min($a, $b); $coarse = [Math]::Max($a, $b)
    @{ Finest = $fine / 10000.0; Coarsest = $coarse / 10000.0; Current = $c / 10000.0; FinestRaw = $fine }
}

function Set-TimerHold([bool]$On) {
    $res = Get-TimerResolution
    $cur = [uint32]0
    if ($On) { [void][ILO.Native]::HonorTimerResolutionWhenHidden() }
    $rc = [ILO.Native]::NtSetTimerResolution([uint32]$res.FinestRaw, $On, [ref]$cur)
    if ($rc -ne 0) { throw ('NtSetTimerResolution failed (0x{0:X8})' -f $rc) }
    return ($cur / 10000.0)
}

# ------------------------------------------------------------------ diagnostics (read only)
function Get-Diagnostics {
    $list = New-Object System.Collections.ArrayList
    function Add-Diag([string]$Title, [string]$Value, [string]$Level = 'info', [string]$Note = '') {
        [void]$list.Add(@{ Title = $Title; Value = $Value; Level = $Level; Note = $Note })
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $dv = (Read-RegValue 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion').V
        Add-Diag 'Windows' ('{0} {1}  (build {2})' -f ($os.Caption -replace '^Microsoft\s+', ''), $dv, $script:Build)
    } catch {}

    try {
        $cpu = @(Get-CimInstance Win32_Processor)[0]
        Add-Diag 'Processor' (($cpu.Name -replace '\s+', ' ').Trim())
    } catch {}

    try {
        foreach ($g in @(Get-CimInstance Win32_VideoController)) {
            $hz = [int]$g.CurrentRefreshRate
            $val = $g.Name
            if ($g.CurrentHorizontalResolution) { $val += '   |   {0} x {1} @ {2} Hz' -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution, $hz }
            if ($g.DriverVersion) { $val += "   |   driver $($g.DriverVersion)" }
            if ($hz -gt 0 -and $hz -le 60) {
                Add-Diag 'Graphics / display' $val 'warn' 'Running at 60 Hz or less. If your monitor supports more, set it in Settings > System > Display > Advanced display - the single biggest latency win there is.'
            } else { Add-Diag 'Graphics / display' $val 'ok' }
        }
    } catch {}

    try {
        $a = Get-ActiveScheme
        $b = $script:Backup.tweaks['PowerPlan']
        $created = if ($b -and $b.data) { $b.data.created } else { $null }
        if ($a.Guid -eq $UltimateGuid -or $a.Guid -eq $HighGuid -or ($created -and $a.Guid -eq $created)) {
            Add-Diag 'Power plan' $a.Name 'ok'
        } elseif ($a.Guid -ne $BalancedGuid -and $a.Guid -ne $SaverGuid) {
            Add-Diag 'Power plan' $a.Name 'info' 'A custom plan. Fine to keep if it is a performance plan - the power and CPU tweaks apply to whichever plan is active.'
        } else {
            Add-Diag 'Power plan' $a.Name 'warn' 'Not a performance plan. See Tweaks > Ultimate Performance power plan.'
        }
    } catch {}

    try {
        $r = Get-TimerResolution
        Add-Diag 'Timer resolution' ('{0:0.###} ms right now  (finest possible {1:0.###} ms)' -f $r.Current, $r.Finest) 'info' 'Games normally raise this themselves while they run. See Live tools.'
    } catch {}

    try {
        $h = Read-RegValue 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
        $hv = if (-not $h.Exists) { 'Not set (Windows default for your GPU)' } elseif ([int]$h.V -eq 2) { 'On' } else { 'Off' }
        Add-Diag 'Hardware-accelerated GPU scheduling' $hv
    } catch {}

    try {
        $mi = Read-RegValue 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
        if ($mi.Exists -and [int]$mi.V -eq 1) {
            Add-Diag 'Memory integrity (Core isolation)' 'On' 'info' 'A security feature, so this app leaves it alone. Microsoft says it can cost some gaming performance; if you decide to turn it off, it is in Windows Security > Device security > Core isolation.'
        } else { Add-Diag 'Memory integrity (Core isolation)' 'Off' }
    } catch {}

    if (Test-Admin) {
        try {
            $line = @(& bcdedit.exe /enum '{current}') | Where-Object { $_ -match '^\s*useplatformclock\s' } | Select-Object -First 1
            if ($line -and $line -notmatch '\sNo\s*$') {
                Add-Diag 'HPET (useplatformclock)' $line.Trim() 'warn' 'Forcing the HPET timer usually adds overhead and latency. To go back to the Windows default, run this in an admin terminal:  bcdedit /deletevalue useplatformclock'
            } else { Add-Diag 'HPET (useplatformclock)' 'Not forced (Windows default)' 'ok' }
        } catch {}
    }

    try {
        $names = @(Get-Process | ForEach-Object { $_.ProcessName })
        $found = @($Overlays.Keys | Where-Object { $names -contains $_ } | ForEach-Object { $Overlays[$_] } | Select-Object -Unique)
        if ($found.Count) {
            Add-Diag 'Overlays / RGB / peripheral apps running' ($found -join ', ') 'warn' 'These hook into games or poll USB devices and can add overhead or stutter. Close the ones you do not need while gaming.'
        } else { Add-Diag 'Overlays / RGB / peripheral apps running' 'None of the common ones' 'ok' }
    } catch {}

    try {
        $sys = @(Get-PriorityEntries | Where-Object { $ProtectedExe -contains $_.Exe.ToLower() -or $_.Exe -match '^(SearchIndexer|TrustedInstaller|MsMpEng)\.exe$' })
        if ($sys.Count) {
            $txt = ($sys | ForEach-Object { '{0} {1}' -f $_.Exe, (Get-PriorityName $_.Class) }) -join ', '
            Add-Diag 'Fixed CPU priorities on Windows processes' $txt 'warn' 'Another tweak tool forced these. Idle or Below normal on svchost.exe / audiodg.exe can cause audio crackle or hitches under load, and Windows already manages these processes well. You can remove any of them in Live tools > Game CPU priority.'
        }
    } catch {}

    $n = $script:Backup.tweaks.Count + $script:Backup.priority.Count
    Add-Diag 'Backups' ('{0} saved   |   {1}' -f $n, $BackupFile)
    $list
}

# ------------------------------------------------------------------ status mode
Import-Backup

if ($Status) {
    "$AppName $AppVersion - status (read only)"
    ''
    foreach ($t in $Tweaks) {
        $s = Test-Tweak $t
        $extra = if ($s -eq 'Error') { '   <- ' + $script:TestErrors[$t.Id] } else { '' }
        '{0,-12} {1,-11} {2}{3}' -f $t.Id, $StateStyle[$s][0], $t.Name, $extra
    }
    exit 0
}

# ------------------------------------------------------------------ window
function Esc([string]$s) { [System.Security.SecurityElement]::Escape($s) }

function Get-MetaText($t, [bool]$HasBackup) {
    $parts = @()
    if ($t.Rec) { $parts += 'Recommended' }
    $parts += $WhenText[$t.When]
    if ($HasBackup) { $parts += 'Backup saved, can be reverted' }
    $parts -join ('   ' + [char]0x00B7 + '   ')
}

function Get-RowXaml($t) {
    $id  = $t.Id
    $imp = $ImpactStyle[$t.Impact]
    $name = Esc $t.Name
    $desc = Esc $t.Desc
    $meta = Esc (Get-MetaText $t $false)
@"
<Border Style="{StaticResource Card}">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <CheckBox x:Name="chk_$id" Style="{StaticResource Chk}">
      <StackPanel>
        <TextBlock Text="$name" FontSize="14" FontWeight="SemiBold" Foreground="{StaticResource Fg}"/>
        <TextBlock Text="$desc" TextWrapping="Wrap" Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
        <TextBlock x:Name="meta_$id" Text="$meta" Foreground="{StaticResource Dim}" FontSize="11.5" Margin="0,6,0,0"/>
      </StackPanel>
    </CheckBox>
    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top" Margin="16,1,0,0">
      <Border Style="{StaticResource Tag}" Background="$($imp[1])" Width="104" Margin="0,0,6,0">
        <TextBlock Text="$($imp[0])" Foreground="$($imp[2])" FontSize="10.5" FontWeight="Bold" HorizontalAlignment="Center"/>
      </Border>
      <Border x:Name="pill_$id" Style="{StaticResource Tag}" Width="96" Background="#1D2129">
        <TextBlock x:Name="st_$id" Text="..." Foreground="#9AA3B5" FontSize="10.5" FontWeight="Bold" HorizontalAlignment="Center"/>
      </Border>
    </StackPanel>
  </Grid>
</Border>
"@
}

function Build-Xaml {
    # (PowerShell variable names are case-insensitive: keep these distinct from $Tips / $Rows)
    $rowXml = New-Object System.Text.StringBuilder
    foreach ($c in @($Tweaks | ForEach-Object { $_.Cat } | Select-Object -Unique)) {
        [void]$rowXml.AppendLine("<TextBlock Text=`"$(Esc $c.ToUpper())`" Style=`"{StaticResource Section}`"/>")
        foreach ($t in @($Tweaks | Where-Object { $_.Cat -eq $c })) { [void]$rowXml.AppendLine((Get-RowXaml $t)) }
    }
    $tipXml = New-Object System.Text.StringBuilder
    foreach ($sec in $Tips) {
        [void]$tipXml.AppendLine("<Border Style=`"{StaticResource Card}`" Padding=`"18,14`"><StackPanel>")
        [void]$tipXml.AppendLine("<TextBlock Text=`"$(Esc $sec.Title)`" Style=`"{StaticResource H2}`" Margin=`"0,0,0,10`"/>")
        foreach ($i in $sec.Items) {
            [void]$tipXml.AppendLine("<DockPanel Margin=`"0,0,0,8`"><Rectangle Width=`"6`" Height=`"6`" Fill=`"{StaticResource Accent}`" Margin=`"0,7,12,0`" VerticalAlignment=`"Top`" DockPanel.Dock=`"Left`"/><TextBlock Text=`"$(Esc $i)`" TextWrapping=`"Wrap`" Foreground=`"#C9CDD6`"/></DockPanel>")
        }
        [void]$tipXml.AppendLine('</StackPanel></Border>')
    }
    $script:XamlTemplate.Replace('__ROWS__', $rowXml.ToString()).Replace('__TIPS__', $tipXml.ToString())
}

$script:XamlTemplate = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Input Latency Optimizer" Width="1100" Height="820" MinWidth="960" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#0D0F13" Foreground="#E6E8ED"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Fg" Color="#E6E8ED"/>
    <SolidColorBrush x:Key="Muted" Color="#8A92A3"/>
    <SolidColorBrush x:Key="Dim" Color="#5D6575"/>
    <SolidColorBrush x:Key="Accent" Color="#3D8BFF"/>
    <SolidColorBrush x:Key="Line" Color="#222733"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#15181F"/>
      <Setter Property="BorderBrush" Value="#222733"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="2"/>
      <Setter Property="Padding" Value="16,12"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Tag" TargetType="Border">
      <Setter Property="Padding" Value="8,4"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A92A3"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="2,14,0,8"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="#E6E8ED"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E6E8ED"/>
      <Setter Property="Background" Value="#1B1F28"/>
      <Setter Property="BorderBrush" Value="#2A303C"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="2" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#5A9BFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#2F7BF5"/>
      <Setter Property="BorderBrush" Value="#2F7BF5"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="Chk" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6E8ED"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="box" Width="20" Height="20" CornerRadius="2" BorderThickness="1.5" BorderBrush="#3A4150"
                      Background="#0D0F13" VerticalAlignment="Top" Margin="0,1,14,0">
                <Path x:Name="tick" Data="M 3.5,9 L 7.5,13 L 14.5,4.5" Stroke="White" StrokeThickness="2.2"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Grid.Column="1" VerticalAlignment="Top"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="#5A9BFF"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="#2F7BF5"/>
                <Setter TargetName="box" Property="BorderBrush" Value="#2F7BF5"/>
                <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="#0A0C10"/>
      <Setter Property="Foreground" Value="#E6E8ED"/>
      <Setter Property="BorderBrush" Value="#2A303C"/>
      <Setter Property="CaretBrush" Value="#E6E8ED"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="#E6E8ED"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="b" Background="Transparent" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1A1F29"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#1C3150"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb"><Border Background="#2E3442" Margin="2,0,2,0"/></ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TabControl">
      <Setter Property="Foreground" Value="#E6E8ED"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <DockPanel>
              <Border DockPanel.Dock="Top" BorderBrush="#222733" BorderThickness="0,0,0,1" Margin="0,0,0,12">
                <TabPanel IsItemsHost="True"/>
              </Border>
              <ContentPresenter ContentSource="SelectedContent" TextElement.Foreground="#E6E8ED"/>
            </DockPanel>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#8A92A3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="b" Padding="14,8" Margin="0,0,4,-1" BorderThickness="0,0,0,2" BorderBrush="Transparent" Background="Transparent" Cursor="Hand">
              <ContentPresenter ContentSource="Header" TextElement.Foreground="{TemplateBinding Foreground}" TextElement.FontWeight="SemiBold"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#3D8BFF"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="24,20,24,0">
      <StackPanel>
        <TextBlock Text="INPUT LATENCY OPTIMIZER" FontSize="20" FontWeight="Bold"/>
        <TextBlock Text="Reversible Windows tweaks for less delay between your hand and the screen." Foreground="{StaticResource Muted}" Margin="0,4,0,0"/>
      </StackPanel>
      <StackPanel HorizontalAlignment="Right" VerticalAlignment="Center">
        <TextBlock x:Name="txtSummary" Text="Checking..." FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Right"/>
        <TextBlock x:Name="txtAdmin" Foreground="{StaticResource Muted}" HorizontalAlignment="Right" Margin="0,3,0,0"/>
      </StackPanel>
    </Grid>

    <TabControl x:Name="tabs" Grid.Row="1" Margin="24,16,24,10">
      <TabItem Header="Tweaks">
        <DockPanel>
          <Border DockPanel.Dock="Bottom" BorderBrush="#222733" BorderThickness="0,1,0,0" Padding="0,12,0,0">
            <DockPanel>
              <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
                <Button x:Name="btnRecommended" Content="Select recommended" Style="{StaticResource Btn}"/>
                <Button x:Name="btnNone" Content="Clear" Style="{StaticResource Btn}"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="btnRestorePoint" Content="Create restore point" Style="{StaticResource Btn}"/>
                <Button x:Name="btnRevert" Content="Revert selected" Style="{StaticResource Btn}"/>
                <Button x:Name="btnRestoreAll" Content="Restore everything" Style="{StaticResource Btn}"/>
                <Button x:Name="btnApply" Content="Apply selected" Style="{StaticResource BtnPrimary}" Margin="0"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Margin="0,0,12,12">
__ROWS__
            </StackPanel>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Live tools">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,12,0">
            <Border Style="{StaticResource Card}" Padding="18,16">
              <StackPanel>
                <TextBlock Text="Timer resolution" Style="{StaticResource H2}"/>
                <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                  <TextBlock x:Name="txtTimer" Text="-" FontFamily="Consolas" FontSize="26" FontWeight="Bold" Foreground="{StaticResource Fg}"/>
                  <TextBlock x:Name="txtTimerSub" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="14,0,0,5"/>
                </StackPanel>
                <TextBlock x:Name="txtTimerNote" TextWrapping="Wrap" Foreground="{StaticResource Muted}" Margin="0,8,0,0"/>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                  <Button x:Name="btnTimer" Content="Hold finest timer resolution" Style="{StaticResource BtnPrimary}"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Padding="18,16">
              <StackPanel>
                <TextBlock Text="Game CPU priority" Style="{StaticResource H2}"/>
                <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Muted}"
                           Text="Windows starts these programs at a higher CPU priority every time they launch. Use the game's .exe name, for example cs2.exe. Above normal is the safe choice; High gives the game more headroom but can make Discord or OBS stutter. Some anti-cheat games reset or ignore it."/>
                <Grid Margin="0,12,0,0">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <TextBox x:Name="txtExe" Style="{StaticResource Input}" Margin="0,0,8,0"/>
                  <Button x:Name="btnBrowse" Grid.Column="1" Content="Browse..." Style="{StaticResource Btn}"/>
                  <Button x:Name="btnPrioAbove" Grid.Column="2" Content="Add as Above normal" Style="{StaticResource Btn}"/>
                  <Button x:Name="btnPrioHigh" Grid.Column="3" Content="Add as High" Style="{StaticResource BtnPrimary}" Margin="0"/>
                </Grid>
                <ListBox x:Name="lstPrio" Height="150" Margin="0,10,0,0" Background="#0A0C10" BorderBrush="{StaticResource Line}"
                         Foreground="{StaticResource Fg}" FontFamily="Consolas" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
                <Button x:Name="btnPrioRemove" Content="Remove selected" Style="{StaticResource Btn}" HorizontalAlignment="Left" Margin="0,10,0,0"/>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </TabItem>

      <TabItem x:Name="tabDiag" Header="Diagnostics">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="btnDiag" Content="Run checks again" Style="{StaticResource Btn}" DockPanel.Dock="Left"/>
            <TextBlock Text="Read-only checks. Nothing on this page changes your PC." Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="6,0,0,0"/>
          </DockPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="pnlDiag" Margin="0,0,12,0"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Tips">
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,12,0">
__TIPS__
          </StackPanel>
        </ScrollViewer>
      </TabItem>
    </TabControl>

    <TextBox x:Name="txtLog" Grid.Row="2" Margin="24,0,24,18" Height="92" IsReadOnly="True" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="12" Background="#0A0C10"
             Foreground="#9AA3B5" BorderBrush="#222733" Padding="8,6"/>
  </Grid>
</Window>
'@

# ------------------------------------------------------------------ UI logic
$script:Brushes = @{}
function Get-Brush([string]$Hex) {
    if (-not $script:Brushes.ContainsKey($Hex)) {
        $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
        $b.Freeze()
        $script:Brushes[$Hex] = $b
    }
    $script:Brushes[$Hex]
}

function Update-Ui {
    $window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Set-Busy([bool]$On) {
    foreach ($n in 'btnApply', 'btnRevert', 'btnRestoreAll', 'btnRestorePoint', 'btnRecommended', 'btnNone', 'btnDiag') { $ui[$n].IsEnabled = -not $On }
    $window.Cursor = if ($On) { [System.Windows.Input.Cursors]::Wait } else { $null }
    Update-Ui
}

function Show-Message([string]$Text, [string]$Icon = 'Information') {
    [void][System.Windows.MessageBox]::Show($window, $Text, $AppName, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]$Icon)
}

function Confirm-Action([string]$Text) {
    $r = [System.Windows.MessageBox]::Show($window, $Text, $AppName, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    return ($r -eq [System.Windows.MessageBoxResult]::Yes)
}

function Invoke-Safe([scriptblock]$Action) {
    try { & $Action }
    catch {
        Write-Log "Error: $($_.Exception.Message)"
        try { Set-Busy $false } catch {}
        Show-Message $_.Exception.Message 'Warning'
    }
}

function Update-AllStatus {
    $active = 0; $avail = 0
    foreach ($t in $Tweaks) {
        $s = Test-Tweak $t
        $script:LastState[$t.Id] = $s
        $st = $StateStyle[$s]
        $r = $script:Rows[$t.Id]
        $r.Status.Text = $st[0]
        $r.Pill.Background = Get-Brush $st[1]
        $r.Status.Foreground = Get-Brush $st[2]
        $r.Pill.ToolTip = switch ($s) {
            'Error'  { $script:TestErrors[$t.Id] }
            'NA'     { 'Not available on this PC or Windows version' }
            'Custom' { "You are using a custom plan ($((Get-ActiveScheme).Name)). Keeping it is fine if it is a performance plan; applying switches to Ultimate Performance." }
            default  { $null }
        }
        $r.Meta.Text = Get-MetaText $t ($script:Backup.tweaks.ContainsKey($t.Id))
        $r.Check.IsEnabled = ($s -ne 'NA')
        if ($s -eq 'NA') { $r.Check.IsChecked = $false } else { $avail++ }
        if ($s -eq 'Applied') { $active++ }
    }
    $ui.txtSummary.Text = "$active / $avail tweaks active"
}

function Get-SelectedTweaks { @($Tweaks | Where-Object { $script:Rows[$_.Id].Check.IsChecked -eq $true }) }

function Select-Recommended {
    $n = 0
    foreach ($t in $Tweaks) {
        $s = $script:LastState[$t.Id]
        $pick = [bool]($t.Rec -and $s -ne 'Applied' -and $s -ne 'NA' -and $s -ne 'Custom')
        $script:Rows[$t.Id].Check.IsChecked = $pick
        if ($pick) { $n++ }
    }
    if ($n) { Write-Log "Selected $n recommended tweak(s) that are not active yet. Press 'Apply selected'." }
    else { Write-Log 'All recommended tweaks are already active.' }
}

function New-RestorePoint {
    Write-Log 'Creating a System Restore point (can take up to a minute)...'
    Update-Ui
    try {
        $w = $null
        Checkpoint-Computer -Description 'Before Input Latency Optimizer' -RestorePointType 'MODIFY_SETTINGS' -WarningVariable w -WarningAction SilentlyContinue
        if ($w) { Write-Log "Restore point: $($w[0])" } else { Write-Log 'Restore point created.' }
    } catch {
        Write-Log "Could not create a restore point: $($_.Exception.Message) (System Protection may be off for drive C:)."
    }
}

function Invoke-ApplySelected {
    $sel = Get-SelectedTweaks
    if ($sel.Count -eq 0) { Show-Message 'Tick the tweaks you want first, or press "Select recommended".'; return }
    if (-not $script:AskedRestorePoint) {
        $r = [System.Windows.MessageBox]::Show($window,
            "Create a System Restore point first?`n`nThis app also backs up every value it changes, so you can undo everything from here either way.",
            $AppName, [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Question)
        if ($r -eq [System.Windows.MessageBoxResult]::Cancel) { return }
        $script:AskedRestorePoint = $true
        if ($r -eq [System.Windows.MessageBoxResult]::Yes) { Set-Busy $true; New-RestorePoint }
    }
    Set-Busy $true
    $when = @{}; $ok = 0
    foreach ($t in $sel) {
        try { if (Invoke-TweakApply $t) { $ok++; $when[$t.When] = $true } }
        catch { Write-Log "$($t.Name): FAILED - $($_.Exception.Message)" }
        Update-Ui
    }
    foreach ($t in $sel) { $script:Rows[$t.Id].Check.IsChecked = $false }
    Update-AllStatus
    Update-TimerNote
    Set-Busy $false
    $msg = "$ok change(s) applied."
    if ($when.reboot) { $msg += ' Some of them need a reboot to take effect.' }
    elseif ($when.signout) { $msg += ' Some of them need a sign-out to take effect.' }
    elseif ($when.game) { $msg += ' Restart your game to pick them up.' }
    Write-Log $msg
}

function Invoke-RevertSelected {
    $sel = Get-SelectedTweaks
    if ($sel.Count -eq 0) { Show-Message 'Tick the tweaks you want to undo first.'; return }
    Set-Busy $true
    $n = 0
    for ($i = $sel.Count - 1; $i -ge 0; $i--) {
        try { if (Invoke-TweakRevert $sel[$i]) { $n++ } }
        catch { Write-Log "$($sel[$i].Name): revert FAILED - $($_.Exception.Message)" }
        Update-Ui
    }
    foreach ($t in $sel) { $script:Rows[$t.Id].Check.IsChecked = $false }
    Update-AllStatus
    Update-TimerNote
    Set-Busy $false
    Write-Log "$n tweak(s) reverted. Changes marked 'after a reboot' or 'after you sign out' need that again to fully undo."
}

function Invoke-RestoreEverything {
    $todo  = @($Tweaks | Where-Object { $script:Backup.tweaks.ContainsKey($_.Id) })
    $exes  = @($script:Backup.priority.Keys)
    if ($todo.Count + $exes.Count -eq 0) { Show-Message 'Nothing to restore - there are no saved backups.'; return }
    if (-not (Confirm-Action "Put back the original value of everything this app changed?`n`n$($todo.Count) tweak(s) and $($exes.Count) program priority setting(s).")) { return }
    Set-Busy $true
    for ($i = $todo.Count - 1; $i -ge 0; $i--) {
        try { [void](Invoke-TweakRevert $todo[$i]) } catch { Write-Log "$($todo[$i].Name): revert FAILED - $($_.Exception.Message)" }
        Update-Ui
    }
    foreach ($e in $exes) {
        try { Restore-PriorityBackup $e } catch { Write-Log "$e priority: restore FAILED - $($_.Exception.Message)" }
    }
    Update-AllStatus
    Update-PriorityList
    Update-TimerNote
    Set-Busy $false
    Write-Log 'Everything restored. Reboot once so settings that load at startup are back too.'
}

function Update-PriorityList {
    $script:PrioEntries = @(Get-PriorityEntries | Sort-Object { $_.Exe })
    $ui.lstPrio.Items.Clear()
    foreach ($e in $script:PrioEntries) {
        $who = if ($script:Backup.priority.ContainsKey($e.Exe)) { '' } else { '    (set by another tool)' }
        [void]$ui.lstPrio.Items.Add(('{0,-34} {1}{2}' -f $e.Exe, (Get-PriorityName $e.Class), $who))
    }
}

function Update-TimerText {
    $r = Get-TimerResolution
    $ui.txtTimer.Text = '{0:0.000} ms' -f $r.Current
    $ui.txtTimerSub.Text = 'current     |     finest {0:0.###} ms     |     Windows default {1:0.###} ms' -f $r.Finest, $r.Coarsest
}

function Update-TimerNote {
    $base = 'Most games already ask for 1 ms on their own; holding the finest resolution mainly helps frame limiters and games that sleep between frames. Uses a little more power and is released when you close this app.'
    if ($script:Build -ge 22000) {
        if ($script:LastState['GlobalTimer'] -eq 'Applied') { $n = 'Global timer requests are switched on (needs a reboot after enabling), so holding it here applies to every program.' }
        else { $n = "On Windows 11 every program gets its own timer resolution. Holding it here only reaches your games after you enable 'Global timer resolution requests' (Tweaks > Experimental) and reboot." }
    } elseif ($script:Build -ge 19041) {
        $n = 'On this Windows 10 version every program gets its own timer resolution and that cannot be made global, so holding it here does not reach your games.'
    } else {
        $n = 'On this Windows version timer resolution is global, so holding it here applies to every program.'
    }
    $ui.txtTimerNote.Text = "$n $base"
}

function Switch-TimerHold {
    if ($script:TimerHeld) {
        [void](Set-TimerHold $false)
        $script:TimerHeld = $false
        $ui.btnTimer.Content = 'Hold finest timer resolution'
        Write-Log 'Timer resolution released.'
    } else {
        $got = Set-TimerHold $true
        $script:TimerHeld = $true
        $ui.btnTimer.Content = 'Release timer resolution'
        Write-Log ('Holding timer resolution at {0:0.###} ms while this app is open.' -f $got)
    }
    Update-TimerText
}

function New-DiagCard($Item) {
    $color = switch ($Item.Level) { 'ok' { '#3DDC84' } 'warn' { '#F2B33D' } 'bad' { '#F06565' } default { '#6AA9FF' } }
    $card = New-Object System.Windows.Controls.Border
    $card.Style = $window.FindResource('Card')
    $dock = New-Object System.Windows.Controls.DockPanel
    $mark = New-Object System.Windows.Shapes.Rectangle
    $mark.Width = 4
    $mark.Fill = Get-Brush $color
    $mark.Margin = [System.Windows.Thickness]::new(0, 0, 14, 0)
    [System.Windows.Controls.DockPanel]::SetDock($mark, [System.Windows.Controls.Dock]::Left)
    [void]$dock.Children.Add($mark)
    $stack = New-Object System.Windows.Controls.StackPanel
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $Item.Title; $t1.FontSize = 11.5; $t1.Foreground = Get-Brush '#8A92A3'
    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text = $Item.Value; $t2.FontSize = 14; $t2.FontWeight = [System.Windows.FontWeights]::SemiBold; $t2.Foreground = Get-Brush '#E6E8ED'
    $t2.TextWrapping = [System.Windows.TextWrapping]::Wrap; $t2.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    [void]$stack.Children.Add($t1)
    [void]$stack.Children.Add($t2)
    if ($Item.Note) {
        $t3 = New-Object System.Windows.Controls.TextBlock
        $t3.Text = $Item.Note; $t3.Foreground = Get-Brush '#8A92A3'
        $t3.TextWrapping = [System.Windows.TextWrapping]::Wrap; $t3.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
        [void]$stack.Children.Add($t3)
    }
    [void]$dock.Children.Add($stack)
    $card.Child = $dock
    return $card
}

function Show-Diagnostics {
    Set-Busy $true
    try {
        $ui.pnlDiag.Children.Clear()
        foreach ($it in @(Get-Diagnostics)) { [void]$ui.pnlDiag.Children.Add((New-DiagCard $it)) }
    } finally { Set-Busy $false }
}

function Initialize-View {
    Set-Busy $true
    try {
        Update-AllStatus
        Update-PriorityList
        Update-TimerText
        Update-TimerNote
    } finally { Set-Busy $false }
    $n = $script:Backup.tweaks.Count + $script:Backup.priority.Count
    Write-Log ('Ready. {0} saved backup(s) in {1}' -f $n, $BackupFile)
}

# ------------------------------------------------------------------ main
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Build-Xaml))))

    $ui = @{}
    foreach ($n in 'txtSummary', 'txtAdmin', 'tabs', 'tabDiag', 'btnApply', 'btnRevert', 'btnRestoreAll', 'btnRestorePoint',
                   'btnRecommended', 'btnNone', 'txtLog', 'pnlDiag', 'btnDiag', 'txtTimer', 'txtTimerSub', 'txtTimerNote',
                   'btnTimer', 'txtExe', 'btnBrowse', 'btnPrioHigh', 'btnPrioAbove', 'lstPrio', 'btnPrioRemove') {
        $ui[$n] = $window.FindName($n)
        if ($null -eq $ui[$n]) { throw "UI element '$n' is missing" }
    }
    $script:Rows = @{}
    foreach ($t in $Tweaks) {
        $script:Rows[$t.Id] = @{
            Check  = $window.FindName("chk_$($t.Id)")
            Pill   = $window.FindName("pill_$($t.Id)")
            Status = $window.FindName("st_$($t.Id)")
            Meta   = $window.FindName("meta_$($t.Id)")
        }
    }
    $script:LogBox = $ui.txtLog
    $script:TimerHeld = $false
    $script:AskedRestorePoint = $false
    $script:DiagLoaded = $false
    $script:PrioEntries = @()

    $adminText = if (Test-Admin) { 'Running as administrator' } else { 'Read-only (not administrator)' }
    $ui.txtAdmin.Text = '{0}   {1}   v{2}' -f $adminText, [char]0x00B7, $AppVersion

    $ui.btnApply.Add_Click({ Invoke-Safe { Invoke-ApplySelected } })
    $ui.btnRevert.Add_Click({ Invoke-Safe { Invoke-RevertSelected } })
    $ui.btnRestoreAll.Add_Click({ Invoke-Safe { Invoke-RestoreEverything } })
    $ui.btnRestorePoint.Add_Click({ Invoke-Safe { Set-Busy $true; try { New-RestorePoint } finally { Set-Busy $false } } })
    $ui.btnRecommended.Add_Click({ Invoke-Safe { Select-Recommended } })
    $ui.btnNone.Add_Click({ foreach ($t in $Tweaks) { $script:Rows[$t.Id].Check.IsChecked = $false } })
    $ui.btnDiag.Add_Click({ Invoke-Safe { Show-Diagnostics } })
    $ui.btnTimer.Add_Click({ Invoke-Safe { Switch-TimerHold } })
    $ui.btnBrowse.Add_Click({ Invoke-Safe {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Programs (*.exe)|*.exe'
        $dlg.Title = 'Pick the game executable'
        if ($dlg.ShowDialog($window)) { $ui.txtExe.Text = [IO.Path]::GetFileName($dlg.FileName) }
    } })
    $ui.btnPrioHigh.Add_Click({ Invoke-Safe { Add-PriorityEntry $ui.txtExe.Text 3; $ui.txtExe.Text = ''; Update-PriorityList } })
    $ui.btnPrioAbove.Add_Click({ Invoke-Safe { Add-PriorityEntry $ui.txtExe.Text 6; $ui.txtExe.Text = ''; Update-PriorityList } })
    $ui.btnPrioRemove.Add_Click({ Invoke-Safe {
        $i = $ui.lstPrio.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:PrioEntries.Count) { Show-Message 'Pick a program in the list first.'; return }
        Remove-PriorityEntry $script:PrioEntries[$i].Exe
        Update-PriorityList
    } })
    $ui.tabs.Add_SelectionChanged({
        param($s, $e)
        if ($e.OriginalSource -ne $ui.tabs) { return }
        if ($ui.tabs.SelectedItem -eq $ui.tabDiag -and -not $script:DiagLoaded) {
            $script:DiagLoaded = $true
            Invoke-Safe { Show-Diagnostics }
        }
    })

    $tick = New-Object System.Windows.Threading.DispatcherTimer
    $tick.Interval = [TimeSpan]::FromSeconds(1)
    $tick.Add_Tick({ try { Update-TimerText } catch {} })

    $window.Add_ContentRendered({ Invoke-Safe { Initialize-View }; $tick.Start() })
    $window.Add_Closing({ $tick.Stop(); if ($script:TimerHeld) { try { [void](Set-TimerHold $false) } catch {} } })

    if ($SelfTest) {
        Initialize-View
        Show-Diagnostics
        "SELFTEST window built: $($Tweaks.Count) tweaks, $($ui.pnlDiag.Children.Count) diagnostics, summary '$($ui.txtSummary.Text)'"
        foreach ($t in $Tweaks) { '  {0,-12} {1}' -f $t.Id, $script:Rows[$t.Id].Status.Text }
        $window.Close()
        exit 0
    }

    [void]$window.ShowDialog()
} catch {
    $msg = "$($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)"
    if ($ReadOnly) { Write-Host $msg; exit 1 }
    try { Write-Log "Fatal: $msg" } catch {}
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("Something went wrong:`n`n$msg", $AppName, 'OK', 'Error')
    } catch {}
    exit 1
}
