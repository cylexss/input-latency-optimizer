<#
    Input Latency Optimizer 1.2
    Reversible Windows 10/11 tweaks that target input latency, a read-only BIOS check and two
    small measuring tools. Checks and changes run on a background thread (-Library loads this
    same file there), so the window stays responsive while they work.

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
    [switch]$SelfTest,
    [switch]$Library
)

$ErrorActionPreference = 'Stop'

$AppName    = 'Input Latency Optimizer'
$AppVersion = '1.2'
$DataDir    = Join-Path $env:ProgramData 'InputLatencyOptimizer'
$BackupFile = Join-Path $DataDir 'backup.json'
$LogFile    = Join-Path $DataDir 'log.txt'
$WakeFile   = Join-Path $DataDir 'wake-tests.json'
$IsWorker   = [bool]$Library
$ReadOnly   = [bool]($Status -or $SelfTest -or $IloReadOnly)   # $IloReadOnly: set by the window for its worker

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $ReadOnly -and -not $IsWorker -and -not (Test-Admin)) {
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
# Compiling this takes about a second, so the window leaves it to the worker thread.
$NativeSource = @'
using System;
using System.Diagnostics;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace ILO {
    public static class Native {
        [DllImport("dwmapi.dll")]
        static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        // DWMWA_USE_IMMERSIVE_DARK_MODE: a dark title bar on Windows 10 20H1 and later.
        public static void UseDarkTitleBar(Window window) {
            int on = 1;
            try { DwmSetWindowAttribute(new WindowInteropHelper(window).Handle, 20, ref on, 4); } catch (Exception) { }
        }

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

    // NVIDIA driver settings through NVAPI: the global profile, the same place as "Global Settings"
    // in NVIDIA Control Panel. Nothing persists until SaveSettings runs.
    public static class Nv {
        [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
        static extern IntPtr Query(uint id);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnVoid();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnSessionOut(out IntPtr session);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnSession(IntPtr session);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnProfileOut(IntPtr session, out IntPtr profile);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnGet(IntPtr session, IntPtr profile, uint id, [In, Out] byte[] setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnSet(IntPtr session, IntPtr profile, [In, Out] byte[] setting);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int FnDelete(IntPtr session, IntPtr profile, uint id);
        delegate void SessionWork(IntPtr session, IntPtr profile);

        const int SettingSize = 12320;      // sizeof(NVDRS_SETTING_V1)
        const int OffsetId = 4100, OffsetIsPredefined = 4112, OffsetCurrent = 8220;
        const int NotFound = -160;          // NVAPI_SETTING_NOT_FOUND
        const uint Initialize = 0x0150E828, CreateSession = 0x0694D52E, DestroySession = 0xDAD9CFF8, LoadSettings = 0x375DBD6B,
                   SaveSettings = 0xFCBC7E14, GetGlobalProfile = 0x617BFF9F, GetSetting = 0x73BF8338, SetSetting = 0x577DD202,
                   DeleteSetting = 0xE4A26362;

        static bool checkedOnce, available;

        static T Fn<T>(uint id) { return (T)(object)Marshal.GetDelegateForFunctionPointer(Query(id), typeof(T)); }

        static void Check(int rc, string what) {
            if (rc != 0) throw new InvalidOperationException("The NVIDIA driver refused " + what + " (NVAPI error " + rc + ").");
        }

        // False on PCs without an NVIDIA driver (nvapi64.dll is missing).
        public static bool Available() {
            if (!checkedOnce) {
                checkedOnce = true;
                try { available = Fn<FnVoid>(Initialize)() == 0; } catch (Exception) { available = false; }
            }
            return available;
        }

        static byte[] NewSetting(uint id, uint value) {
            byte[] s = new byte[SettingSize];
            BitConverter.GetBytes((uint)(SettingSize | (1 << 16))).CopyTo(s, 0);
            BitConverter.GetBytes(id).CopyTo(s, OffsetId);
            BitConverter.GetBytes(value).CopyTo(s, OffsetCurrent);
            return s;
        }

        static void WithSession(SessionWork work) {
            IntPtr session, profile;
            Check(Fn<FnSessionOut>(CreateSession)(out session), "opening a settings session");
            try {
                Check(Fn<FnSession>(LoadSettings)(session), "loading its settings");
                Check(Fn<FnProfileOut>(GetGlobalProfile)(session, out profile), "opening the global profile");
                work(session, profile);
            } finally { Fn<FnSession>(DestroySession)(session); }
        }

        // userSet is false when the value is only the driver's predefined one.
        public static bool TryGet(uint id, out uint value, out bool userSet) {
            uint v = 0; bool u = false, found = false;
            WithSession(delegate(IntPtr session, IntPtr profile) {
                byte[] s = NewSetting(id, 0);
                int rc = Fn<FnGet>(GetSetting)(session, profile, id, s);
                if (rc == NotFound) return;
                Check(rc, "reading a setting");
                found = true;
                v = BitConverter.ToUInt32(s, OffsetCurrent);
                u = BitConverter.ToUInt32(s, OffsetIsPredefined) == 0;
            });
            value = v; userSet = u;
            return found;
        }

        // Reads several settings in one session, which is much faster than one session each.
        // A setting that is not set comes back as -1.
        public static long[] ReadAll(uint[] ids) {
            long[] values = new long[ids.Length];
            WithSession(delegate(IntPtr session, IntPtr profile) {
                FnGet get = Fn<FnGet>(GetSetting);
                for (int i = 0; i < ids.Length; i++) {
                    byte[] s = NewSetting(ids[i], 0);
                    int rc = get(session, profile, ids[i], s);
                    if (rc == NotFound) { values[i] = -1; continue; }
                    Check(rc, "reading a setting");
                    values[i] = BitConverter.ToUInt32(s, OffsetCurrent);
                }
            });
            return values;
        }

        public static void Set(uint id, uint value) {
            WithSession(delegate(IntPtr session, IntPtr profile) {
                Check(Fn<FnSet>(SetSetting)(session, profile, NewSetting(id, value)), "changing a setting");
                Check(Fn<FnSession>(SaveSettings)(session), "saving its settings");
            });
        }

        // Removes the setting from the profile, which returns it to the driver's default.
        public static void Delete(uint id) {
            WithSession(delegate(IntPtr session, IntPtr profile) {
                int rc = Fn<FnDelete>(DeleteSetting)(session, profile, id);
                if (rc == NotFound) return;
                Check(rc, "removing a setting");
                Check(Fn<FnSession>(SaveSettings)(session), "saving its settings");
            });
        }

        // Writes a value and reads it back in a session that closes without saving, so nothing changes.
        public static uint ProbeUnsaved(uint id, uint value) {
            uint v = 0;
            WithSession(delegate(IntPtr session, IntPtr profile) {
                Check(Fn<FnSet>(SetSetting)(session, profile, NewSetting(id, value)), "changing a setting");
                byte[] s = NewSetting(id, 0);
                Check(Fn<FnGet>(GetSetting)(session, profile, id, s), "reading a setting");
                v = BitConverter.ToUInt32(s, OffsetCurrent);
            });
            return v;
        }
    }

    // Eased mouse-wheel scrolling. Written in C# so it costs nothing while a frame is being drawn.
    public static class SmoothScroll {
        static readonly DependencyProperty OffsetProperty = DependencyProperty.RegisterAttached(
            "IloOffset", typeof(double), typeof(SmoothScroll), new PropertyMetadata(0.0, OnOffsetChanged));
        static readonly DependencyProperty TargetProperty = DependencyProperty.RegisterAttached(
            "IloTarget", typeof(double), typeof(SmoothScroll), new PropertyMetadata(-1.0));

        public static void Attach(ScrollViewer viewer) { viewer.PreviewMouseWheel += OnWheel; }

        static void OnOffsetChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) {
            ((ScrollViewer)d).ScrollToVerticalOffset((double)e.NewValue);
        }

        // A list inside the page (the priority list) keeps its own scrolling.
        static bool OverNestedScroller(ScrollViewer viewer, object source) {
            DependencyObject o = source as DependencyObject;
            while (o != null && o != viewer) {
                ScrollViewer inner = o as ScrollViewer;
                if (inner != null && inner.ScrollableHeight > 0) return true;
                o = o is Visual ? VisualTreeHelper.GetParent(o) : LogicalTreeHelper.GetParent(o);
            }
            return false;
        }

        static void OnWheel(object sender, MouseWheelEventArgs e) {
            ScrollViewer viewer = (ScrollViewer)sender;
            if (viewer.ScrollableHeight <= 0 || OverNestedScroller(viewer, e.OriginalSource)) return;
            double target = (double)viewer.GetValue(TargetProperty);
            if (target < 0) {   // not mid-scroll: start from where the view is, the scrollbar may have moved it
                target = viewer.VerticalOffset;
                viewer.BeginAnimation(OffsetProperty, null);
                viewer.SetValue(OffsetProperty, target);
            }
            target = Math.Max(0, Math.Min(viewer.ScrollableHeight, target - e.Delta * 1.1));
            viewer.SetValue(TargetProperty, target);
            double thisTarget = target;
            CubicEase ease = new CubicEase();
            ease.EasingMode = EasingMode.EaseOut;
            DoubleAnimation animation = new DoubleAnimation(target, new Duration(TimeSpan.FromMilliseconds(260)));
            animation.EasingFunction = ease;
            animation.Completed += delegate {
                if ((double)viewer.GetValue(TargetProperty) == thisTarget) viewer.SetValue(TargetProperty, -1.0);
            };
            viewer.BeginAnimation(OffsetProperty, animation, HandoffBehavior.SnapshotAndReplace);
            e.Handled = true;
        }
    }

    // Counts raw mouse reports. Moving the mouse quickly makes the rate approach its polling rate.
    public static class MousePoll {
        [StructLayout(LayoutKind.Sequential)]
        struct RawInputDevice { public ushort UsagePage; public ushort Usage; public uint Flags; public IntPtr Target; }

        [DllImport("user32.dll", SetLastError = true)]
        static extern bool RegisterRawInputDevices(RawInputDevice[] devices, uint count, uint size);

        const int WmInput = 0x00FF;
        const uint RemoveDevice = 0x00000001;
        static HwndSource source;
        static long reports;

        static bool Register(uint flags, IntPtr target) {
            RawInputDevice[] d = new RawInputDevice[1];
            d[0].UsagePage = 1; d[0].Usage = 2; d[0].Flags = flags; d[0].Target = target;   // generic desktop, mouse
            return RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RawInputDevice)));
        }

        static IntPtr Hook(IntPtr window, int message, IntPtr w, IntPtr l, ref bool handled) {
            if (message == WmInput) Interlocked.Increment(ref reports);
            return IntPtr.Zero;
        }

        public static long Reports { get { return Interlocked.Read(ref reports); } }

        public static bool Start(Window window) {
            IntPtr handle = new WindowInteropHelper(window).Handle;
            source = HwndSource.FromHwnd(handle);
            source.AddHook(Hook);
            if (Register(0, handle)) return true;
            source.RemoveHook(Hook);
            source = null;
            return false;
        }

        public static void Stop() {
            if (source == null) return;
            Register(RemoveDevice, IntPtr.Zero);
            source.RemoveHook(Hook);
            source = null;
        }
    }

    // How late Windows wakes a thread that asked to sleep 1 ms, the way a game's frame limiter does.
    public static class WakeTest {
        // Returns average, 99th percentile and worst sleep time in milliseconds. Asks for a 1 ms timer
        // like a game does, unless the app already holds a finer one: a process has only one timer
        // request, so changing it here would cancel that hold. WPF's own timer calls can cancel the
        // request when an animation ends, so it is repeated during the test.
        public static double[] Run(int samples, bool alreadyHeld) {
            double[] t = new double[samples];
            uint current;
            try {
                for (int i = 0; i < samples; i++) {
                    if (!alreadyHeld && i % 50 == 0) Native.NtSetTimerResolution(10000, true, out current);
                    long start = Stopwatch.GetTimestamp();
                    Thread.Sleep(1);
                    t[i] = (Stopwatch.GetTimestamp() - start) * 1000.0 / Stopwatch.Frequency;
                }
            } finally { if (!alreadyHeld) Native.NtSetTimerResolution(10000, false, out current); }
            double sum = 0;
            foreach (double v in t) sum += v;
            Array.Sort(t);
            return new double[] { sum / samples, t[(int)(samples * 0.99)], t[samples - 1] };
        }
    }

    // Pings several hosts at the same time and reports how steady each one is.
    public static class NetTest {
        // Returns average ms (-1 if nothing answered), jitter ms, worst ms and packets lost.
        static double[] PingOne(string host, int count, int intervalMs) {
            int lost = 0, ok = 0, steps = 0;
            double sum = 0, worst = 0, jitter = 0, last = -1;
            byte[] data = new byte[32];
            using (Ping ping = new Ping()) {
                // The first call includes .NET start-up work and name lookup, so it is not counted.
                try { ping.Send(host, 1000, data); } catch (PingException) { }
                for (int i = 0; i < count; i++) {
                    long start = Stopwatch.GetTimestamp();
                    bool answered = false;
                    try { answered = ping.Send(host, 1000, data).Status == IPStatus.Success; } catch (PingException) { }
                    double ms = (Stopwatch.GetTimestamp() - start) * 1000.0 / Stopwatch.Frequency;
                    if (answered) {
                        ok++;
                        sum += ms;
                        if (ms > worst) worst = ms;
                        if (last >= 0) { jitter += Math.Abs(ms - last); steps++; }
                        last = ms;
                    } else lost++;
                    int rest = intervalMs - (int)ms;
                    if (rest > 0) Thread.Sleep(rest);
                }
            }
            return new double[] { ok > 0 ? sum / ok : -1, steps > 0 ? jitter / steps : 0, worst, lost };
        }

        public static double[][] Run(string[] hosts, int count, int intervalMs) {
            double[][] results = new double[hosts.Length][];
            Thread[] threads = new Thread[hosts.Length];
            for (int i = 0; i < hosts.Length; i++) {
                int index = i;
                threads[i] = new Thread(delegate() {
                    try { results[index] = PingOne(hosts[index], count, intervalMs); }
                    catch (Exception) { results[index] = new double[] { -1, 0, 0, count }; }
                });
                threads[i].IsBackground = true;
                threads[i].Start();
            }
            foreach (Thread t in threads) t.Join();
            return results;
        }
    }
}
'@

function Add-IloTypes {
    if ('ILO.Native' -as [type]) { return }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $refs = @([System.Windows.Window], [System.Windows.UIElement], [System.Windows.DependencyObject], [System.Xaml.XamlReader]) |
        ForEach-Object { $_.Assembly.Location }
    Add-Type -TypeDefinition $NativeSource -ReferencedAssemblies $refs
}

if ($Status -or $IsWorker) { Add-IloTypes }

