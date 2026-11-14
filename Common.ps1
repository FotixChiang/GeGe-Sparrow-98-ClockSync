#Requires -Version 5.1
<#
    Common.ps1 - shared helpers. ASCII only (PS 5.1 misreads BOM-less UTF-8 scripts).
#>

if (-not ('CcHid' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CcHid
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("hid.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool HidD_GetProductString(IntPtr h, StringBuilder buf, uint len);

    [DllImport("hid.dll", SetLastError = true)]
    public static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);

    [StructLayout(LayoutKind.Sequential)]
    public struct HIDD_ATTRIBUTES
    {
        public int Size;
        public ushort VendorID;
        public ushort ProductID;
        public ushort VersionNumber;
    }
}
'@
}

if (-not ('CcHidden' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class CcHidden
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize;
        public int dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateDesktopW(string lpszDesktop, string lpszDevice, IntPtr pDevmode, int dwFlags, uint dwDesiredAccess, IntPtr lpsa);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseDesktop(IntPtr hDesktop);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumDesktopWindows(IntPtr hDesktop, EnumProc lpfn, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetThreadDesktop(uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr h, uint ms);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr h, uint code);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr h);

    // Runs exe on a throwaway invisible desktop. Returns a status string.
    public static string Run(string exe, string workdir, int startTimeoutMs, int settleMs, int exitWaitMs)
    {
        string deskName = "CcSync_" + Guid.NewGuid().ToString("N").Substring(0, 8);
        IntPtr desk = CreateDesktopW(deskName, null, IntPtr.Zero, 0, 0x10000000u, IntPtr.Zero);
        if (desk == IntPtr.Zero)
            return "ERROR CreateDesktop err=" + Marshal.GetLastWin32Error();

        try
        {
            STARTUPINFO si = new STARTUPINFO();
            si.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            si.lpDesktop = "winsta0\\" + deskName;
            si.dwFlags = 0x1;
            si.wShowWindow = 0;

            PROCESS_INFORMATION pi;
            if (!CreateProcessW(exe, null, IntPtr.Zero, IntPtr.Zero, false, 0u, IntPtr.Zero, workdir, ref si, out pi))
                return "ERROR CreateProcess err=" + Marshal.GetLastWin32Error();

            Stopwatch sw = Stopwatch.StartNew();
            try
            {
                IntPtr first = IntPtr.Zero;
                while (sw.ElapsedMilliseconds < startTimeoutMs)
                {
                    if (WaitForSingleObject(pi.hProcess, 0u) == 0u)
                        return "ERROR app exited early";
                    IntPtr found = IntPtr.Zero;
                    EnumDesktopWindows(desk, delegate(IntPtr h, IntPtr l) { if (found == IntPtr.Zero) found = h; return true; }, IntPtr.Zero);
                    if (found != IntPtr.Zero) { first = found; break; }
                    System.Threading.Thread.Sleep(200);
                }

                if (first == IntPtr.Zero)
                    return "WARN no window on private desktop within " + startTimeoutMs + "ms";

                System.Threading.Thread.Sleep(settleMs);

                IntPtr userDesk = GetThreadDesktop(GetCurrentThreadId());
                int leaked = 0;
                EnumDesktopWindows(userDesk, delegate(IntPtr h, IntPtr l)
                {
                    uint p;
                    GetWindowThreadProcessId(h, out p);
                    if (p == (uint)pi.dwProcessId) leaked++;
                    return true;
                }, IntPtr.Zero);

                EnumDesktopWindows(desk, delegate(IntPtr h, IntPtr l) { PostMessage(h, 0x10u, IntPtr.Zero, IntPtr.Zero); return true; }, IntPtr.Zero);

                uint waited = WaitForSingleObject(pi.hProcess, (uint)exitWaitMs);
                string tail = string.Format(" up={0:F1}s leaked_windows={1}", sw.Elapsed.TotalSeconds, leaked);
                if (waited != 0u)
                {
                    TerminateProcess(pi.hProcess, 0u);
                    return "OK" + tail + " forced";
                }
                return "OK" + tail;
            }
            finally
            {
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
            }
        }
        finally
        {
            CloseDesktop(desk);
        }
    }
}
'@
}

function Write-CcLog {
    param([string]$Path, [string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).Length -gt 65536)) {
            Move-Item -LiteralPath $Path -Destination ($Path + '.old') -Force
        }
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    } catch { }
    if ($env:CC_VERBOSE -eq '1') { Write-Host $line }
}