$SPI_SETMOUSE          = 0x0004
$SPI_SETKEYBOARDSPEED  = 0x000B
$SPI_SETKEYBOARDDELAY  = 0x0017
$SPI_SETANIMATION      = 0x0049
$SPI_SETMENUSHOWDELAY  = 0x006B
$SPI_SETMOUSETRAILS    = 0x005D
$SPI_SETMOUSESPEED     = 0x0071
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
$SetCpuIdleOff = '5d76a2ca-e8c0-402f-a133-2158492d58ad'
$SubDisk       = '0012ee47-9041-4b5d-9b77-535fba8b1442'
$SetDiskIdle   = '6738e2c4-e8a5-4a42-b16a-e040e769756e'
$SetAhciLpm    = '0b2d69d7-a2a1-449c-9680-f91c70521c60'
$SetNvmeTol1   = 'fc95af4d-40e7-4b6d-835a-56d131dbc80e'
$SetNvmeTol2   = 'dbc9e238-6de9-49e3-92cd-8c2b4946b472'
$SubWifi       = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$SetWifiPower  = '12bbebe6-58d6-4636-95bb-3217ef867c1a'

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

# ------------------------------------------------------------------ NVIDIA driver settings
function Test-NvTweak($t) {
    if (-not [ILO.Nv]::Available()) { return 'NA' }
    $hit = 0
    foreach ($s in $t.Nv) {
        if ($script:NvCache) {
            if ($script:NvCache[[long]$s.Id] -eq [long]$s.V) { $hit++ }
            continue
        }
        $v = [uint32]0; $user = $false
        if ([ILO.Nv]::TryGet([uint32]$s.Id, [ref]$v, [ref]$user) -and $v -eq [uint32]$s.V) { $hit++ }
    }
    if ($hit -eq @($t.Nv).Count) { 'Applied' } elseif ($hit -gt 0) { 'Partial' } else { 'Default' }
}

# Lets a full status check read every NVIDIA setting at once. Valid only during that check.
function Update-NvCache {
    $script:NvCache = $null
    if (-not [ILO.Nv]::Available()) { return }
    $ids = @($Tweaks | Where-Object { $_.Nv } | ForEach-Object { $_.Nv } | ForEach-Object { [uint32]$_.Id })
    $values = [ILO.Nv]::ReadAll([uint32[]]$ids)
    $cache = @{}
    for ($i = 0; $i -lt $ids.Count; $i++) { $cache[[long]$ids[$i]] = $values[$i] }
    $script:NvCache = $cache
}

function Set-NvTweak($t, $Data) {
    if ($null -eq $Data.nv) { $Data.nv = @() }
    foreach ($s in $t.Nv) {
        if (@(@($Data.nv) | Where-Object { [long]$_.Id -eq [long]$s.Id }).Count -eq 0) {
            $v = [uint32]0; $user = $false
            $found = [ILO.Nv]::TryGet([uint32]$s.Id, [ref]$v, [ref]$user)
            $Data.nv = @($Data.nv) + @(@{ Id = [long]$s.Id; Exists = [bool]($found -and $user); V = [long]$v })
        }
        [ILO.Nv]::Set([uint32]$s.Id, [uint32]$s.V)
    }
}

function Restore-NvTweak($Data) {
    foreach ($e in @($Data.nv)) {
        if ($e.Exists) { [ILO.Nv]::Set([uint32]$e.Id, [uint32]$e.V) } else { [ILO.Nv]::Delete([uint32]$e.Id) }
    }
}

# ------------------------------------------------------------------ network adapters
# Only settings whose off value is 0. Each one is used only if the adapter lists 0 as valid.
$NicKeywords = @('*InterruptModeration', '*EEE', 'AdvancedEEE', 'EEELinkAdvertisement', 'EnableGreenEthernet', 'GreenEthernet',
                 'PowerSavingMode', 'AutoDisableGigabit', 'GigaLite', 'ULPMode', 'ReduceSpeedOnPowerDown', '*FlowControl', '*PacketCoalescing')

# Reads the driver's registry keys directly: about 1 second faster than Get-NetAdapterAdvancedProperty.
function Get-NicSettings {
    $root = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    $up = @{}
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -eq 'Up') { $up[$n.Id] = $n.Name }
    }
    $k = Open-RegKey $root
    if ($null -eq $k) { return }
    try {
        foreach ($sub in $k.GetSubKeyNames()) {
            if ($sub -notmatch '^\d{4}$') { continue }
            $p = "$root\$sub"
            $id = [string](Read-RegValue $p 'NetCfgInstanceId').V
            if (-not $id -or -not $up.ContainsKey($id)) { continue }
            if (([int](Read-RegValue $p 'Characteristics').V -band 4) -eq 0) { continue }   # NCF_PHYSICAL
            foreach ($key in $NicKeywords) {
                $param = "$p\Ndi\Params\$key"
                if (-not (Read-RegValue "$param\Enum" '0').Exists) { continue }             # 0 must be a valid choice
                $v = Read-RegValue $p $key
                if (-not $v.Exists) { $v = Read-RegValue $param 'Default' }                 # never changed: the driver's default
                if ($v.Exists) { @{ Nic = $up[$id]; Key = $key; Value = [string]$v.V } }
            }
        }
    } finally { $k.Close() }
}

# ------------------------------------------------------------------ forced priorities on Windows processes
function Get-ForcedWindowsPriorities {
    $k = Open-RegKey $IfeoPath
    if ($null -eq $k) { return }
    try {
        foreach ($exe in $k.GetSubKeyNames()) {
            if ($WindowsExe -notcontains $exe) { continue }
            foreach ($name in 'CpuPriorityClass', 'IoPriority', 'PagePriority') {
                if ((Read-RegValue "$IfeoPath\$exe\PerfOptions" $name).Exists) { @{ Exe = $exe; Name = $name } }
            }
        }
    } finally { $k.Close() }
}

$HvciPath = 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'

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
        Id = 'StoragePower'; Cat = 'Power and CPU'; Impact = 'Medium'; Rec = $true; When = 'instant'
        Name = 'Keep drives awake'
        Desc = 'Stops drives from using power states that take time to wake from while plugged in: NVMe latency tolerance 0, SATA link power management off and no hard disk sleep. Avoids short stalls when a game reads from a drive that has to wake up first. Drives run slightly warmer.'
        Power = @(
            @{ Sub = $SubDisk; Set = $SetNvmeTol1; V = 0; Label = 'Primary NVMe latency tolerance' }
            @{ Sub = $SubDisk; Set = $SetNvmeTol2; V = 0; Label = 'Secondary NVMe latency tolerance' }
            @{ Sub = $SubDisk; Set = $SetAhciLpm;  V = 0; Label = 'SATA link power management' }
            @{ Sub = $SubDisk; Set = $SetDiskIdle; V = 0; Label = 'Turn off hard disk after' }
        )
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
        Id = 'PointerExact'; Cat = 'Mouse and keyboard'; Impact = 'Low'; Rec = $false; When = 'instant'
        Name = 'Pointer speed 6/11 and no pointer trails'
        Desc = "Sets Windows pointer speed to the middle notch, the only one that maps mouse movement 1:1 without skipping pixels, and turns off pointer trails, which add cursor lag. It changes how fast your cursor feels, so it is your call. Raw-input games are unaffected."
        Reg = @(
            RegValue 'HKCU\Control Panel\Mouse' 'MouseSensitivity' 'String' '10'
            RegValue 'HKCU\Control Panel\Mouse' 'MouseTrails' 'String' '0'
        )
        Live = {
            $speed = [int](Get-RegString 'HKCU\Control Panel\Mouse' 'MouseSensitivity' '10')
            $trails = [uint32](Get-RegString 'HKCU\Control Panel\Mouse' 'MouseTrails' '0')
            [void][ILO.Native]::SystemParametersInfoNull($SPI_SETMOUSESPEED, 0, [IntPtr]::new($speed), $SPIF_SENDCHANGE)
            [void][ILO.Native]::SystemParametersInfoNull($SPI_SETMOUSETRAILS, $trails, [IntPtr]::Zero, $SPIF_SENDCHANGE)
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
        Id = 'NvLowLatency'; Cat = 'NVIDIA driver'; Impact = 'High'; Rec = $true; When = 'game'
        Name = 'Low Latency Mode: On'
        Desc = 'Limits the driver to one queued frame, which cuts latency when the graphics card is the bottleneck. Mainly helps DirectX 11 games without Reflex; Reflex, DirectX 12 and Vulkan games manage their own queue. Ultra can only be picked in NVIDIA Control Panel. Per-game profiles there override this.'
        Nv = @( @{ Id = 0x007BA09E; V = 1 } )   # PRERENDERLIMIT_ID
    }
    @{
        Id = 'NvRefresh'; Cat = 'NVIDIA driver'; Impact = 'Medium'; Rec = $true; When = 'game'
        Name = 'Preferred refresh rate: Highest available'
        Desc = "Exclusive-fullscreen games that do not ask for a specific refresh rate run at your monitor's highest instead of a lower default."
        Nv = @( @{ Id = 0x0064B541; V = 1 } )   # REFRESH_RATE_OVERRIDE_ID = HIGHEST_AVAILABLE
    }
    @{
        Id = 'NvPowerMax'; Cat = 'NVIDIA driver'; Impact = 'Medium'; Rec = $true; When = 'game'
        Name = 'Power management: Prefer maximum performance'
        Desc = 'Stops the graphics card from clocking down while a 3D app runs, which avoids a ramp-up delay when GPU load is low. Uses more power while a game or GPU-accelerated app is open.'
        Nv = @( @{ Id = 0x1057EB71; V = 1 } )   # PREFERRED_PSTATE_ID = PREFER_MAX
    }
    @{
        Id = 'NvShaderCache'; Cat = 'NVIDIA driver'; Impact = 'Medium'; Rec = $true; When = 'game'
        Name = 'Shader cache: on, unlimited size'
        Desc = 'Keeps compiled shaders on disk instead of throwing old ones away when the cache fills up, so games stutter less from recompiling them. Uses more disk space over time.'
        Nv = @(
            @{ Id = 0x00198FFF; V = 1 }             # PS_SHADERDISKCACHE_ID = ON
            @{ Id = 0x00AC8497; V = 4294967295 }    # PS_SHADERDISKCACHE_MAX_SIZE_ID = MAX
        )
    }
    @{
        Id = 'NvVsyncOff'; Cat = 'NVIDIA driver'; Impact = 'High'; Rec = $false; When = 'game'
        Name = 'Vertical sync: Force off'
        Desc = 'V-Sync makes finished frames wait for the screen, which adds a lot of latency, and some games turn it on by default. This forces it off everywhere, so you may see tearing. Do not use it with G-Sync or FreeSync: they work best with V-Sync on in the driver.'
        Nv = @( @{ Id = 0x00A879CF; V = 0x08416747 } )   # VSYNCMODE_ID = FORCEOFF
    }
    @{
        Id = 'NvVulkanDxgi'; Cat = 'NVIDIA driver'; Impact = 'Varies'; Rec = $false; When = 'game'
        Name = 'Vulkan/OpenGL present method: layered on DXGI'
        Desc = 'Presents Vulkan and OpenGL games through a DXGI swapchain, which gives them the flip presentation model in windowed and borderless mode. Results vary by game, so compare it with the default.'
        Nv = @( @{ Id = 0x20D690F8; V = 1 } )   # OGL_CPL_PREFER_DXPRESENT_ID = PREFER_ENABLED
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
        Id = 'NoTransparency'; Cat = 'Desktop'; Impact = 'Low'; Rec = $false; When = 'signout'
        Name = 'Transparency effects off'
        Desc = 'Gives the desktop compositor a little less work by turning off see-through taskbars and menus. Mostly a look-and-feel choice.'
        Reg = @( RegValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 'DWord' 0 )
    }
    @{
        Id = 'NicLatency'; Cat = 'Network'; Impact = 'Medium'; Rec = $true; When = 'instant'
        Name = 'Network adapter low-latency mode'
        Desc = 'Turns off interrupt moderation, packet coalescing, Energy Efficient Ethernet, green and power-saving modes and flow control on connected adapters, so packets are handled as soon as they arrive. Your connection drops for a few seconds when this is applied or reverted, and it uses a little more CPU at very high download speeds.'
        Test = {
            $all = @(Get-NicSettings)
            if ($all.Count -eq 0) { return 'NA' }
            $off = @($all | Where-Object { $_.Value -eq '0' }).Count
            if ($off -eq $all.Count) { 'Applied' } elseif ($off -gt 0) { 'Partial' } else { 'Default' }
        }
        Apply = {
            param($t, $d)
            if ($null -eq $d.nic) { $d.nic = @() }
            $changed = @{}
            foreach ($s in @(Get-NicSettings | Where-Object { $_.Value -ne '0' })) {
                if (@(@($d.nic) | Where-Object { $_.Nic -eq $s.Nic -and $_.Key -eq $s.Key }).Count -eq 0) {
                    $d.nic = @($d.nic) + @(@{ Nic = $s.Nic; Key = $s.Key; Value = $s.Value })
                }
                Set-NetAdapterAdvancedProperty -Name $s.Nic -RegistryKeyword $s.Key -RegistryValue '0' -NoRestart
                $changed[$s.Nic] = $true
            }
            foreach ($n in @($changed.Keys)) { Restart-NetAdapter -Name $n }
        }
        Revert = {
            param($t, $d)
            $changed = @{}
            foreach ($e in @($d.nic)) {
                if ($null -eq (Get-NetAdapter -Name $e.Nic -ErrorAction SilentlyContinue)) { continue }
                Set-NetAdapterAdvancedProperty -Name $e.Nic -RegistryKeyword $e.Key -RegistryValue $e.Value -NoRestart
                $changed[$e.Nic] = $true
            }
            foreach ($n in @($changed.Keys)) { Restart-NetAdapter -Name $n }
        }
    }
    @{
        Id = 'WifiPower'; Cat = 'Network'; Impact = 'Medium'; Rec = $true; When = 'instant'
        Name = 'Wi-Fi adapter: maximum performance'
        Desc = 'Stops the Wi-Fi adapter from napping between packets while plugged in, which is a common cause of ping spikes on Wi-Fi. Shows N/A on PCs without Wi-Fi.'
        Power = @( @{ Sub = $SubWifi; Set = $SetWifiPower; V = 0; Label = 'Wireless adapter power saving mode' } )
        Test = {
            param($t)
            $wifi = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.NetworkInterfaceType -eq 'Wireless80211' })
            if ($wifi.Count -eq 0) { return 'NA' }
            Test-PowerTweak $t
        }
    }
    @{
        Id = 'DeliveryOpt'; Cat = 'Network'; Impact = 'Low'; Rec = $true; When = 'reboot'
        Name = 'No sharing of Windows updates with other PCs'
        Desc = 'Stops Windows from uploading updates to other PCs in the background, which can fill your upload and raise your ping. Updates still download normally.'
        Reg = @( RegValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 'DWord' 0 )
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
        Id = 'SysPriorities'; Cat = 'Clean-up'; Impact = 'Varies'; Rec = $false; When = 'reboot'
        Name = 'Remove forced priorities on Windows processes'
        Desc = 'Some tweak tools pin Windows processes to fixed priorities, such as svchost.exe at Idle or dwm.exe at Realtime. svchost.exe hosts audio, network and many other services, so starving it can cause hitches under load. This removes those overrides and lets Windows schedule them again. Your game entries in Live tools stay.'
        Test = { if (@(Get-ForcedWindowsPriorities).Count -eq 0) { 'Applied' } else { 'Default' } }
        Apply = {
            param($t, $d)
            $found = @(Get-ForcedWindowsPriorities)
            foreach ($e in $found) {
                $p = "$IfeoPath\$($e.Exe)\PerfOptions"
                Save-RegValueState $d $p $e.Name
                Remove-RegValue $p $e.Name
            }
            foreach ($exe in @($found | ForEach-Object { $_.Exe } | Select-Object -Unique)) {
                Remove-EmptyKey "$IfeoPath\$exe\PerfOptions"
                Remove-EmptyKey "$IfeoPath\$exe"
            }
        }
    }
    @{
        Id = 'GlobalTimer'; Cat = 'Experimental'; Impact = 'Experimental'; Rec = $false; When = 'reboot'; MinBuild = 22000
        Name = 'Global timer resolution requests'
        Desc = "Windows 11 only. Lets a high timer-resolution request (like 'Hold finest timer resolution' in Live tools) apply system-wide again, as before Windows 10 2004. Can tighten frame pacing in games that sleep between frames; costs a little power. Evidence is mixed."
        Reg = @( RegValue 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 'DWord' 1 )
    }
    @{
        Id = 'FsoOff'; Cat = 'Experimental'; Impact = 'Experimental'; Rec = $false; When = 'game'
        Name = 'Fullscreen optimizations off'
        Desc = 'Asks Windows to give games true exclusive fullscreen. Modern games usually get the same latency either way, while some older DirectX 9 and 11 games respond better. Evidence is mixed, and Alt+Tab gets slower.'
        Reg = @(
            RegValue 'HKCU\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 'DWord' 2
            RegValue 'HKCU\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 'DWord' 1
            RegValue 'HKCU\System\GameConfigStore' 'GameDVR_FSEBehavior' 'DWord' 2
            RegValue 'HKCU\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 'DWord' 1
        )
    }
    @{
        Id = 'CpuIdleOff'; Cat = 'Experimental'; Impact = 'Experimental'; Rec = $false; When = 'instant'
        Name = 'No CPU idle states (extreme)'
        Desc = 'Keeps every core awake so none has to wake up when work arrives (plugged in only). It adds a lot of heat and power draw, Task Manager shows 100% CPU, and it can lower boost clocks on Ryzen, which can cost FPS. Measure before keeping it.'
        Confirm = "This keeps every CPU core running at all times.`n`nExpect much more heat and power draw, and Task Manager will show 100% CPU. On Ryzen it can lower boost clocks and cost FPS.`n`nTurn it on anyway?"
        Power = @( @{ Sub = $SubCpu; Set = $SetCpuIdleOff; V = 1; Label = 'Processor idle disable' } )
    }
    @{
        Id = 'MemoryIntegrity'; Cat = 'Security trade-off'; Impact = 'Varies'; Rec = $false; When = 'reboot'
        Name = 'Turn off Memory integrity (Core isolation)'
        Desc = "Memory integrity stops malicious or vulnerable drivers from running code in the Windows kernel. Microsoft says it may affect gaming performance, without saying how much. Turning it off lowers your PC's protection, so it is never selected automatically. Microsoft suggests turning it back on when you finish playing. If a game's anti-cheat asks for it, revert this."
        NaNote = 'Memory integrity is locked on by a policy or a UEFI lock on this PC.'
        Confirm = "This turns off a Windows security feature.`n`nMemory integrity stops malicious or vulnerable drivers from running code in the Windows kernel. Without it, those attacks are easier.`n`nTurn it off anyway?"
        Reg = @( RegValue $HvciPath 'Enabled' 'DWord' 0 )
        Test = {
            $locked = Read-RegValue $HvciPath 'Locked'
            $policy = Read-RegValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'HypervisorEnforcedCodeIntegrity'
            if (($locked.Exists -and [int]$locked.V -eq 1) -or ($policy.Exists -and [int]$policy.V -ne 0)) { return 'NA' }
            $v = Read-RegValue $HvciPath 'Enabled'
            if (-not $v.Exists -or [int]$v.V -eq 0) { 'Applied' } else { 'Default' }
        }
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
$WindowsExe   = $ProtectedExe + @('searchindexer.exe', 'trustedinstaller.exe', 'msmpeng.exe', 'wuauclt.exe')

# Usual BIOS menu locations. Names vary by board and BIOS version, so the BIOS tab says "usually".
$XmpMenu = @{
    ASUS = 'Ai Tweaker > Ai Overclock Tuner'; MSI = 'OC > A-XMP'; Gigabyte = 'Tweaker > Extreme Memory Profile (X.M.P.)'
    ASRock = 'OC Tweaker > DRAM Profile'; Biostar = 'Main tab > memory profile (XMP / DOCP)'
}
$RebarMenu = @{
    ASUS = 'Advanced > PCI Subsystem Settings'; MSI = 'Settings > Advanced > PCI Subsystem Settings'
    Gigabyte = 'Settings > IO Ports'; ASRock = 'Advanced > Chipset Configuration'
}

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
    @{ Title = 'Hit registration'; Items = @(
        'The game server decides what hits. Your PC only controls how fast and how steadily your packets reach it, so no Windows setting can fix bad netcode. The connection test in Live tools shows where a problem sits.'
        'Use a cable if you can. Wi-Fi adds jitter and loses packets, and no setting makes up for that.'
        'Pick the closest server region. The lower your ping, the sooner the server sees your shots.'
        'Check for bufferbloat: ping that jumps when anyone on your network downloads or uploads. Test it at waveform.com/tools/bufferbloat. The fix is in the router: turn on SQM or QoS and cap the speed a little below your real speed.'
        'Stop uploads and downloads while you play: cloud sync such as OneDrive, game launchers and torrents.'
        'Keep your frame rate stable. Big frame drops can delay when your shots are sent.'
        'Some shooters have a network buffer setting (Valorant: Network Buffering; CS2: buffering to smooth over packet jitter). Use the lowest value your connection stays stable at.'
    ) }
    @{ Title = 'Measure, do not guess'; Items = @(
        'Live tools has a mouse polling test and a wake-up test. Run the wake-up test before and after a change, with the same apps open, and keep only what helps.'
        'For true input-to-screen delay, use NVIDIA Reflex Analyzer on a supported monitor, or film the screen and mouse in slow motion.'
        'Change one thing at a time. If several tweaks go in at once and something gets worse, you will not know which one did it.'
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
    if ($IsWorker) {
        $IloSync.Queue.Enqueue(@{ Type = 'log'; Text = $line })
    } elseif ($script:LogBox) {
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
        if ($t.Nv)    { return [string](Test-NvTweak $t) }
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
        elseif ($t.Nv) { Set-NvTweak $t $Data }
        else {
            foreach ($s in @(Get-TweakValues $t)) {
                Save-RegValueState $Data $s.P $s.N
                Write-RegValue $s.P $s.N $s.K $s.V
            }
        }
    } else {
        if ($t.Power) { Restore-PowerTweak $t $Data }
        elseif ($t.Nv) { Restore-NvTweak $Data }
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
    if ($ProtectedExe -contains $Exe) { throw "$Exe is part of Windows - leave its priority alone." }
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
    # Releasing can report "not set" if WPF's own timer calls already cancelled the request. That is fine.
    if ($On -and $rc -ne 0) { throw ('NtSetTimerResolution failed (0x{0:X8})' -f $rc) }
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
            Add-Diag 'Memory integrity (Core isolation)' 'On' 'info' 'A security feature. Microsoft says it may affect gaming performance. Tweaks > Security trade-off can turn it off if you accept that; it is never selected automatically.'
        } else { Add-Diag 'Memory integrity (Core isolation)' 'Off' }
    } catch {}

    try {
        foreach ($nic in @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' })) {
            $val = '{0}   |   {1}' -f $nic.InterfaceDescription, $nic.LinkSpeed
            if ($nic.PhysicalMediaType -match '802\.11') {
                Add-Diag 'Network connection' $val 'warn' 'You are on Wi-Fi. A cable lowers latency and jitter more than any network setting can.'
            } else { Add-Diag 'Network connection' $val 'ok' }
        }
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
        $sys = @(Get-PriorityEntries | Where-Object { $WindowsExe -contains $_.Exe })
        if ($sys.Count) {
            $txt = ($sys | ForEach-Object { '{0} {1}' -f $_.Exe, (Get-PriorityName $_.Class) }) -join ', '
            Add-Diag 'Fixed CPU priorities on Windows processes' $txt 'warn' 'Another tweak tool forced these. Idle or Below normal on svchost.exe can cause audio crackle or hitches under load, and Windows already manages these processes well. Tweaks > Clean-up removes them, with a backup.'
        }
    } catch {}

    $n = $script:Backup.tweaks.Count + $script:Backup.priority.Count
    Add-Diag 'Backups' ('{0} saved   |   {1}' -f $n, $BackupFile)
    $list
}

# ------------------------------------------------------------------ BIOS check (read only)
# BIOS settings live in a board-specific format and a wrong write can stop a PC from booting, so
# this only reports what Windows can see and lists the rest for the user to change by hand.
function Get-BiosAudit {
    $detected = New-Object System.Collections.ArrayList
    $manual   = New-Object System.Collections.ArrayList
    $keep     = New-Object System.Collections.ArrayList
    function Add-Item($List, [string]$Title, [string]$Value, [string]$Level = 'info', [string]$Note = '') {
        [void]$List.Add(@{ Title = $Title; Value = $Value; Level = $Level; Note = $Note })
    }

    $boardText = 'Motherboard not detected'; $vendor = ''
    try {
        $bb = Get-CimInstance Win32_BaseBoard
        $boardText = ('{0} {1}' -f $bb.Manufacturer, $bb.Product).Trim()
        switch -Regex ($bb.Manufacturer) {
            'ASUS'           { $vendor = 'ASUS' }
            'Micro-Star|MSI' { $vendor = 'MSI' }
            'Gigabyte'       { $vendor = 'Gigabyte' }
            'ASRock'         { $vendor = 'ASRock' }
            'BIOSTAR'        { $vendor = 'Biostar' }
        }
    } catch {}

    $isAmd = $false; $isX3D = $false; $virtOn = $null
    try {
        $cpu = @(Get-CimInstance Win32_Processor)[0]
        $isAmd = [bool]($cpu.Manufacturer -match 'AMD')
        $isX3D = [bool]($cpu.Name -match 'X3D')
        $virtOn = $cpu.VirtualizationFirmwareEnabled
    } catch {}

    try {
        $bios = Get-CimInstance Win32_BIOS
        $date = $bios.ReleaseDate
        $val = '{0}, released {1}' -f $bios.SMBIOSBIOSVersion, $date.ToString('yyyy-MM-dd')
        if ($isAmd -and $date -lt [datetime]'2022-06-01') {
            Add-Item $detected 'BIOS version' $val 'warn' 'Older than AMD''s AGESA 1.2.0.7 update (mid-2022), which addressed random stutter from the fTPM. Check your board maker''s site for a newer BIOS.'
        } elseif (((Get-Date) - $date).TotalDays -gt 1095) {
            Add-Item $detected 'BIOS version' $val 'info' 'More than three years old. Check your board maker''s site for a newer one.'
        } else { Add-Item $detected 'BIOS version' $val 'ok' }
    } catch {}

    if ($env:firmware_type -eq 'UEFI') {
        Add-Item $detected 'Boot mode' 'UEFI (CSM is not in use)' 'ok'
    } elseif ($env:firmware_type) {
        Add-Item $detected 'Boot mode' $env:firmware_type 'warn' 'Re-Size BAR needs UEFI. Do not just turn off CSM: Windows on an MBR disk will stop booting. Convert the disk with mbr2gpt first.'
    }

    $ramOk = $false
    try {
        $sticks = @(Get-CimInstance Win32_PhysicalMemory)
        if ($sticks.Count) {
            $running = ($sticks | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
            $rated   = ($sticks | Measure-Object Speed -Maximum).Maximum
            $type    = $sticks[0].SMBIOSMemoryType
            $typeName = switch ($type) { 26 { 'DDR4' } 34 { 'DDR5' } default { 'RAM' } }
            $val = '{0} x {1} GB {2} at {3} MT/s (module reports {4})' -f $sticks.Count, ($sticks[0].Capacity / 1GB), $typeName, $running, $rated
            $looksStock = ($type -eq 26 -and $running -le 2666) -or ($type -eq 34 -and $running -le 4800)
            if ($running -lt $rated -or $looksStock) {
                Add-Item $detected 'RAM speed' $val 'warn' 'This looks like the slow default speed, which means XMP / EXPO / DOCP is probably off. Compare with the speed printed on the sticks. This is usually the biggest BIOS win.'
            } else {
                $ramOk = $true
                Add-Item $detected 'RAM speed' $val 'ok' 'Above the default speed, so XMP / EXPO / DOCP looks on.'
            }
            $channels = @($sticks | ForEach-Object {
                $m = [regex]::Match("$($_.BankLabel) $($_.DeviceLocator)", '(?i)channel\s*([A-D])|DIMM[\s_]*([A-D])\d')
                if ($m.Success) { $m.Groups[1].Value + $m.Groups[2].Value }
            } | Select-Object -Unique)
            if ($sticks.Count -eq 1) {
                Add-Item $detected 'Memory channels' 'One stick (single channel)' 'warn' 'A second matching stick doubles memory bandwidth, which matters most on integrated graphics and in CPU-heavy games.'
            } elseif ($channels.Count -ge 2) {
                Add-Item $detected 'Memory channels' 'Dual channel' 'ok'
            } elseif ($channels.Count -eq 1) {
                Add-Item $detected 'Memory channels' 'All sticks are in one channel' 'warn' 'Move them to the slots your motherboard manual recommends for dual channel.'
            }
        }
    } catch {}

    $rebarOn = $false
    try {
        $smi = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
        if ($smi) {
            $line = @(& $smi '--query-gpu=pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,memory.total' '--format=csv,noheader,nounits')[0]
            $f = @($line -split ',' | ForEach-Object { $_.Trim() })
            $bar = [regex]::Match((@(& $smi -q -d MEMORY) -join "`n"), 'BAR1 Memory Usage\s+Total\s*:\s*(\d+)')
            if ($bar.Success) {
                $mb = [int]$bar.Groups[1].Value
                if ($mb -ge 1024) {
                    $rebarOn = $true
                    Add-Item $detected 'Re-Size BAR' "On ($mb MB of video memory visible to the CPU)" 'ok' 'NVIDIA uses it only in games it has approved.'
                } else {
                    Add-Item $detected 'Re-Size BAR' "Off ($mb MB of video memory visible to the CPU)" 'warn' 'Turn it on in the BIOS. It needs UEFI boot mode.'
                }
            }
            if ([int]$f[1] -lt [int]$f[2]) {
                Add-Item $detected 'Graphics card slot' ('PCIe Gen {0}, running x{1} of x{2}' -f $f[0], $f[1], $f[2]) 'warn' 'The card has fewer lanes than it supports. Check that it is in the top slot and fully seated.'
            } else {
                Add-Item $detected 'Graphics card slot' ('PCIe Gen {0} x{1}' -f $f[0], $f[1]) 'ok'
            }
        }
    } catch {}

    try {
        foreach ($g in @(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -like 'PCI\*' })) {
            $m = Read-RegValue "HKLM\SYSTEM\CurrentControlSet\Enum\$($g.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" 'MSISupported'
            if ($m.Exists -and [int]$m.V -eq 1) {
                Add-Item $detected 'Graphics card interrupts' "$($g.Name): MSI mode on" 'ok'
            } else {
                Add-Item $detected 'Graphics card interrupts' "$($g.Name): MSI mode not set" 'info' 'Modern cards normally use MSI mode. This app does not force it, because a wrong value on a device can stop a PC from booting.'
            }
        }
    } catch {}

    try {
        $usb = @(Get-CimInstance Win32_USBController | Where-Object { $_.PNPDeviceID -like 'PCI\*' })
        if ($usb.Count) {
            $msi = @($usb | Where-Object {
                $m = Read-RegValue "HKLM\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" 'MSISupported'
                $m.Exists -and [int]$m.V -eq 1
            }).Count
            if ($msi -eq $usb.Count) { Add-Item $detected 'USB controller interrupts' "MSI mode on ($msi of $($usb.Count))" 'ok' }
            else { Add-Item $detected 'USB controller interrupts' "MSI mode on $msi of $($usb.Count)" 'info' 'Modern USB controllers normally use MSI mode. This app only reports it.' }
        }
    } catch {}

    try {
        $hv = [bool](Get-CimInstance Win32_ComputerSystem).HypervisorPresent
        $hvci = $false
        try { $hvci = @((Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard).SecurityServicesRunning) -contains 2 } catch {}
        if ($hv -and $hvci) {
            Add-Item $detected 'Virtualization' 'Windows is running on a hypervisor because Memory integrity is on' 'info' 'Microsoft says this may affect gaming performance. See Tweaks > Security trade-off. Hyper-V, WSL 2 and Virtual Machine Platform keep the hypervisor running too.'
        } elseif ($hv) {
            Add-Item $detected 'Virtualization' 'Windows is running on a hypervisor' 'info' 'Hyper-V, WSL 2 or Virtual Machine Platform is probably on. If you do not use them, turn them off in Turn Windows features on or off.'
        } else {
            Add-Item $detected 'Virtualization' 'No hypervisor running' 'ok'
        }
    } catch {}

    try {
        $sb = Read-RegValue 'HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
        if ($sb.Exists) { Add-Item $detected 'Secure Boot' $(if ([int]$sb.V -eq 1) { 'On' } else { 'Off' }) 'info' }
    } catch {}

    if (-not $ramOk) {
        $where = if ($XmpMenu[$vendor]) { "Usually at $($XmpMenu[$vendor]). " } else { '' }
        Add-Item $manual 'XMP / EXPO / DOCP' 'Enabled' 'todo' "${where}Names vary by board and BIOS version. If the PC will not start afterwards, clear CMOS to go back to the defaults."
    }
    if (-not $rebarOn) {
        $where = if ($RebarMenu[$vendor]) { "Usually at $($RebarMenu[$vendor]). " } else { '' }
        Add-Item $manual 'Re-Size BAR and Above 4G Decoding' 'Enabled' 'todo' "${where}Windows could not confirm this one. It needs UEFI boot mode."
    }
    if ($isX3D) {
        Add-Item $manual 'Global C-state Control' 'Try Enabled instead of Auto' 'todo' 'Usually under AMD CBS > CPU Common Options. Reports say Auto can misbehave on X3D chips, but that is forum evidence, not lab testing. Change only this, then compare in LatencyMon.'
    } else {
        Add-Item $manual 'CPU C-states' 'Try Disabled only if LatencyMon shows spikes' 'todo' 'Waking from deep sleep states takes time, so this can lower latency. It also adds heat and can reduce boost on some CPUs. Forum evidence, not lab testing, so measure before and after.'
    }
    Add-Item $manual 'Unused onboard devices' 'Disable what you do not use' 'todo' 'A second network port, Wi-Fi / Bluetooth, or onboard audio if you use USB audio. Worth doing only if LatencyMon blames one of their drivers.'

    Add-Item $keep 'Secure Boot and TPM' 'Keep on' 'leave' 'No measurable latency cost. Windows 11 and some anti-cheats expect them.'
    Add-Item $keep 'SVM / VT-x (virtualization)' 'Keep on' 'leave' 'It costs nothing by itself. Turning it off also disables Memory integrity and WSL 2 without telling you.'
    Add-Item $keep 'SMT / Hyper-Threading' 'Keep on' 'leave' 'Turning it off rarely helps and costs performance in games that use many threads.'
    if ($isX3D) {
        Add-Item $keep 'Precision Boost Overdrive and overclocking' 'Leave on Auto' 'leave' 'X3D chips have very limited tuning, so these usually add heat, not speed.'
    }

    @{ Board = $boardText; Detected = $detected; Manual = $manual; Keep = $keep }
}

# ------------------------------------------------------------------ worker thread jobs
# Everything here runs on the worker thread and talks to the window only through this queue,
# which the window drains on a timer. Only plain hashtables, arrays and strings cross over.
function Send-Ui($Message) {
    if ($Message.Type -eq 'progress' -and $IloSync.Splash) {   # read directly by the loading screen, even while the window thread is busy
        $IloSync.Splash.Frac = 0.15 + 0.8 * $Message.Done / $Message.Total
        $IloSync.Splash.Text = $Message.Text
    }
    $IloSync.Queue.Enqueue($Message)
}

function Get-PrimaryNic {
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -ne 'Up' -or "$($n.NetworkInterfaceType)" -in 'Loopback', 'Tunnel') { continue }
        foreach ($g in $n.GetIPProperties().GatewayAddresses) {
            if ("$($g.Address.AddressFamily)" -eq 'InterNetwork' -and "$($g.Address)" -ne '0.0.0.0') { return @{ Nic = $n; Gateway = "$($g.Address)" } }
        }
    }
}