<#  Returns present HID interfaces of a vendor id, with product string.  #>
function Get-VendorDevice {
    param([string]$Vid = '258A')

    $result = New-Object System.Collections.Generic.List[object]
    $guid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'
    $base = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"
    $pattern = 'VID_' + $Vid

    foreach ($k in Get-ChildItem $base -ErrorAction SilentlyContinue) {
        $key = $k.PSChildName
        if ($key -notmatch $pattern) { continue }

        $ifPath = '\\?\' + ($key -replace '^##\?#', '')
        $h = [CcHid]::CreateFileW($ifPath, [uint32]2147483648, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
        if ([int]$h -eq -1) { continue }

        $sb = New-Object System.Text.StringBuilder 256
        $null = [CcHid]::HidD_GetProductString($h, $sb, [uint32]256)
        $attr = New-Object CcHid+HIDD_ATTRIBUTES
        $attr.Size = 8
        $null = [CcHid]::HidD_GetAttributes($h, [ref]$attr)
        $null = [CcHid]::CloseHandle($h)

        $result.Add([pscustomobject]@{
            Vid       = '{0:X4}' -f $attr.VendorID
            Pid       = '{0:X4}' -f $attr.ProductID
            Product   = $sb.ToString()
            Interface = ($key -split '#')[1]
        })
    }

    return $result | Where-Object { $_.Vid -eq $Vid }
}

function Test-VendorConnected {
    param([string]$Vid = '258A')
    if (Get-VendorDevice -Vid $Vid) { return $true }
    $c = & pnputil.exe /enum-devices /connected 2>$null
    return [bool]($c -match ('VID_' + $Vid))
}

<#
    Finds the OEM config app for a 258A-family board.
    Every rebrand of this suite ships Cfg.ini with VID=/PID= and a Dev\<PID>\KB.ini,
    so we identify the app by the VID inside Cfg.ini instead of by folder name.
#>
function Find-VendorApp {
    param([string]$Vid = '258A', [string]$TargetPid = '')

    $dirs = New-Object System.Collections.Generic.List[string]

    $uninstallRoots = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstallRoots) {
        Get-ItemProperty $root -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.InstallLocation -and (Test-Path -LiteralPath $_.InstallLocation)) {
                $dirs.Add($_.InstallLocation)
            }
        }
    }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'))
    $keywords = '(?i)keyboard|kbd|gege|sparrow|royal|^rk|vgn|ajazz|epomaker|monsgeek|womier|feker|aula|leobog|magic|attack'
    foreach ($r in $roots) {
        if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
        Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $keywords } |
            ForEach-Object { $dirs.Add($_.FullName) }
    }

    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($d in ($dirs | Select-Object -Unique)) {
        $cfg = Join-Path $d 'Cfg.ini'
        if (-not (Test-Path -LiteralPath $cfg)) { continue }

        $txt = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
        if (-not $txt) { continue }

        $m = [regex]::Match($txt, '(?im)^\s*VID\s*=\s*(.+?)\s*$')
        if (-not $m.Success) { continue }
        if ($m.Groups[1].Value -notmatch $Vid) { continue }

        $exe = Join-Path $d 'DeviceDriver.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            $pick = Get-ChildItem -LiteralPath $d -Filter '*.exe' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '(?i)^unins|^uninstall' } |
                    Sort-Object Length -Descending | Select-Object -First 1
            if ($pick) { $exe = $pick.FullName }
        }
        if (-not (Test-Path -LiteralPath $exe)) { continue }

        # Which model under Dev\ matches, and does it enable time-on-open?
        $model = ''
        $timeOnOpen = $false
        $modelPid = ''
        $devRoot = Join-Path $d 'Dev'
        if (Test-Path -LiteralPath $devRoot) {
            $pids = Get-ChildItem -LiteralPath $devRoot -Directory -ErrorAction SilentlyContinue
            if ($TargetPid) {
                $exact = $pids | Where-Object { $_.Name -eq $TargetPid }
                if ($exact) { $pids = $exact }
            }
            foreach ($p in $pids) {
                $kb = Join-Path $p.FullName 'KB.ini'
                if (-not (Test-Path -LiteralPath $kb)) { continue }
                $kbtxt = Get-Content -LiteralPath $kb -Raw -ErrorAction SilentlyContinue
                if (-not $kbtxt) { continue }
                if ($kbtxt -match '(?im)^\s*SendTimeOnOpenKB\s*=\s*1') {
                    $timeOnOpen = $true
                    $model = $p.Name
                    $modelPid = $p.Name
                    break
                }
                if (-not $model) { $model = $p.Name; $modelPid = $p.Name }
            }
        }

        $pidList = ''
        $pm = [regex]::Match($txt, '(?im)^\s*PID\s*=\s*(.+?)\s*$')
        if ($pm.Success) { $pidList = $pm.Groups[1].Value }

        $candidates.Add([pscustomobject]@{
            Exe         = $exe
            Dir         = $d
            PidList     = $pidList
            Model       = $model
            ModelPid    = $modelPid
            TimeOnOpen  = $timeOnOpen
        })
    }

    if ($candidates.Count -eq 0) { return $null }

    $best = $candidates | Where-Object { $_.TimeOnOpen } | Select-Object -First 1
    if (-not $best) { $best = $candidates[0] }
    return $best
}

function Invoke-VendorSync {
    param(
        [string]$Exe,
        [string]$WorkDir,
        [int]$StartTimeoutMs = 30000,
        [int]$SettleMs = 4000,
        [int]$ExitWaitMs = 6000
    )
    return [CcHidden]::Run($Exe, $WorkDir, $StartTimeoutMs, $SettleMs, $ExitWaitMs)
}