# Ten seconds of pings. The verdict thresholds are rules of thumb, not hard limits.
function Invoke-NetTest([string]$Server) {
    $Server = $Server.Trim()
    if ($Server -and $Server -notmatch '^[A-Za-z0-9\.\-:]+$') { throw 'That does not look like a server address. Use an IP address or a host name.' }
    $primary = Get-PrimaryNic
    $targets = @()
    if ($primary) { $targets += @{ Label = 'Your router'; Address = $primary.Gateway } }
    $targets += @{ Label = 'Internet'; Address = '1.1.1.1' }
    if ($Server) { $targets += @{ Label = 'Game server'; Address = $Server } }

    $count = 100
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $stats = if ($primary) { $primary.Nic.GetIPStatistics() } else { $null }
    $down0 = if ($stats) { $stats.BytesReceived } else { 0 }
    $up0   = if ($stats) { $stats.BytesSent } else { 0 }
    $raw = [ILO.NetTest]::Run([string[]]@($targets | ForEach-Object { $_.Address }), $count, 100)
    $seconds = [Math]::Max($clock.Elapsed.TotalSeconds, 1)
    $stats = if ($primary) { $primary.Nic.GetIPStatistics() } else { $null }
    $downMbps = if ($stats) { ($stats.BytesReceived - $down0) * 8 / 1000000 / $seconds } else { 0 }
    $upMbps   = if ($stats) { ($stats.BytesSent - $up0) * 8 / 1000000 / $seconds } else { 0 }

    $rows = @()
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $rows += @{ Label = $targets[$i].Label; Address = $targets[$i].Address; Avg = $raw[$i][0]; Jitter = $raw[$i][1]; Worst = $raw[$i][2]; Lost = [int]$raw[$i][3]; Sent = $count }
    }
    $verdict = Get-NetVerdict ($rows | Where-Object { $_.Label -eq 'Your router' }) ($rows | Where-Object { $_.Label -eq 'Internet' }) ($rows | Where-Object { $_.Label -eq 'Game server' }) $downMbps $upMbps
    @{ Rows = @($rows); Notes = @($verdict.Notes); Clean = $verdict.Clean; DownMbps = $downMbps; UpMbps = $upMbps }
}

function Get-NetVerdict($router, $net, $game, [double]$downMbps, [double]$upMbps) {
    $notes = @()
    $busy = ($upMbps -gt 1 -or $downMbps -gt 5)
    $routerBad = $router -and ($router.Lost -gt 0 -or $router.Worst -gt 20)
    if ($router -and $router.Lost -gt 0) {
        $notes += "Packets are being lost between this PC and your router ($($router.Lost) of $($router.Sent)). That is your cable, Wi-Fi or network adapter, and it hurts hit registration directly. Fix this first."
    } elseif ($router -and $router.Worst -gt 20) {
        $notes += ('Your link to the router spikes up to {0:0} ms, when it should stay under a few ms. That usually means Wi-Fi interference or a busy network.' -f $router.Worst)
    }
    if ($net.Avg -lt 0) {
        $notes += 'The internet test got no replies at all. Check that you are online and that nothing is blocking ping.'
    } else {
        if ($net.Lost -gt 0 -and -not $routerBad) {
            if ($busy) {
                $notes += ('Packets were lost past your router ({0} of {1}) while this PC was moving {2:0.0} Mbps down and {3:0.0} Mbps up. A full connection queues and drops game packets, which is exactly what hurts hit registration. Stop that transfer and test again.' -f $net.Lost, $net.Sent, $downMbps, $upMbps)
            } else {
                $notes += "Packets are being lost past your router ($($net.Lost) of $($net.Sent)) while this PC was quiet, so the cause is the router, your internet provider or other devices on your network."
            }
        }
        if ($net.Jitter -gt 5) {
            $notes += ('Your internet ping moves by about {0:0.0} ms between packets, which is unsteady. Games absorb small changes, but this much can make shots register late. If anyone on your network was downloading or uploading, that is bufferbloat (see Tips).' -f $net.Jitter)
        }
    }
    if ($game -and $game.Avg -lt 0) { $notes += 'The game server did not answer. Many servers block ping, so this does not show a problem by itself.' }
    if ($busy -and -not ($net.Lost -gt 0 -and -not $routerBad)) {
        $notes += ('This PC moved {0:0.0} Mbps down and {1:0.0} Mbps up during the test. Something in the background is using your connection, and a game itself uses far less. Close it and test again.' -f $downMbps, $upMbps)
    }
    $clean = $notes.Count -eq 0
    if ($clean) {
        $notes += 'Clean result: no packet loss and steady ping. If hits still do not register, the cause is more likely your distance from that server, the server itself or the game than this PC.'
    }
    @{ Notes = @($notes); Clean = $clean }
}

function Get-TweakTip($t, [string]$State) {
    switch ($State) {
        'Error'  { return $script:TestErrors[$t.Id] }
        'NA'     { if ($t.NaNote) { return $t.NaNote } else { return 'Not available on this PC or Windows version' } }
        'Custom' { return "You are using a custom plan ($((Get-ActiveScheme).Name)). Keeping it is fine if it is a performance plan; applying switches to Ultimate Performance." }
    }
    return $null
}

function Get-PrioritySnapshot {
    @{
        Priority = @(Get-PriorityEntries | Sort-Object { $_.Exe } | ForEach-Object {
            @{ Exe = $_.Exe; Class = $_.Class; Mine = $script:Backup.priority.ContainsKey($_.Exe) } })
        PriorityBackups = @($script:Backup.priority.Keys)
    }
}

function Get-Snapshot {
    $states = @{}
    $i = 0
    Update-NvCache
    foreach ($t in $Tweaks) {
        Send-Ui @{ Type = 'progress'; Done = $i; Total = $Tweaks.Count; Text = "Checking: $($t.Name)" }
        $s = Test-Tweak $t
        $info = @{ State = $s; HasBackup = $script:Backup.tweaks.ContainsKey($t.Id); Tip = (Get-TweakTip $t $s) }
        $states[$t.Id] = $info
        Send-Ui @{ Type = 'state'; Id = $t.Id; Info = $info }
        $i++
    }
    $script:NvCache = $null
    $snap = Get-PrioritySnapshot
    $snap.States = $states
    $snap.TweakBackups = @($script:Backup.tweaks.Keys)
    $snap.WakeTests = @(Get-WakeHistory)
    $snap
}

function Get-WakeHistory {
    if (-not (Test-Path $WakeFile)) { return }
    try { @(ConvertTo-PlainObject (Get-Content -Path $WakeFile -Raw -Encoding UTF8 | ConvertFrom-Json)) } catch {}
}

function New-RestorePoint {
    Write-Log 'Creating a System Restore point (can take up to a minute)...'
    try {
        $w = $null
        Checkpoint-Computer -Description 'Before Input Latency Optimizer' -RestorePointType 'MODIFY_SETTINGS' -WarningVariable w -WarningAction SilentlyContinue
        if ($w) { Write-Log "Restore point: $($w[0])" } else { Write-Log 'Restore point created.' }
    } catch {
        Write-Log "Could not create a restore point: $($_.Exception.Message) (System Protection may be off for drive C:)."
    }
}

function Invoke-WorkerJob([string]$Kind, $Arg) {
    $result = $null; $failure = $null
    try {
        switch ($Kind) {
            'Status'      { $result = Get-Snapshot }
            'Diagnostics' { $result = @{ Items = @(Get-Diagnostics) } }
            'Bios'        { $result = Get-BiosAudit }
            'RestorePoint' { New-RestorePoint }
            'Apply' {
                if ($Arg.RestorePoint) { New-RestorePoint }
                $ids = @($Arg.Ids); $when = @{}; $ok = 0; $i = 0
                foreach ($id in $ids) {
                    $t = $Tweaks | Where-Object { $_.Id -eq $id }
                    Send-Ui @{ Type = 'progress'; Done = $i; Total = $ids.Count; Text = "Applying: $($t.Name)" }
                    try { if (Invoke-TweakApply $t) { $ok++; $when[$t.When] = $true } }
                    catch { Write-Log "$($t.Name): FAILED - $($_.Exception.Message)" }
                    $i++
                }
                $msg = "$ok change(s) applied."
                if ($when.reboot) { $msg += ' Some of them need a reboot to take effect.' }
                elseif ($when.signout) { $msg += ' Some of them need a sign-out to take effect.' }
                elseif ($when.game) { $msg += ' Restart your game to pick them up.' }
                Write-Log $msg
                $result = Get-Snapshot
            }
            'Revert' {
                $ids = @($Arg.Ids); $n = 0
                for ($i = $ids.Count - 1; $i -ge 0; $i--) {
                    $id = $ids[$i]
                    $t = $Tweaks | Where-Object { $_.Id -eq $id }
                    Send-Ui @{ Type = 'progress'; Done = ($ids.Count - 1 - $i); Total = $ids.Count; Text = "Reverting: $($t.Name)" }
                    try { if (Invoke-TweakRevert $t) { $n++ } }
                    catch { Write-Log "$($t.Name): revert FAILED - $($_.Exception.Message)" }
                }
                Write-Log "$n tweak(s) reverted. Changes marked 'after a reboot' or 'after you sign out' need that again to fully undo."
                $result = Get-Snapshot
            }
            'RestoreAll' {
                $todo = @($Tweaks | Where-Object { $script:Backup.tweaks.ContainsKey($_.Id) })
                for ($i = $todo.Count - 1; $i -ge 0; $i--) {
                    try { [void](Invoke-TweakRevert $todo[$i]) } catch { Write-Log "$($todo[$i].Name): revert FAILED - $($_.Exception.Message)" }
                }
                foreach ($e in @($script:Backup.priority.Keys)) {
                    try { Restore-PriorityBackup $e } catch { Write-Log "$e priority: restore FAILED - $($_.Exception.Message)" }
                }
                Write-Log 'Everything restored. Reboot once so settings that load at startup are back too.'
                $result = Get-Snapshot
            }
            'NetTest'    { $result = Invoke-NetTest ([string]$Arg.Server) }
            'PrioAdd'    { Add-PriorityEntry $Arg.Exe $Arg.Class; $result = Get-PrioritySnapshot }
            'PrioRemove' { Remove-PriorityEntry $Arg.Exe; $result = Get-PrioritySnapshot }
            'WakeTest' {
                $r = [ILO.WakeTest]::Run(1500, [bool]$Arg.Held)
                $entry = @{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Avg = [Math]::Round($r[0], 3); P99 = [Math]::Round($r[1], 3); Worst = [Math]::Round($r[2], 3) }
                $history = @(@($entry) + @(Get-WakeHistory)) | Select-Object -First 6
                if (-not $ReadOnly) {
                    if (-not (Test-Path $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir -Force) }
                    ConvertTo-Json -InputObject @($history) -Depth 4 | Set-Content -Path $WakeFile -Encoding UTF8
                }
                $result = @{ History = @($history) }
            }
            'NvProbe' {
                $lines = @()
                if ([ILO.Nv]::Available()) {
                    foreach ($t in @($Tweaks | Where-Object { $_.Nv })) {
                        foreach ($s in $t.Nv) { $lines += '  NVIDIA unsaved write test {0}: wrote {1}, read back {2}' -f $t.Id, $s.V, [ILO.Nv]::ProbeUnsaved([uint32]$s.Id, [uint32]$s.V) }
                    }
                }
                $result = @{ Lines = $lines }
            }
            default { throw "Unknown job: $Kind" }
        }
    } catch { $failure = $_.Exception.Message }
    Send-Ui @{ Type = 'done'; Kind = $Kind; Result = $result; Error = $failure }
}

# ------------------------------------------------------------------ status mode
if ($Status -or $IsWorker) { Import-Backup }   # the worker owns the backups; the window asks it

if ($IsWorker) { return }   # the worker only needed the definitions above

if ($Status) {
    "$AppName $AppVersion - status (read only)"
    ''
    foreach ($t in $Tweaks) {
        $s = Test-Tweak $t
        $extra = if ($s -eq 'Error') { '   <- ' + $script:TestErrors[$t.Id] } else { '' }
        '{0,-15} {1,-11} {2}{3}' -f $t.Id, $StateStyle[$s][0], $t.Name, $extra
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
        [void]$rowXml.AppendLine("<TextBlock Text=`"$(Esc $c.ToUpperInvariant())`" Style=`"{StaticResource Section}`"/>")
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
    <CubicEase x:Key="Ease" EasingMode="EaseOut"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#15181F"/>
      <Setter Property="BorderBrush" Value="#222733"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="2"/>
      <Setter Property="Padding" Value="16,12"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
      <Style.Triggers>
        <EventTrigger RoutedEvent="MouseEnter">
          <BeginStoryboard><Storyboard>
            <ColorAnimation Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#191D26" Duration="0:0:0.14"/>
            <ColorAnimation Storyboard.TargetProperty="(Border.BorderBrush).(SolidColorBrush.Color)" To="#343C4C" Duration="0:0:0.14"/>
          </Storyboard></BeginStoryboard>
        </EventTrigger>
        <EventTrigger RoutedEvent="MouseLeave">
          <BeginStoryboard><Storyboard>
            <ColorAnimation Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#15181F" Duration="0:0:0.22"/>
            <ColorAnimation Storyboard.TargetProperty="(Border.BorderBrush).(SolidColorBrush.Color)" To="#222733" Duration="0:0:0.22"/>
          </Storyboard></BeginStoryboard>
        </EventTrigger>
      </Style.Triggers>
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
            <Grid x:Name="root" RenderTransformOrigin="0.5,0.5">
              <Grid.RenderTransform><ScaleTransform/></Grid.RenderTransform>
              <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="2"/>
              <Border x:Name="hl" Background="#12FFFFFF" BorderBrush="#5A9BFF" BorderThickness="1" CornerRadius="2" Opacity="0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="MouseEnter">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="hl" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="MouseLeave">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="hl" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2"/>
                  <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.12"/>
                  <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.12"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="PreviewMouseLeftButtonDown">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="0.97" Duration="0:0:0.06"/>
                  <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="0.97" Duration="0:0:0.06"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="PreviewMouseLeftButtonUp">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.14" EasingFunction="{StaticResource Ease}"/>
                  <DoubleAnimation Storyboard.TargetName="root" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.14" EasingFunction="{StaticResource Ease}"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="root" Property="Opacity" Value="0.45"/></Trigger>
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
              <Grid Width="20" Height="20" VerticalAlignment="Top" Margin="0,1,14,0">
                <Border CornerRadius="2" BorderThickness="1.5" BorderBrush="#3A4150" Background="#0D0F13"/>
                <Border x:Name="hl" CornerRadius="2" BorderThickness="1.5" BorderBrush="#5A9BFF" Opacity="0"/>
                <Border x:Name="fill" CornerRadius="2" Background="#2F7BF5" Opacity="0"/>
                <Path x:Name="tick" Data="M 4.5,10 L 8.5,14 L 15.5,5.5" Stroke="White" StrokeThickness="2.2" Opacity="0"
                      StrokeStartLineCap="Square" StrokeEndLineCap="Square" RenderTransformOrigin="0.5,0.5">
                  <Path.RenderTransform><ScaleTransform/></Path.RenderTransform>
                </Path>
              </Grid>
              <ContentPresenter Grid.Column="1" VerticalAlignment="Top"/>
            </Grid>
            <ControlTemplate.Triggers>
              <EventTrigger RoutedEvent="MouseEnter">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="hl" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.12"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <EventTrigger RoutedEvent="MouseLeave">
                <BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="hl" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2"/>
                </Storyboard></BeginStoryboard>
              </EventTrigger>
              <Trigger Property="IsChecked" Value="True">
                <!-- The setters are the resting state; the animations only play the change, then let go. -->
                <Setter TargetName="fill" Property="Opacity" Value="1"/>
                <Setter TargetName="tick" Property="Opacity" Value="1"/>
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard FillBehavior="Stop">
                    <DoubleAnimation Storyboard.TargetName="fill" Storyboard.TargetProperty="Opacity" From="0" To="1" Duration="0:0:0.12"/>
                    <DoubleAnimation Storyboard.TargetName="tick" Storyboard.TargetProperty="Opacity" From="0" To="1" Duration="0:0:0.12"/>
                    <DoubleAnimation Storyboard.TargetName="tick" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="0.4" To="1" Duration="0:0:0.16" EasingFunction="{StaticResource Ease}"/>
                    <DoubleAnimation Storyboard.TargetName="tick" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" From="0.4" To="1" Duration="0:0:0.16" EasingFunction="{StaticResource Ease}"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard FillBehavior="Stop">
                    <DoubleAnimation Storyboard.TargetName="fill" Storyboard.TargetProperty="Opacity" From="1" To="0" Duration="0:0:0.12"/>
                    <DoubleAnimation Storyboard.TargetName="tick" Storyboard.TargetProperty="Opacity" From="1" To="0" Duration="0:0:0.1"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
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
              <ContentPresenter x:Name="PART_Body" ContentSource="SelectedContent" TextElement.Foreground="#E6E8ED"/>
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
            <Grid Margin="0,0,4,-1" Background="Transparent" Cursor="Hand">
              <ContentPresenter Margin="14,8,14,10" ContentSource="Header" TextElement.Foreground="{TemplateBinding Foreground}" TextElement.FontWeight="SemiBold"/>
              <Rectangle x:Name="ul" Height="2" VerticalAlignment="Bottom" Fill="#3D8BFF" Opacity="0" RenderTransformOrigin="0.5,0.5">
                <Rectangle.RenderTransform><ScaleTransform/></Rectangle.RenderTransform>
              </Rectangle>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ul" Property="Opacity" Value="1"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard FillBehavior="Stop">
                    <DoubleAnimation Storyboard.TargetName="ul" Storyboard.TargetProperty="Opacity" From="0" To="1" Duration="0:0:0.1"/>
                    <DoubleAnimation Storyboard.TargetName="ul" Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" From="0.2" To="1" Duration="0:0:0.22" EasingFunction="{StaticResource Ease}"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard FillBehavior="Stop">
                    <DoubleAnimation Storyboard.TargetName="ul" Storyboard.TargetProperty="Opacity" From="1" To="0" Duration="0:0:0.14"/>
                  </Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
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
        <Grid Width="180" Height="3" HorizontalAlignment="Right" Margin="0,5,0,0">
          <Border Background="#222733"/>
          <Border Background="#3DDC84" RenderTransformOrigin="0,0.5">
            <Border.RenderTransform><ScaleTransform x:Name="sumScale" ScaleX="0"/></Border.RenderTransform>
          </Border>
        </Grid>
        <TextBlock x:Name="txtAdmin" Foreground="{StaticResource Muted}" HorizontalAlignment="Right" Margin="0,5,0,0"/>
      </StackPanel>
    </Grid>

    <Grid x:Name="busyTrack" Grid.Row="1" Height="2" VerticalAlignment="Top" Margin="24,6,24,0" Opacity="0" IsHitTestVisible="False" Panel.ZIndex="1">
      <Border Background="#222733"/>
      <Border Background="#3D8BFF" RenderTransformOrigin="0,0.5">
        <Border.RenderTransform><ScaleTransform x:Name="busyScale" ScaleX="0"/></Border.RenderTransform>
      </Border>
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
          <ScrollViewer x:Name="svTweaks" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="pnlTweaks" Margin="0,0,12,12">
__ROWS__
            </StackPanel>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem x:Name="tabLive" Header="Live tools">
        <ScrollViewer x:Name="svLive" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Margin="0,0,12,0">
            <Border Style="{StaticResource Card}" Padding="18,16">
              <StackPanel>
                <TextBlock Text="Connection test (hit registration)" Style="{StaticResource H2}"/>
                <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Muted}"
                           Text="The game server decides what hits, using your ping and how steadily your packets arrive. This sends 100 pings over 10 seconds to your router and the internet, and tells you where any loss or instability sits. To test the route to your game, add its server address."/>
                <Grid Margin="0,12,0,0">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <TextBox x:Name="txtNetServer" Style="{StaticResource Input}" Margin="0,0,8,0"/>
                  <TextBlock Text="Game server address (optional)" Foreground="{StaticResource Dim}" IsHitTestVisible="False" VerticalAlignment="Center" Margin="11,0,0,0">
                    <TextBlock.Style>
                      <Style TargetType="TextBlock">
                        <Setter Property="Visibility" Value="Collapsed"/>
                        <Style.Triggers><DataTrigger Binding="{Binding Text, ElementName=txtNetServer}" Value=""><Setter Property="Visibility" Value="Visible"/></DataTrigger></Style.Triggers>
                      </Style>
                    </TextBlock.Style>
                  </TextBlock>
                  <Button x:Name="btnNet" Grid.Column="1" Content="Run test (10 seconds)" Style="{StaticResource BtnPrimary}" Margin="0"/>
                </Grid>
                <TextBlock x:Name="txtNet" Text="No runs yet." FontFamily="Consolas" Foreground="{StaticResource Fg}" Margin="0,10,0,0"/>
                <TextBlock x:Name="txtNetVerdict" TextWrapping="Wrap" Foreground="#C9CDD6" Margin="0,8,0,0"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Padding="18,16">
              <StackPanel>
                <TextBlock Text="Wake-up test" Style="{StaticResource H2}"/>
                <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Muted}"
                           Text="Measures how late Windows wakes a thread that asked to sleep 1 ms, the way a game's frame limiter does. Lower and steadier is better, and the worst value shows hitches. This is one part of latency, not your full input-to-screen delay. Run it before and after a change, with the same apps open."/>
                <TextBlock x:Name="txtWake" Text="No runs yet." FontFamily="Consolas" Foreground="{StaticResource Fg}" Margin="0,10,0,0"/>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                  <Button x:Name="btnWake" Content="Run test (about 3 seconds)" Style="{StaticResource BtnPrimary}"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Padding="18,16">
              <StackPanel>
                <TextBlock Text="Mouse polling test" Style="{StaticResource H2}"/>
                <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Muted}"
                           Text="Press start, then move your mouse in fast circles for a few seconds. The peak shows the rate your mouse really reports at. Keep this window focused while testing."/>
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                  <TextBlock x:Name="txtPoll" Text="-" FontFamily="Consolas" FontSize="26" FontWeight="Bold" Foreground="{StaticResource Fg}"/>
                  <TextBlock x:Name="txtPollSub" Foreground="{StaticResource Muted}" VerticalAlignment="Bottom" Margin="14,0,0,5"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                  <Button x:Name="btnPoll" Content="Start test" Style="{StaticResource BtnPrimary}"/>
                </StackPanel>
              </StackPanel>
            </Border>
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
                  <TextBlock Text="Program name, for example cs2.exe" Foreground="{StaticResource Dim}" IsHitTestVisible="False" VerticalAlignment="Center" Margin="11,0,0,0">
                    <TextBlock.Style>
                      <Style TargetType="TextBlock">
                        <Setter Property="Visibility" Value="Collapsed"/>
                        <Style.Triggers><DataTrigger Binding="{Binding Text, ElementName=txtExe}" Value=""><Setter Property="Visibility" Value="Visible"/></DataTrigger></Style.Triggers>
                      </Style>
                    </TextBlock.Style>
                  </TextBlock>
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

      <TabItem x:Name="tabBios" Header="BIOS check">
        <DockPanel>
          <Border DockPanel.Dock="Top" Style="{StaticResource Card}" Padding="18,14">
            <DockPanel>
              <Button x:Name="btnBiosReboot" DockPanel.Dock="Right" Content="Restart into BIOS" Style="{StaticResource Btn}" Margin="16,0,0,0" VerticalAlignment="Center"/>
              <StackPanel>
                <TextBlock x:Name="txtBiosBoard" Text="Checking..." Style="{StaticResource H2}"/>
                <TextBlock TextWrapping="Wrap" Foreground="{StaticResource Muted}"
                           Text="Read-only. BIOS settings cannot be changed safely from Windows: they are stored in a board-specific format, and a wrong value can stop the PC from booting. So this page reports what Windows can see and lists the rest for you to change by hand."/>
              </StackPanel>
            </DockPanel>
          </Border>
          <ScrollViewer x:Name="svBios" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="pnlBios" Margin="0,0,12,0"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem x:Name="tabDiag" Header="Diagnostics">
        <DockPanel>
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
            <Button x:Name="btnDiag" Content="Run checks again" Style="{StaticResource Btn}" DockPanel.Dock="Left"/>
            <TextBlock Text="Read-only checks. Nothing on this page changes your PC." Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="6,0,0,0"/>
          </DockPanel>
          <ScrollViewer x:Name="svDiag" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="pnlDiag" Margin="0,0,12,0"/>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem Header="Tips">
        <ScrollViewer x:Name="svTips" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
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

# ------------------------------------------------------------------ loading screen
# Runs on its own thread with its own message loop, so it keeps animating while the main thread
# parses the big window. Built in code because the XAML parser costs over a second on first use.
# It only reads $IloSplash, a shared table the app writes progress into.
$script:SplashScript = @'
function Brush([string]$Hex) {
    $b = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    $b
}
function Label([string]$Value, [double]$Size, [string]$Color) {
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Value; $t.FontSize = $Size; $t.Foreground = Brush $Color
    $t
}
function Ms([int]$Value) { [TimeSpan]::FromMilliseconds($Value) }

$ease = [System.Windows.Media.Animation.CubicEase]::new()
$ease.EasingMode = 'EaseOut'
$ease.Freeze()
function Anim($Target, $Property, [double]$To, [int]$Length, [scriptblock]$Done) {
    $a = [System.Windows.Media.Animation.DoubleAnimation]::new()
    $a.To = $To
    $a.Duration = [System.Windows.Duration]::new((Ms $Length))
    $a.EasingFunction = $ease
    if ($Done) { $a.Add_Completed($Done) }
    $Target.BeginAnimation($Property, $a)
}
$opacity = [System.Windows.UIElement]::OpacityProperty

$w = [System.Windows.Window]::new()
$w.Title = 'Input Latency Optimizer'
$w.Width = 500; $w.Height = 236
$w.WindowStyle = 'None'; $w.ResizeMode = 'NoResize'
$w.AllowsTransparency = $true
$w.Background = [System.Windows.Media.Brushes]::Transparent
$w.WindowStartupLocation = 'CenterScreen'
$w.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
$w.UseLayoutRounding = $true
[System.Windows.Media.TextOptions]::SetTextFormattingMode($w, 'Display')

$root = [System.Windows.Controls.Border]::new()
$root.Background = Brush '#0D0F13'
$root.BorderBrush = Brush '#2A303C'
$root.BorderThickness = [System.Windows.Thickness]::new(1)
$root.Padding = [System.Windows.Thickness]::new(32, 28, 32, 28)
$root.Opacity = 0
$move = [System.Windows.Media.TranslateTransform]::new(0, 10)
$root.RenderTransform = $move

$dock = [System.Windows.Controls.DockPanel]::new()
$top = [System.Windows.Controls.StackPanel]::new()
$title = Label 'INPUT LATENCY OPTIMIZER' 20 '#E6E8ED'
$title.FontWeight = [System.Windows.FontWeights]::Bold
$version = Label "Version $($IloSplash.Version)" 13 '#8A92A3'
$version.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
[void]$top.Children.Add($title)
[void]$top.Children.Add($version)
[System.Windows.Controls.DockPanel]::SetDock($top, 'Top')
[void]$dock.Children.Add($top)

$bottom = [System.Windows.Controls.StackPanel]::new()
$line = [System.Windows.Controls.DockPanel]::new()
$pct = Label '0%' 13 '#8A92A3'
$pct.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
[System.Windows.Controls.DockPanel]::SetDock($pct, 'Right')
$step = Label $IloSplash.Text 13 '#8A92A3'
$step.TextTrimming = 'CharacterEllipsis'
[void]$line.Children.Add($pct)
[void]$line.Children.Add($step)
$track = [System.Windows.Controls.Grid]::new()
$track.Height = 3
$track.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
$rail = [System.Windows.Controls.Border]::new()
$rail.Background = Brush '#222733'
$fill = [System.Windows.Controls.Border]::new()
$fill.Background = Brush '#3D8BFF'
$fill.RenderTransformOrigin = [System.Windows.Point]::new(0, 0.5)
$scale = [System.Windows.Media.ScaleTransform]::new(0, 1)
$fill.RenderTransform = $scale
[void]$track.Children.Add($rail)
[void]$track.Children.Add($fill)
[void]$bottom.Children.Add($line)
[void]$bottom.Children.Add($track)
[System.Windows.Controls.DockPanel]::SetDock($bottom, 'Bottom')
[void]$dock.Children.Add($bottom)

# A row of squares that light up in turn.
$row = [System.Windows.Controls.StackPanel]::new()
$row.Orientation = 'Horizontal'
$row.VerticalAlignment = 'Center'
$board = [System.Windows.Media.Animation.Storyboard]::new()
$accent = Brush '#3D8BFF'
for ($i = 0; $i -lt 16; $i++) {
    $sq = [System.Windows.Shapes.Rectangle]::new()
    $sq.Width = 14; $sq.Height = 14
    $sq.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $sq.Fill = $accent
    $sq.Opacity = 0.14
    [void]$row.Children.Add($sq)
    $keys = [System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
    $keys.BeginTime = Ms ($i * 55)
    [void]$keys.KeyFrames.Add([System.Windows.Media.Animation.LinearDoubleKeyFrame]::new(1, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan((Ms 100))))
    [void]$keys.KeyFrames.Add([System.Windows.Media.Animation.LinearDoubleKeyFrame]::new(0.14, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan((Ms 500))))
    [System.Windows.Media.Animation.Storyboard]::SetTarget($keys, $sq)
    [System.Windows.Media.Animation.Storyboard]::SetTargetProperty($keys, [System.Windows.PropertyPath]::new('Opacity'))
    $board.Children.Add($keys)
}
$board.Duration = [System.Windows.Duration]::new((Ms 1500))
$board.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
[void]$dock.Children.Add($row)

$root.Child = $dock
$w.Content = $root
$w.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

$global:ShownFrac = -1.0
$global:Closing = $false
$poll = [System.Windows.Threading.DispatcherTimer]::new()
$poll.Interval = Ms 40
$poll.Add_Tick({
    if ($IloSplash.Close) {
        if (-not $global:Closing) {
            $global:Closing = $true
            $poll.Stop()
            $w.Topmost = $true
            Anim $root $opacity 0 220 { $w.Close() }
        }
        return
    }
    $f = [double]$IloSplash.Frac
    if ($f -ne $global:ShownFrac) {
        $global:ShownFrac = $f
        $pct.Text = '{0:0}%' -f ($f * 100)
        Anim $scale ([System.Windows.Media.ScaleTransform]::ScaleXProperty) $f 220 $null
    }
    if ($step.Text -cne $IloSplash.Text) { $step.Text = $IloSplash.Text }
})

$w.Show()
Anim $root $opacity 1 220 $null
Anim $move ([System.Windows.Media.TranslateTransform]::YProperty) 0 280 $null
$board.Begin()
$poll.Start()
[System.Windows.Threading.Dispatcher]::Run()
'@

function Start-Splash {
    $script:SplashState = [hashtable]::Synchronized(@{ Frac = 0.05; Text = 'Starting...'; Close = $false; Version = $AppVersion })
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::Create()   # empty: it only needs .NET, and opens fast
    $iss.LanguageMode = 'FullLanguage'
    $iss.Variables.Add([System.Management.Automation.Runspaces.SessionStateVariableEntry]::new('IloSplash', $script:SplashState, ''))
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:SplashScript)
    [void]$ps.BeginInvoke()
    $script:SplashPs = $ps   # stays referenced, or the garbage collector could end it early
}

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

function Invoke-Anim($Target, $Property, [double]$To, [int]$Ms = 180, $From = $null, [int]$DelayMs = 0, [scriptblock]$OnDone = $null) {
    if ($script:Headless) { return }
    $a = [System.Windows.Media.Animation.DoubleAnimation]::new()
    $a.To = $To
    if ($null -ne $From) { $a.From = [double]$From }
    $a.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($Ms))
    if ($DelayMs -gt 0) { $a.BeginTime = [TimeSpan]::FromMilliseconds($DelayMs) }
    $a.EasingFunction = $script:EaseOut
    if ($OnDone) { $a.Add_Completed($OnDone) }
    $Target.BeginAnimation($Property, $a)
}

# Fades and slides a list of elements in, one shortly after the other.
function Invoke-Stagger($Elements, [int]$StepMs = 16, [int]$MaxDelayMs = 300) {
    if ($script:Headless) { return }
    $i = 0
    foreach ($el in @($Elements)) {
        $delay = [Math]::Min($i * $StepMs, $MaxDelayMs)
        $move = [System.Windows.Media.TranslateTransform]::new(0, 8)
        $el.Opacity = 0
        $el.RenderTransform = $move
        Invoke-Anim $el $OpacityDp 1 200 0 $delay
        Invoke-Anim $move $MoveYDp 0 240 8 $delay
        $i++
    }
}

function Show-Message([string]$Text, [string]$Icon = 'Information') {
    if ($script:Headless) { Write-Host "[$Icon] $Text"; return }
    if ($script:MainShown) { [void][System.Windows.MessageBox]::Show($window, $Text, $AppName, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]$Icon) }
    else { [void][System.Windows.MessageBox]::Show($Text, $AppName, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]$Icon) }
}

function Confirm-Action([string]$Text) {
    $r = [System.Windows.MessageBox]::Show($window, $Text, $AppName, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    return ($r -eq [System.Windows.MessageBoxResult]::Yes)
}

function Invoke-Safe([scriptblock]$Action) {
    try { & $Action }
    catch {
        Write-Log "Error: $($_.Exception.Message)"
        Show-Message $_.Exception.Message 'Warning'
    }
}

# ------------------------------------------------------------------ worker thread
function Start-Worker {
    $script:Sync = [hashtable]::Synchronized(@{ Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'; Splash = $script:SplashState })
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
    foreach ($v in @(@('IloSync', $script:Sync), @('IloPath', $PSCommandPath), @('IloReadOnly', $ReadOnly))) {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry $v[0], $v[1], ''))
    }
    $script:WorkerRs = [runspacefactory]::CreateRunspace($iss)
    $script:WorkerRs.ApartmentState = 'STA'
    $script:WorkerRs.ThreadOptions = 'ReuseThread'
    $script:WorkerRs.Open()
    $script:JobQueue = New-Object System.Collections.Queue
    $script:Running = $null
    if (-not $script:Headless) {
        $script:Pump = New-Object System.Windows.Threading.DispatcherTimer
        $script:Pump.Interval = [TimeSpan]::FromMilliseconds(30)
        $script:Pump.Add_Tick({
            try { Invoke-Pump }
            catch {
                if ($script:MainShown) { Write-Log "Error: $($_.Exception.Message)" }
                else { $script:Pump.Stop(); Stop-WithError $_.Exception.Message }
            }
        })
    }
}

# Busy jobs change the PC, so the action buttons wait for them. Only one job runs at a time.
function Add-Work([string]$Kind, $Arg = $null, [scriptblock]$OnDone = $null, [switch]$Busy) {
    $script:JobQueue.Enqueue(@{ Kind = $Kind; Arg = $Arg; OnDone = $OnDone; Busy = [bool]$Busy })
    if ($Busy -and $script:MainShown) { foreach ($n in $ActionButtons) { $ui[$n].IsEnabled = $false } }   # before a double-click can queue it twice
    if ($script:Pump -and -not $script:Pump.IsEnabled) { $script:Pump.Start() }
}

function Start-NextJob {
    $state = $script:WorkerRs.RunspaceStateInfo
    if ($state.State -eq 'Broken') { $script:JobQueue.Clear(); throw "The background thread could not start: $($state.Reason)" }
    if ($state.State -ne 'Opened') { return }
    $job = $script:JobQueue.Dequeue()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $script:WorkerRs
    if ($job.Kind -eq 'Startup') {
        [void]$ps.AddScript('try { . $IloPath -Library; Invoke-WorkerJob "Status" $null } catch { $IloSync.Queue.Enqueue(@{ Type = "done"; Kind = "Startup"; Error = "$($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" }) }')
    } else {
        [void]$ps.AddScript('param($k, $a) Invoke-WorkerJob $k $a').AddArgument($job.Kind).AddArgument($job.Arg)
    }
    $job.Ps = $ps
    $script:Running = $job
    Set-Working $job
    [void]$ps.BeginInvoke()
}

function Invoke-Pump {
    if ($null -eq $script:Running -and $script:JobQueue.Count -gt 0) { Start-NextJob }
    $m = $null; $n = 0
    while ($n -lt 200 -and $script:Sync.Queue.TryDequeue([ref]$m)) {
        $n++
        switch ($m.Type) {
            'log'      { Write-UiLog $m.Text }
            'state'    { Set-RowState $m.Id $m.Info }
            'progress' { Set-JobProgress $m }
            'done'     { Complete-Job $m }
        }
    }
    if ($script:Running -and $script:Running.Ps.InvocationStateInfo.State -in 'Failed', 'Stopped' -and $script:Sync.Queue.IsEmpty) {
        Complete-Job @{ Type = 'done'; Kind = $script:Running.Kind; Error = "The background job stopped: $($script:Running.Ps.InvocationStateInfo.Reason)" }
    }
    if ($script:Pump -and $null -eq $script:Running -and $script:JobQueue.Count -eq 0 -and $script:Sync.Queue.IsEmpty) { $script:Pump.Stop() }
}

function Complete-Job($Message) {
    $job = $script:Running
    $script:Running = $null
    if ($null -eq $job) { return }
    try { $job.Ps.Dispose() } catch {}
    Set-Idle $job
    if ($Message.Error -and $job.Kind -ne 'Startup') {
        Write-UiLog "Error: $($Message.Error)"
        Show-Message $Message.Error 'Warning'
    }
    if ($job.OnDone) {
        try { & $job.OnDone $Message }
        catch { Write-UiLog "Error: $($_.Exception.Message)"; Show-Message $_.Exception.Message 'Warning' }
    }
}

# Used only without a message loop (-SelfTest).
function Wait-Work {
    while ($script:Running -or $script:JobQueue.Count -gt 0 -or -not $script:Sync.Queue.IsEmpty) {
        Invoke-Pump
        Start-Sleep -Milliseconds 20
    }
}

function Write-UiLog([string]$Line) {
    if ($script:LogBox) {
        $script:LogBox.AppendText($Line + [Environment]::NewLine)
        $script:LogBox.ScrollToEnd()
    } else { $script:EarlyLog += $Line }
}

# ------------------------------------------------------------------ progress and row state
$ActionButtons = 'btnApply', 'btnRevert', 'btnRestoreAll', 'btnRestorePoint', 'btnRecommended', 'btnNone', 'btnPrioHigh', 'btnPrioAbove', 'btnPrioRemove'

function Set-Working($Job) {
    if (-not $script:MainShown) { return }
    Invoke-Anim $ui.busyTrack $OpacityDp 1 140
    $ui.busyScale.BeginAnimation($ScaleXDp, $null)
    $ui.busyScale.ScaleX = 0
    Invoke-Anim $ui.busyScale $ScaleXDp 0.3 400
}

function Set-Idle($Job) {
    if (-not $script:MainShown) { return }
    if (@($script:JobQueue.ToArray() | Where-Object { $_.Busy }).Count -eq 0) { foreach ($n in $ActionButtons) { $ui[$n].IsEnabled = $true } }
    if ($script:JobQueue.Count -gt 0) { return }
    Invoke-Anim $ui.busyScale $ScaleXDp 1 160
    Invoke-Anim $ui.busyTrack $OpacityDp 0 260 $null 180
}

function Set-JobProgress($Message) {
    if (-not $script:MainShown) { return }   # the loading screen gets this directly from the worker
    $f = if ($Message.Total) { [double]$Message.Done / $Message.Total } else { 0.0 }
    Invoke-Anim $ui.busyScale $ScaleXDp ([Math]::Max($f, 0.05)) 200
}

function Set-RowState([string]$Id, $Info) {
    $prev = $script:LastState[$Id]
    $hadBackup = $script:HasBackup[$Id]
    $key = "$($Info.State)|$($Info.HasBackup)|$($Info.Tip)"
    $script:LastState[$Id] = $Info.State
    $script:HasBackup[$Id] = [bool]$Info.HasBackup
    $r = $script:Rows[$Id]
    if ($null -eq $r -or $r.Key -eq $key) { return }   # unchanged rows cost nothing
    $r.Key = $key
    $st = $StateStyle[$Info.State]
    $r.Status.Text = $st[0]
    $r.Pill.Background = Get-Brush $st[1]
    $r.Status.Foreground = Get-Brush $st[2]
    $r.Pill.ToolTip = $Info.Tip
    $r.Meta.Text = Get-MetaText $script:TweakById[$Id] ([bool]$Info.HasBackup)
    $r.Check.IsEnabled = ($Info.State -ne 'NA')
    if ($Info.State -eq 'NA') { $r.Check.IsChecked = $false }
    if ($script:MainShown -and $prev -and $prev -ne $Info.State) { Invoke-Anim $r.Pill $OpacityDp 1 280 0.15 }
}

function Update-Snapshot($Snap) {
    if ($null -eq $Snap) { return }
    $active = 0; $avail = 0
    foreach ($id in @($Snap.States.Keys)) {
        $info = $Snap.States[$id]
        Set-RowState $id $info
        if ($info.State -ne 'NA') { $avail++ }
        if ($info.State -eq 'Applied') { $active++ }
    }
    $ui.txtSummary.Text = "$active / $avail tweaks active"
    if ($avail -gt 0) {
        if ($script:Headless) { $ui.sumScale.ScaleX = $active / $avail }
        else { Invoke-Anim $ui.sumScale $ScaleXDp ($active / $avail) 420 }
    }
    $script:TweakBackups = @($Snap.TweakBackups)
    Update-PriorityList $Snap
    Update-TimerNote
    if ($Snap.ContainsKey('WakeTests')) { Show-WakeResults @($Snap.WakeTests) }
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

# ------------------------------------------------------------------ actions
function Invoke-ApplySelected {
    $picked = @(Get-SelectedTweaks)
    if ($picked.Count -eq 0) { Show-Message 'Tick the tweaks you want first, or press "Select recommended".'; return }
    $sel = @()
    foreach ($t in $picked) {
        if ($t.Confirm -and $script:LastState[$t.Id] -ne 'Applied' -and -not (Confirm-Action $t.Confirm)) {
            $script:Rows[$t.Id].Check.IsChecked = $false
            Write-Log "$($t.Name): skipped"
            continue
        }
        $sel += $t
    }
    if ($sel.Count -eq 0) { return }
    $restorePoint = $false
    if (-not $script:AskedRestorePoint) {
        $r = [System.Windows.MessageBox]::Show($window,
            "Create a System Restore point first?`n`nThis app also backs up every value it changes, so you can undo everything from here either way.",
            $AppName, [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Question)
        if ($r -eq [System.Windows.MessageBoxResult]::Cancel) { return }
        $script:AskedRestorePoint = $true
        $restorePoint = ($r -eq [System.Windows.MessageBoxResult]::Yes)
    }
    foreach ($t in $sel) { $script:Rows[$t.Id].Check.IsChecked = $false }
    Add-Work 'Apply' @{ Ids = @($sel | ForEach-Object { $_.Id }); RestorePoint = $restorePoint } { param($m) Update-Snapshot $m.Result } -Busy
}

function Invoke-RevertSelected {
    $sel = @(Get-SelectedTweaks)   # @() keeps one selected tweak an array, not a bare hashtable
    if ($sel.Count -eq 0) { Show-Message 'Tick the tweaks you want to undo first.'; return }
    foreach ($t in $sel) { $script:Rows[$t.Id].Check.IsChecked = $false }
    Add-Work 'Revert' @{ Ids = @($sel | ForEach-Object { $_.Id }) } { param($m) Update-Snapshot $m.Result } -Busy
}

function Invoke-RestoreEverything {
    $nTweaks = @($script:TweakBackups).Count
    $nExes = @($script:PriorityBackups).Count
    if ($nTweaks + $nExes -eq 0) { Show-Message 'Nothing to restore - there are no saved backups.'; return }
    if (-not (Confirm-Action "Put back the original value of everything this app changed?`n`n$nTweaks tweak(s) and $nExes program priority setting(s).")) { return }
    Add-Work 'RestoreAll' $null { param($m) Update-Snapshot $m.Result } -Busy
}

function Update-PriorityList($Snap) {
    $script:PriorityBackups = @($Snap.PriorityBackups)
    $script:PrioEntries = @($Snap.Priority)
    $ui.lstPrio.Items.Clear()
    foreach ($e in $script:PrioEntries) {
        $who = if ($e.Mine) { '' } else { '    (set by another tool)' }
        [void]$ui.lstPrio.Items.Add(('{0,-34} {1}{2}' -f $e.Exe, (Get-PriorityName $e.Class), $who))
    }
}

function Add-Priority([int]$Class) {
    Add-Work 'PrioAdd' @{ Exe = $ui.txtExe.Text; Class = $Class } {
        param($m)
        if (-not $m.Error) { $ui.txtExe.Text = ''; Update-PriorityList $m.Result }
    } -Busy
}

function Remove-SelectedPriority {
    $i = $ui.lstPrio.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:PrioEntries.Count) { Show-Message 'Pick a program in the list first.'; return }
    $e = $script:PrioEntries[$i]
    if (-not $e.Mine -and -not (Confirm-Action "$($e.Exe) was set by another tool, so this app has no backup of it and cannot put it back. Remove it anyway?")) { return }
    Add-Work 'PrioRemove' @{ Exe = $e.Exe } { param($m) if (-not $m.Error) { Update-PriorityList $m.Result } } -Busy
}

# ------------------------------------------------------------------ live tools
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
        $script:HoldTimer.Stop()
        [void](Set-TimerHold $false)
        $script:TimerHeld = $false
        $ui.btnTimer.Content = 'Hold finest timer resolution'
        Write-Log 'Timer resolution released.'
    } else {
        $got = Set-TimerHold $true
        $script:TimerHeld = $true
        $script:HoldTimer.Start()
        $ui.btnTimer.Content = 'Release timer resolution'
        Write-Log ('Holding timer resolution at {0:0.###} ms while this app is open.' -f $got)
    }
    Update-TimerText
}

function Show-WakeResults($History) {
    $runs = @($History)
    if ($runs.Count -eq 0) { $ui.txtWake.Text = 'No runs yet.'; return }
    $lines = @('{0,-18} {1,8} {2,8} {3,8}' -f 'Run', 'Average', '99%', 'Worst')
    foreach ($r in $runs) { $lines += '{0,-18} {1,8:0.00} {2,8:0.00} {3,8:0.00}' -f $r.Time, $r.Avg, $r.P99, $r.Worst }
    $ui.txtWake.Text = ($lines -join [Environment]::NewLine) + [Environment]::NewLine + 'All values in milliseconds. The target is 1.00.'
    if ($script:MainShown) { Invoke-Anim $ui.txtWake $OpacityDp 1 240 0.2 }
}

function Start-WakeTest {
    $ui.btnWake.IsEnabled = $false
    $ui.btnTimer.IsEnabled = $false   # the hold must not change while the test measures it
    $ui.btnWake.Content = 'Measuring...'
    Add-Work 'WakeTest' @{ Held = [bool]$script:TimerHeld } {
        param($m)
        $ui.btnWake.IsEnabled = $true
        $ui.btnTimer.IsEnabled = $true
        $ui.btnWake.Content = 'Run test (about 3 seconds)'
        if (-not $m.Error) { Show-WakeResults @($m.Result.History) }
    }
}

function Show-NetResults($Result) {
    $lines = @('{0,-14} {1,8} {2,8} {3,8} {4,6}' -f 'Target', 'Average', 'Jitter', 'Worst', 'Lost')
    foreach ($r in @($Result.Rows)) {
        if ($r.Avg -lt 0) { $lines += '{0,-14} {1,8} {2,8} {3,8} {4,6}' -f $r.Label, '-', '-', '-', "$($r.Lost)%" }
        else { $lines += '{0,-14} {1,8:0.0} {2,8:0.0} {3,8:0.0} {4,6}' -f $r.Label, $r.Avg, $r.Jitter, $r.Worst, "$($r.Lost)%" }
    }
    $ui.txtNet.Text = ($lines -join [Environment]::NewLine) + [Environment]::NewLine + ('Times in milliseconds. Background traffic during the test: {0:0.0} Mbps down, {1:0.0} Mbps up.' -f $Result.DownMbps, $Result.UpMbps)
    $ui.txtNetVerdict.Text = @($Result.Notes) -join ([Environment]::NewLine + [Environment]::NewLine)
    $ui.txtNetVerdict.Foreground = Get-Brush $(if ($Result.Clean) { '#3DDC84' } else { '#F2B33D' })
    if ($script:MainShown) {
        Invoke-Anim $ui.txtNet $OpacityDp 1 240 0.2
        Invoke-Anim $ui.txtNetVerdict $OpacityDp 1 280 0
    }
}

function Start-NetTest {
    $ui.btnNet.IsEnabled = $false
    $ui.btnNet.Content = 'Testing...'
    Add-Work 'NetTest' @{ Server = $ui.txtNetServer.Text } {
        param($m)
        $ui.btnNet.IsEnabled = $true
        $ui.btnNet.Content = 'Run test (10 seconds)'
        if (-not $m.Error) { Show-NetResults $m.Result }
    }
}

function Stop-PollTest {
    if (-not $script:PollOn) { return }
    $script:PollOn = $false
    $script:PollTimer.Stop()
    [ILO.MousePoll]::Stop()
    $ui.btnPoll.Content = 'Start test'
    if ($script:PollPeak -lt 30) {
        $ui.txtPoll.Text = '-'
        $ui.txtPollSub.Text = 'No mouse movement seen. Keep this window focused and move the mouse in fast circles.'
        return
    }
    $rates = 125, 250, 500, 1000, 2000, 4000, 8000
    $near = $rates | Sort-Object { [Math]::Abs($_ - $script:PollPeak) } | Select-Object -First 1
    $ui.txtPoll.Text = '{0:0} Hz' -f $script:PollPeak
    $ui.txtPollSub.Text = "peak     |     your mouse looks set to $near Hz"
    Write-Log ("Mouse polling test: peak {0:0} Hz, looks set to {1} Hz." -f $script:PollPeak, $near)
}

function Update-PollTest {
    $now = $script:PollClock.Elapsed.TotalSeconds
    $count = [ILO.MousePoll]::Reports
    $dt = $now - $script:PollLastTime
    if ($dt -gt 0) {
        $hz = ($count - $script:PollLastCount) / $dt
        if ($hz -gt $script:PollPeak) { $script:PollPeak = $hz }
        $ui.txtPoll.Text = '{0:0} Hz' -f $hz
        $ui.txtPollSub.Text = 'now     |     peak {0:0} Hz     |     {1:0} s left' -f $script:PollPeak, [Math]::Max(0, 10 - $now)
    }
    $script:PollLastTime = $now
    $script:PollLastCount = $count
    if ($now -ge 10) { Stop-PollTest }
}

function Switch-PollTest {
    if ($script:PollOn) { Stop-PollTest; return }
    if (-not [ILO.MousePoll]::Start($window)) { throw 'Windows would not start raw mouse input for this test.' }
    $script:PollOn = $true
    $script:PollPeak = 0.0
    $script:PollClock = [System.Diagnostics.Stopwatch]::StartNew()
    $script:PollLastTime = 0.0
    $script:PollLastCount = [ILO.MousePoll]::Reports
    $ui.btnPoll.Content = 'Stop test'
    $ui.txtPoll.Text = '0 Hz'
    $ui.txtPollSub.Text = 'Move the mouse in fast circles now'
    $script:PollTimer.Start()
}

# ------------------------------------------------------------------ cards
function New-DiagCard($Item) {
    $color = switch ($Item.Level) { 'ok' { '#3DDC84' } 'warn' { '#F2B33D' } 'bad' { '#F06565' } 'leave' { '#5D6575' } default { '#6AA9FF' } }
    $card = [System.Windows.Controls.Border]::new()
    $card.Style = $window.FindResource('Card')
    $dock = [System.Windows.Controls.DockPanel]::new()
    $mark = [System.Windows.Shapes.Rectangle]::new()
    $mark.Width = 4
    $mark.Fill = Get-Brush $color
    $mark.Margin = [System.Windows.Thickness]::new(0, 0, 14, 0)
    [System.Windows.Controls.DockPanel]::SetDock($mark, [System.Windows.Controls.Dock]::Left)
    [void]$dock.Children.Add($mark)
    $stack = [System.Windows.Controls.StackPanel]::new()
    $t1 = [System.Windows.Controls.TextBlock]::new()
    $t1.Text = $Item.Title; $t1.FontSize = 11.5; $t1.Foreground = Get-Brush '#8A92A3'
    $t2 = [System.Windows.Controls.TextBlock]::new()
    $t2.Text = $Item.Value; $t2.FontSize = 14; $t2.FontWeight = [System.Windows.FontWeights]::SemiBold; $t2.Foreground = Get-Brush '#E6E8ED'
    $t2.TextWrapping = [System.Windows.TextWrapping]::Wrap; $t2.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    [void]$stack.Children.Add($t1)
    [void]$stack.Children.Add($t2)
    if ($Item.Note) {
        $t3 = [System.Windows.Controls.TextBlock]::new()
        $t3.Text = $Item.Note; $t3.Foreground = Get-Brush '#8A92A3'
        $t3.TextWrapping = [System.Windows.TextWrapping]::Wrap; $t3.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
        [void]$stack.Children.Add($t3)
    }
    [void]$dock.Children.Add($stack)
    $card.Child = $dock
    return $card
}

function New-PanelNote([string]$Text) {
    $n = New-Object System.Windows.Controls.TextBlock
    $n.Text = $Text
    $n.Foreground = Get-Brush '#8A92A3'
    $n.Margin = [System.Windows.Thickness]::new(2, 6, 0, 0)
    return $n
}

function Show-Diagnostics {
    $ui.pnlDiag.Children.Clear()
    [void]$ui.pnlDiag.Children.Add((New-PanelNote 'Checking...'))
    Add-Work 'Diagnostics' $null {
        param($m)
        $ui.pnlDiag.Children.Clear()
        if ($m.Error) { return }
        foreach ($it in @($m.Result.Items)) { [void]$ui.pnlDiag.Children.Add((New-DiagCard $it)) }
        Invoke-Stagger $ui.pnlDiag.Children
    }
}

function Add-BiosSection([string]$Title, $Items) {
    if (@($Items).Count -eq 0) { return }
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $Title.ToUpperInvariant()
    $h.Style = $window.FindResource('Section')
    [void]$ui.pnlBios.Children.Add($h)
    foreach ($it in @($Items)) { [void]$ui.pnlBios.Children.Add((New-DiagCard $it)) }
}

function Show-BiosCheck {
    $ui.pnlBios.Children.Clear()
    [void]$ui.pnlBios.Children.Add((New-PanelNote 'Checking...'))
    Add-Work 'Bios' $null {
        param($m)
        $ui.pnlBios.Children.Clear()
        if ($m.Error) { return }
        $ui.txtBiosBoard.Text = $m.Result.Board
        Add-BiosSection 'Read from this PC' $m.Result.Detected
        Add-BiosSection 'Change by hand in the BIOS, if you want' $m.Result.Manual
        Add-BiosSection 'Leave these alone' $m.Result.Keep
        Invoke-Stagger $ui.pnlBios.Children
    }
}

function Restart-IntoBios {
    if ($env:firmware_type -ne 'UEFI') { Show-Message 'This PC does not boot in UEFI mode, so Windows cannot restart straight into the BIOS. Press DEL or F2 during startup instead.'; return }
    if (-not (Confirm-Action "Restart now and open the BIOS setup?`n`nSave your work first. Windows restarts in 15 seconds and closes open programs.")) { return }
    & shutdown.exe /r /fw /t 15 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Windows could not schedule a restart into the BIOS on this PC. Press DEL or F2 during startup instead.' }
    Write-Log 'Restarting into the BIOS in 15 seconds. To cancel, run this in a terminal:  shutdown /a'
}

function Invoke-TabTransition {
    if (-not $script:MainShown) { return }
    $body = $ui.tabs.Template.FindName('PART_Body', $ui.tabs)
    if ($null -eq $body) { return }
    $move = New-Object System.Windows.Media.TranslateTransform 0, 6
    $body.RenderTransform = $move
    Invoke-Anim $body $OpacityDp 1 170 0
    Invoke-Anim $move $MoveYDp 0 210 6
}

# ------------------------------------------------------------------ building and showing the window
function Build-MainWindow {
    $script:window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml](Build-Xaml))))
    $script:ui = @{}
    foreach ($n in 'txtSummary', 'txtAdmin', 'sumScale', 'busyTrack', 'busyScale', 'tabs', 'tabLive', 'tabDiag', 'tabBios',
                   'btnApply', 'btnRevert', 'btnRestoreAll', 'btnRestorePoint', 'btnRecommended', 'btnNone', 'txtLog',
                   'pnlTweaks', 'pnlDiag', 'btnDiag', 'txtTimer', 'txtTimerSub', 'txtTimerNote', 'btnTimer',
                   'txtWake', 'btnWake', 'txtPoll', 'txtPollSub', 'btnPoll', 'txtNetServer', 'btnNet', 'txtNet', 'txtNetVerdict',
                   'txtExe', 'btnBrowse', 'btnPrioHigh', 'btnPrioAbove', 'lstPrio', 'btnPrioRemove',
                   'txtBiosBoard', 'pnlBios', 'btnBiosReboot', 'svTweaks', 'svLive', 'svBios', 'svDiag', 'svTips') {
        $ui[$n] = $window.FindName($n)
        if ($null -eq $ui[$n]) { throw "UI element '$n' is missing" }
    }
    $script:Rows = @{}
    $script:TweakById = @{}
    foreach ($t in $Tweaks) {
        $script:TweakById[$t.Id] = $t
        $script:Rows[$t.Id] = @{
            Check  = $window.FindName("chk_$($t.Id)")
            Pill   = $window.FindName("pill_$($t.Id)")
            Status = $window.FindName("st_$($t.Id)")
            Meta   = $window.FindName("meta_$($t.Id)")
        }
    }
    foreach ($id in @($script:LastState.Keys)) { Set-RowState $id @{ State = $script:LastState[$id]; HasBackup = $script:HasBackup[$id]; Tip = $null } }
    $script:LogBox = $ui.txtLog
    foreach ($line in @($script:EarlyLog)) { Write-UiLog $line }

    $adminText = if (Test-Admin) { 'Running as administrator' } else { 'Read-only (not administrator)' }
    $ui.txtAdmin.Text = '{0}   {1}   v{2}' -f $adminText, [char]0x00B7, $AppVersion

    $ui.btnApply.Add_Click({ Invoke-Safe { Invoke-ApplySelected } })
    $ui.btnRevert.Add_Click({ Invoke-Safe { Invoke-RevertSelected } })
    $ui.btnRestoreAll.Add_Click({ Invoke-Safe { Invoke-RestoreEverything } })
    $ui.btnRestorePoint.Add_Click({ Invoke-Safe { Add-Work 'RestorePoint' $null $null -Busy } })
    $ui.btnRecommended.Add_Click({ Invoke-Safe { Select-Recommended } })
    $ui.btnNone.Add_Click({ foreach ($t in $Tweaks) { $script:Rows[$t.Id].Check.IsChecked = $false } })
    $ui.btnDiag.Add_Click({ Invoke-Safe { Show-Diagnostics } })
    $ui.btnBiosReboot.Add_Click({ Invoke-Safe { Restart-IntoBios } })
    $ui.btnTimer.Add_Click({ Invoke-Safe { Switch-TimerHold } })
    $ui.btnWake.Add_Click({ Invoke-Safe { Start-WakeTest } })
    $ui.btnNet.Add_Click({ Invoke-Safe { Start-NetTest } })
    $ui.btnPoll.Add_Click({ Invoke-Safe { Switch-PollTest } })
    $ui.btnBrowse.Add_Click({ Invoke-Safe {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'Programs (*.exe)|*.exe'
        $dlg.Title = 'Pick the game executable'
        if ($dlg.ShowDialog($window)) { $ui.txtExe.Text = [IO.Path]::GetFileName($dlg.FileName) }
    } })
    $ui.btnPrioHigh.Add_Click({ Invoke-Safe { Add-Priority 3 } })
    $ui.btnPrioAbove.Add_Click({ Invoke-Safe { Add-Priority 6 } })
    $ui.btnPrioRemove.Add_Click({ Invoke-Safe { Remove-SelectedPriority } })

    $script:Tick = New-Object System.Windows.Threading.DispatcherTimer
    $script:Tick.Interval = [TimeSpan]::FromSeconds(1)
    $script:Tick.Add_Tick({ try { Update-TimerText } catch {} })
    # A process has one timer request and WPF's own timer calls can cancel it when an animation ends,
    # so the hold is repeated every second for as long as it is on.
    $script:HoldTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:HoldTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:HoldTimer.Add_Tick({ try { [void](Set-TimerHold $true) } catch {} })
    $script:PollTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:PollTimer.Add_Tick({ try { Update-PollTest } catch { Stop-PollTest } })

    $ui.tabs.Add_SelectionChanged({
        param($s, $e)
        if ($e.OriginalSource -ne $ui.tabs) { return }
        Invoke-TabTransition
        $selected = $ui.tabs.SelectedItem
        if ($selected -eq $ui.tabLive) { try { Update-TimerText } catch {}; $script:Tick.Start() }   # nothing ticks while unseen
        else { $script:Tick.Stop(); Stop-PollTest }
        if ($selected -eq $ui.tabDiag -and -not $script:DiagLoaded) { $script:DiagLoaded = $true; Invoke-Safe { Show-Diagnostics } }
        if ($selected -eq $ui.tabBios -and -not $script:BiosLoaded) { $script:BiosLoaded = $true; Invoke-Safe { Show-BiosCheck } }
    })

    $window.Add_SourceInitialized({ try { [ILO.Native]::UseDarkTitleBar($window) } catch {} })
    $window.Add_Closing({
        param($s, $e)
        if ($script:Running -and $script:Running.Busy) {
            $e.Cancel = $true
            Write-Log 'Still working. The app can close when this change has finished.'
            return
        }
        $script:Tick.Stop()
        $script:HoldTimer.Stop()
        Stop-PollTest
        if ($script:TimerHeld) { try { [void](Set-TimerHold $false) } catch {} }
    })
    $window.Add_Closed({ [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })
}

function Show-MainWhenReady {
    if ($script:MainShown -or $null -eq $script:window -or -not $script:StatusSnapshot) { return }
    Update-Snapshot $script:StatusSnapshot
    foreach ($n in 'svTweaks', 'svLive', 'svBios', 'svDiag', 'svTips') { [ILO.SmoothScroll]::Attach($ui[$n]) }
    $root = $window.Content
    $root.Opacity = 0
    $move = New-Object System.Windows.Media.TranslateTransform 0, 12
    $root.RenderTransform = $move
    $script:MainShown = $true
    if ($script:SplashState) { $script:SplashState.Frac = 1.0; $script:SplashState.Text = 'Ready' }
    $window.Show()
    [void]$window.Activate()
    Invoke-Anim $root $OpacityDp 1 240 0
    Invoke-Anim $move $MoveYDp 0 300 12
    Invoke-Stagger $ui.pnlTweaks.Children
    Write-Log ('Ready. {0} saved backup(s) in {1}' -f (@($script:TweakBackups).Count + @($script:PriorityBackups).Count), $BackupFile)
    if ($script:SplashState) { $script:SplashState.Close = $true }   # it fades itself out over the main window
}

function Stop-WithError([string]$Text) {
    Write-Log "Fatal: $Text"
    if ($script:SplashState) { $script:SplashState.Close = $true }
    Show-Message "Something went wrong while starting:`n`n$Text" 'Error'
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

function Add-StartupWork {
    Add-Work 'Startup' $null {
        param($m)
        if ($m.Error) {
            if ($script:Headless) { throw $m.Error }
            Stop-WithError $m.Error
            return
        }
        $script:StatusSnapshot = $m.Result
        if ($script:Headless) { Update-Snapshot $m.Result } else { Show-MainWhenReady }
    }
}

# ------------------------------------------------------------------ main
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $OpacityDp = [System.Windows.UIElement]::OpacityProperty
    $ScaleXDp  = [System.Windows.Media.ScaleTransform]::ScaleXProperty
    $MoveYDp   = [System.Windows.Media.TranslateTransform]::YProperty
    $script:EaseOut = New-Object System.Windows.Media.Animation.CubicEase
    $script:EaseOut.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $script:EaseOut.Freeze()

    # WPF animates at 60 fps unless told otherwise. Must happen before the first animation is created.
    try {
        [System.Windows.Media.Animation.Timeline]::DesiredFrameRateProperty.OverrideMetadata(
            [System.Windows.Media.Animation.Timeline], (New-Object System.Windows.FrameworkPropertyMetadata ([object][int]120)))
    } catch {}

    $script:Headless = [bool]$SelfTest
    $script:MainShown = $false
    $script:Rows = @{}
    $script:EarlyLog = @()
    $script:LastState = @{}
    $script:HasBackup = @{}
    $script:TweakBackups = @()
    $script:PriorityBackups = @()
    $script:PrioEntries = @()
    $script:TimerHeld = $false
    $script:AskedRestorePoint = $false
    $script:DiagLoaded = $false
    $script:BiosLoaded = $false
    $script:PollOn = $false

    if ($SelfTest) {
        Build-MainWindow
        Start-Worker
        Add-StartupWork
        Wait-Work
        Show-Diagnostics
        Show-BiosCheck
        $script:NvLines = @(); $script:WakeLine = ''
        Add-Work 'NvProbe' $null { param($m) $script:NvLines = @($m.Result.Lines) }
        Add-Work 'WakeTest' @{ Held = $false } { param($m) $r = @($m.Result.History)[0]; $script:WakeLine = 'Wake-up test: average {0:0.00} ms, 99% {1:0.00} ms, worst {2:0.00} ms' -f $r.Avg, $r.P99, $r.Worst }
        Add-Work 'NetTest' @{ Server = '' } { param($m) if ($m.Error) { "Connection test failed: $($m.Error)" | Write-Host } else { Show-NetResults $m.Result } }
        Wait-Work
        "SELFTEST window built: $($Tweaks.Count) tweaks, $($ui.pnlDiag.Children.Count) diagnostics, summary '$($ui.txtSummary.Text)'"
        "BIOS tab: $($ui.txtBiosBoard.Text), $($ui.pnlBios.Children.Count) rows"
        foreach ($t in $Tweaks) { '  {0,-15} {1}' -f $t.Id, $script:Rows[$t.Id].Status.Text }
        $script:NvLines
        $script:WakeLine
        $ui.txtNet.Text
        $ui.txtNetVerdict.Text
        $window.Close()
        exit 0
    }

    $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $dispatcher.Add_UnhandledException({
        param($s, $e)
        $e.Handled = $true
        try { Write-Log "Error: $($e.Exception.Message)" } catch {}
    })

    # Three things run at once: the loading screen, the checks on the worker, and parsing the window here.
    Start-Splash
    Start-Worker
    Add-StartupWork
    Invoke-Pump
    Build-MainWindow
    Show-MainWhenReady

    [System.Windows.Threading.Dispatcher]::Run()
    [Environment]::Exit(0)
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
