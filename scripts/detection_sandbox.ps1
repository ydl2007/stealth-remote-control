<#
.SYNOPSIS
    Detection Sandbox — simulates proctoring software detection techniques.
    Safe, read-only enumeration. No evasion, no system modification.

.DESCRIPTION
    This script simulates 10 categories of detection techniques used by
    proctoring software to identify unauthorized remote access, VMs,
    overlay windows, and suspicious processes. It is designed to be run
    as a baseline measurement tool before implementing stealth measures.

    Outputs a structured JSON report to .omo/evidence/task-1-detection-sandbox.json

    Techniques simulated:
      1. Process enumeration (EnumProcesses via Get-Process)
      2. Digital signature verification (WinVerifyTrust via Get-AuthenticodeSignature)
      3. TCP connection mapping (GetExtendedTcpTable via Get-NetTCPConnection)
      4. Foreground / visible window titles (GetForegroundWindow via MainWindowTitle)
      5. Window display affinity (GetWindowDisplayAffinity via Win32 pinvoke)
      6. Monitor enumeration (EnumDisplayMonitors via System.Windows.Forms)
      7. Service enumeration with paths and signatures (EnumServicesStatusEx via CIM)
      8. VM presence detection via registry IDE keys
      9. Clipboard monitor / listener process detection
     10. Aggregated structured JSON output

.NOTES
    Author: Stealth Remote Control Project
    Version: 1.0
    Target: Windows 10/11 (x64)
    Privileges: Some checks require admin (service paths, some registry reads);
                script degrades gracefully without elevation.

    Idempotent: YES. Safe to run multiple times.
    Destructive: NO. Read-only operations only.

.EXAMPLE
    .\detection_sandbox.ps1
    .\detection_sandbox.ps1 -OutputPath "C:\custom\path\report.json"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = $(Join-Path -Path $PSScriptRoot -ChildPath "..\.omo\evidence\task-1-detection-sandbox.json")
)

#Requires -Version 5.1

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
$script:StartTime = Get-Date
$script:Results = @{}
$script:Errors = @()

# ---------------------------------------------------------------------------
# Helper: write structured output with timestamp and duration
# ---------------------------------------------------------------------------
function Write-TimedMessage {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Write-Host "[$ts] [$Level] $Message"
}

function Add-ErrorRecord {
    param([string]$Category, [string]$Detail, [Exception]$Ex)
    $script:Errors += @{
        category    = $Category
        detail      = $Detail
        exception   = $Ex.Message
        line        = $(if ($Ex.InvocationInfo) { $Ex.InvocationInfo.ScriptLineNumber } else { -1 })
        timestamp   = (Get-Date -Format "o")
    }
    Write-TimedMessage -Message "ERROR [$Category] $Detail : $($Ex.Message)" -Level "ERROR"
}

# ---------------------------------------------------------------------------
# 1. Process Enumeration (simulates EnumProcesses)
# ---------------------------------------------------------------------------
function Invoke-ProcessEnumeration {
    Write-TimedMessage -Message "[1/10] Enumerating running processes (EnumProcesses simulation)..."
    $procs = @{}
    try {
        $allProcesses = Get-Process -ErrorAction Stop
        foreach ($p in $allProcesses) {
            try {
                $key = "$($p.Id)"
                # PS 5.1-compatible null checks (no ?. or ?? operators)
                $startTimeVal = if ($p.StartTime) { $p.StartTime.ToString("o") } else { $null }
                $fileVersionVal = $null
                if ($p.MainModule) {
                    if ($p.MainModule.FileVersionInfo) {
                        $fileVersionVal = $p.MainModule.FileVersionInfo.FileVersion
                    }
                }
                $procs[$key] = @{
                    ProcessName        = $p.ProcessName
                    Id                 = $p.Id
                    SessionId          = $p.SessionId
                    StartTime          = $startTimeVal
                    MainWindowTitle    = $p.MainWindowTitle
                    Responding         = $p.Responding
                    WorkingSet64       = $p.WorkingSet64
                    FileVersion        = $fileVersionVal
                }
            }
            catch {
                # Silently skip processes we cannot inspect (e.g. system-level)
            }
        }
        Write-TimedMessage -Message "  -> Enumerated $($procs.Count) processes."
    }
    catch {
        Add-ErrorRecord -Category "ProcessEnumeration" -Detail "Get-Process failed" -Ex $_
        # Fallback: use CIM
        try {
            $cimProcs = Get-CimInstance -ClassName Win32_Process -ErrorAction Stop
            foreach ($p in $cimProcs) {
                $key = "$($p.ProcessId)"
                $startTimeVal = if ($p.CreationDate) { $p.CreationDate.ToString("o") } else { $null }
                $procs[$key] = @{
                    ProcessName        = $p.Name
                    Id                 = $p.ProcessId
                    SessionId          = $p.SessionId
                    StartTime          = $startTimeVal
                    MainWindowTitle    = $null
                    Responding         = $null
                    WorkingSet64       = $p.WorkingSetSize
                    FileVersion        = $null
                }
            }
        }
        catch {
            Add-ErrorRecord -Category "ProcessEnumeration" -Detail "Fallback CIM also failed" -Ex $_
        }
    }
    return $procs
}

# ---------------------------------------------------------------------------
# 2. Digital Signature Verification (simulates WinVerifyTrust)
# ---------------------------------------------------------------------------
function Invoke-SignatureCheck {
    param([hashtable]$Processes)
    Write-TimedMessage -Message "[2/10] Checking digital signatures of running EXEs (WinVerifyTrust simulation)..."

    $sigs = @{}
    $checked = 0
    # Limit to a reasonable sample to avoid long runtime
    $sampleLimit = 300
    $pathsSeen = @{}

    foreach ($key in $Processes.Keys) {
        if ($checked -ge $sampleLimit) { break }
        $p = $Processes[$key]
        # We need the executable path — best-effort via wmi query by PID
        try {
            $pid = $p.Id
            $procObj = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $pid" -ErrorAction SilentlyContinue
            $path = if ($procObj) { $procObj.ExecutablePath } else { $null }
            if (-not $path -or $pathsSeen.ContainsKey($path)) { continue }
            $pathsSeen[$path] = $true

            if (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) {
                $checked++
                $sig = Get-AuthenticodeSignature -FilePath $path -ErrorAction SilentlyContinue
                $sigs[$path] = @{
                    FilePath        = $path
                    Status          = "$($sig.Status)"
                    SignerCN        = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null })
                    SignerThumbprint = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { $null })
                    TimeStamperCN   = $(if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { $null })
                    IsOSBinary      = $path.ToLower().StartsWith("c:\windows")
                }
            }
        }
        catch {
            # best-effort
        }
    }

    $signedCount = ($sigs.Values | Where-Object { $_.Status -eq "Valid" }).Count
    $unsignedCount = ($sigs.Values | Where-Object { $_.Status -ne "Valid" }).Count
    Write-TimedMessage -Message "  -> Checked $checked paths: $signedCount signed, $unsignedCount unsigned/unknown."
    return @{
        SampleSize   = $checked
        SignedCount  = $signedCount
        UnsignedCount = $unsignedCount
        Signatures   = $sigs
    }
}

# ---------------------------------------------------------------------------
# 3. TCP Connection Mapping (simulates GetExtendedTcpTable)
# ---------------------------------------------------------------------------
function Invoke-TcpConnectionMapping {
    Write-TimedMessage -Message "[3/10] Getting active TCP connections mapped to PIDs (GetExtendedTcpTable simulation)..."

    $connections = @()
    try {
        $tcpTable = Get-NetTCPConnection -ErrorAction Stop
        foreach ($conn in $tcpTable) {
            $connections += @{
                LocalAddress   = $conn.LocalAddress
                LocalPort      = $conn.LocalPort
                RemoteAddress  = $conn.RemoteAddress
                RemotePort     = $conn.RemotePort
                State          = "$($conn.State)"
                OwningProcess  = $conn.OwningProcess
                CreationTime   = $(if ($conn.CreationTime) { $conn.CreationTime.ToString("o") } else { $null })
                OffloadState   = "$($conn.OffloadState)"
            }
        }
        Write-TimedMessage -Message "  -> Found $($connections.Count) active TCP connections."
    }
    catch {
        Add-ErrorRecord -Category "TcpConnectionMapping" -Detail "Get-NetTCPConnection failed" -Ex $_
        # Fallback: use netstat
        try {
            $netstat = & netstat -ano 2>$null
            if ($netstat) {
                foreach ($line in $netstat) {
                    if ($line -match '^\s*TCP\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)\s*$') {
                        $connections += @{
                            LocalAddress   = ($matches[1] -split ':')[0]
                            LocalPort      = [int]($matches[1] -split ':')[-1]
                            RemoteAddress  = ($matches[2] -split ':')[0]
                            RemotePort     = [int]($matches[2] -split ':')[-1]
                            State          = $matches[3]
                            OwningProcess  = [int]$matches[4]
                        }
                    }
                }
            }
            Write-TimedMessage -Message "  -> Found $($connections.Count) connections via netstat fallback."
        }
        catch {
            Add-ErrorRecord -Category "TcpConnectionMapping" -Detail "netstat fallback also failed" -Ex $_
        }
    }

    return $connections
}

# ---------------------------------------------------------------------------
# 4. Window Title Enumeration (simulates GetForegroundWindow)
# ---------------------------------------------------------------------------
function Invoke-WindowTitleCheck {
    Write-TimedMessage -Message "[4/10] Checking visible window titles (GetForegroundWindow simulation)..."

    $windows = @()
    try {
        # Load WinForms assembly if not already loaded
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop | Out-Null
    }
    catch {
        Add-ErrorRecord -Category "WindowTitleCheck" -Detail "Cannot load System.Windows.Forms" -Ex $_
    }

    # Method 1: Get-Process with MainWindowTitle
    try {
        $procsWithWindows = Get-Process | Where-Object { -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) } -ErrorAction SilentlyContinue
        foreach ($p in $procsWithWindows) {
            $windows += @{
                Source          = "Get-Process::MainWindowTitle"
                WindowTitle     = $p.MainWindowTitle
                ProcessName     = $p.ProcessName
                ProcessId       = $p.Id
                Responding      = $p.Responding
            }
        }
    }
    catch {
        Add-ErrorRecord -Category "WindowTitleCheck" -Detail "Get-Process MainWindowTitle enumeration failed" -Ex $_
    }

    # Method 2: Win32 API pinvoke for EnumWindows (more thorough)
    try {
        $enumWindowsCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WindowEnumerator
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    public static List<Dictionary<string, object>> EnumerateAllWindows()
    {
        var result = new List<Dictionary<string, object>>();
        var syncLock = new object();

        EnumWindows((hWnd, lParam) =>
        {
            if (!IsWindowVisible(hWnd)) return true;

            var sb = new StringBuilder(256);
            int len = GetWindowText(hWnd, sb, 256);
            string title = sb.ToString();

            if (!string.IsNullOrWhiteSpace(title))
            {
                uint pid = 0;
                GetWindowThreadProcessId(hWnd, out pid);
                lock (syncLock)
                {
                    result.Add(new Dictionary<string, object>
                    {
                        { "WindowTitle", title },
                        { "ProcessId", (int)pid },
                        { "Source", "EnumWindows::GetWindowText" }
                    });
                }
            }
            return true;
        }, IntPtr.Zero);

        return result;
    }
}
'@
        Add-Type -TypeDefinition $enumWindowsCode -ErrorAction SilentlyContinue | Out-Null
        if ([WindowEnumerator] -ne $null) {
            $enumWindows = [WindowEnumerator]::EnumerateAllWindows()
            # Merge with existing, dedup by title+pid
            $existing = $windows | ForEach-Object { "$($_.WindowTitle)|$($_.ProcessId)" } | Sort-Object -Unique
            foreach ($ew in $enumWindows) {
                $key = "$($ew.WindowTitle)|$($ew.ProcessId)"
                if ($key -notin $existing) {
                    $windows += $ew
                    $existing += $key
                }
            }
        }
    }
    catch {
        # EnumWindows via pinvoke is best-effort
    }

    Write-TimedMessage -Message "  -> Found $($windows.Count) visible windows with titles."
    return $windows
}

# ---------------------------------------------------------------------------
# 5. Window Display Affinity Check (simulates GetWindowDisplayAffinity)
# ---------------------------------------------------------------------------
function Invoke-DisplayAffinityCheck {
    Write-TimedMessage -Message "[5/10] Checking windows for display affinity (GetWindowDisplayAffinity pinvoke)..."

    $affinityResults = @()

    # Define Win32 pinvoke for GetWindowDisplayAffinity
    $displayAffinityCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class DisplayAffinityChecker
{
    public const uint WDA_NONE = 0x00000000;
    public const uint WDA_MONITOR = 0x00000001;

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowDisplayAffinity(IntPtr hWnd, out uint dwAffinity);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    public static List<Dictionary<string, object>> CheckAllWindows()
    {
        var results = new List<Dictionary<string, object>>();
        var syncLock = new object();

        EnumWindows(new EnumWindowsProc((hWnd, lParam) =>
        {
            if (!IsWindowVisible(hWnd)) return true;

            uint affinity;
            bool success = GetWindowDisplayAffinity(hWnd, out affinity);

            if (success && affinity != WDA_NONE)
            {
                var sb = new StringBuilder(256);
                GetWindowText(hWnd, sb, 256);
                string title = sb.ToString();
                uint pid = 0;
                GetWindowThreadProcessId(hWnd, out pid);

                lock (syncLock)
                {
                    results.Add(new Dictionary<string, object>
                    {
                        { "WindowTitle", title },
                        { "ProcessId", (int)pid },
                        { "DisplayAffinity", affinity },
                        { "AffinityType", affinity == WDA_MONITOR ? "WDA_MONITOR (0x1)" : $"Unknown (0x{affinity:X8})" }
                    });
                }
            }
            return true;
        }), IntPtr.Zero);

        return results;
    }
}
'@

    try {
        Add-Type -TypeDefinition $displayAffinityCode -ErrorAction Stop | Out-Null
        $affinityResults = [DisplayAffinityChecker]::CheckAllWindows()
        Write-TimedMessage -Message "  -> Found $($affinityResults.Count) windows with non-zero display affinity."
    }
    catch {
        Add-ErrorRecord -Category "DisplayAffinity" -Detail "GetWindowDisplayAffinity pinvoke failed" -Ex $_
    }

    return $affinityResults
}

# ---------------------------------------------------------------------------
# 6. Monitor Enumeration (simulates EnumDisplayMonitors)
# ---------------------------------------------------------------------------
function Invoke-MonitorEnumeration {
    Write-TimedMessage -Message "[6/10] Enumerating monitors (EnumDisplayMonitors simulation)..."

    $monitors = @()
    $primaryInfo = $null

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop | Out-Null
        $allScreens = [System.Windows.Forms.Screen]::AllScreens
        foreach ($screen in $allScreens) {
            $isPrimary = $screen.Primary
            $monitors += @{
                DeviceName      = $screen.DeviceName
                Primary         = $isPrimary
                Bounds          = "$($screen.Bounds.Width)x$($screen.Bounds.Height) @ ($($screen.Bounds.X), $($screen.Bounds.Y))"
                BoundsWidth     = $screen.Bounds.Width
                BoundsHeight    = $screen.Bounds.Height
                BoundsX         = $screen.Bounds.X
                BoundsY         = $screen.Bounds.Y
                WorkingArea     = "$($screen.WorkingArea.Width)x$($screen.WorkingArea.Height)"
                BitsPerPixel    = $null  # Not available via Screen class
            }
            if ($isPrimary) {
                $primaryInfo = @{
                    Width       = $screen.Bounds.Width
                    Height      = $screen.Bounds.Height
                    DeviceName  = $screen.DeviceName
                }
            }
        }
        Write-TimedMessage -Message "  -> Found $($monitors.Count) monitor(s)."
    }
    catch {
        Add-ErrorRecord -Category "MonitorEnumeration" -Detail "Screen.AllScreens enumeration failed" -Ex $_
    }

    # Also try Win32 API for more detail (DDV for bits per pixel, etc.)
    try {
        $gdiCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class MonitorInfo
{
    [StructLayout(LayoutKind.Sequential)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern int GetDeviceCaps(IntPtr hdc, int nIndex);

    public const int BITSPIXEL = 12;
    public const int PLANES = 14;
    public const int HORZRES = 8;
    public const int VERTRES = 10;

    public static Dictionary<string, object> GetPrimaryMonitorCaps()
    {
        var result = new Dictionary<string, object>();
        IntPtr hdc = GetDC(IntPtr.Zero);
        if (hdc != IntPtr.Zero)
        {
            result["BitsPerPixel"] = GetDeviceCaps(hdc, BITSPIXEL) * GetDeviceCaps(hdc, PLANES);
            result["HorizontalResolution"] = GetDeviceCaps(hdc, HORZRES);
            result["VerticalResolution"] = GetDeviceCaps(hdc, VERTRES);
            ReleaseDC(IntPtr.Zero, hdc);
        }
        return result;
    }
}
'@
        Add-Type -TypeDefinition $gdiCode -ErrorAction SilentlyContinue | Out-Null
        if ([MonitorInfo] -ne $null) {
            $caps = [MonitorInfo]::GetPrimaryMonitorCaps()
            if ($caps.Count -gt 0) {
                if ($primaryInfo -eq $null) { $primaryInfo = @{} }
                $primaryInfo['BitsPerPixel'] = $caps['BitsPerPixel']
                $primaryInfo['HorizontalResolution'] = $caps['HorizontalResolution']
                $primaryInfo['VerticalResolution'] = $caps['VerticalResolution']
            }
        }
    }
    catch {
        # Best-effort
    }

    return @{
        Monitors     = $monitors
        PrimaryInfo  = $primaryInfo
        Count        = $monitors.Count
    }
}

# ---------------------------------------------------------------------------
# 7. Service Enumeration (simulates EnumServicesStatusEx)
# ---------------------------------------------------------------------------
function Invoke-ServiceEnumeration {
    Write-TimedMessage -Message "[7/10] Enumerating services with paths and signatures (EnumServicesStatusEx simulation)..."

    $services = @()
    try {
        $svcs = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop
        foreach ($svc in $svcs) {
            $sigInfo = $null
            $path = $svc.PathName
            # Extract executable path (strip arguments)
            if ($path) {
                $exePath = if ($path -match '"([^"]+\.exe)"') {
                    $matches[1]
                } elseif ($path -match '^([^\s"]+\.exe)') {
                    $matches[1]
                } else {
                    $path
                }
                if (Test-Path -LiteralPath $exePath -ErrorAction SilentlyContinue) {
                    try {
                        $sig = Get-AuthenticodeSignature -FilePath $exePath -ErrorAction SilentlyContinue
                        $sigInfo = @{
                            Status   = "$($sig.Status)"
                            SignerCN = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { $null })
                        }
                    }
                    catch {
                        $sigInfo = @{ Status = "Error"; SignerCN = $null }
                    }
                }
            }

            $services += @{
                Name           = $svc.Name
                DisplayName    = $svc.DisplayName
                State          = $svc.State
                StartMode      = $svc.StartMode
                ProcessId      = $svc.ProcessId
                PathName       = $path
                ServiceType    = $svc.ServiceType
                Signature      = $sigInfo
            }
        }
        Write-TimedMessage -Message "  -> Enumerated $($services.Count) services."
    }
    catch {
        Add-ErrorRecord -Category "ServiceEnumeration" -Detail "CIM Win32_Service failed" -Ex $_
    }

    return $services
}

# ---------------------------------------------------------------------------
# 8. VM Presence Detection (simulates registry-based VM detection)
# ---------------------------------------------------------------------------
function Invoke-VmDetection {
    Write-TimedMessage -Message "[8/10] Detecting VM presence via registry hardware IDs..."

    $vmIndicators = @()
    $vmScore = 0

    # Known VM hardware IDs (IDE/SCSI/Vendor)
    $vmHardwareIds = @(
        @{ Pattern = "VEN_15AD";  Name = "VMware";        Type = "Storage Controller" }
        @{ Pattern = "VEN_1AF4";  Name = "QEMU/Virtual";  Type = "Storage Controller" }
        @{ Pattern = "VEN_80EE";  Name = "Oracle VM";     Type = "Storage Controller" }
        @{ Pattern = "VEN_10DE";  Name = "NVIDIA (VM GPU pass-through check needed)"; Type = "VGA" }
        @{ Pattern = "PCI\\VEN_15AD"; Name = "VMware PCI"; Type = "PCI Device" }
        @{ Pattern = "PCI\\VEN_1AF4"; Name = "QEMU PCI";  Type = "PCI Device" }
    )

    # Check IDE/SATA/SCSI controller registry paths
    $regPaths = @(
        "HKLM:\SYSTEM\CurrentControlSet\Enum\IDE",
        "HKLM:\SYSTEM\CurrentControlSet\Enum\SCSI",
        "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI"
    )

    foreach ($regPath in $regPaths) {
        try {
            if (Test-Path -LiteralPath $regPath -ErrorAction SilentlyContinue) {
                $items = Get-ChildItem -Path $regPath -Recurse -ErrorAction SilentlyContinue |
                         Where-Object { $_.PSPath -match 'VEN_' -or $_.PSPath -match 'PCI\\VEN_' }
                foreach ($item in $items) {
                    $pathUpper = $item.PSPath.ToUpper()
                    foreach ($hwId in $vmHardwareIds) {
                        if ($pathUpper -match [regex]::Escape($hwId.Pattern.ToUpper())) {
                            $vmIndicators += @{
                                DetectionType = "RegistryHardwareID"
                                Source        = $regPath
                                MatchedID     = $hwId.Pattern
                                VMName        = $hwId.Name
                                Value         = ($item.Name -split '\\')[-1]
                            }
                            $vmScore++
                        }
                    }
                }
            }
        }
        catch {
            Add-ErrorRecord -Category "VmDetection" -Detail "Registry check failed at $regPath" -Ex $_
        }
    }

    # Check for known VM guest additions/services
    $vmServices = @(
        @{ Name = "VMTools";        DisplayPattern = "VMware";     Category = "VMware Tools" }
        @{ Name = "VBoxService";    DisplayPattern = "VirtualBox"; Category = "VirtualBox Guest Additions" }
        @{ Name = "qemu-ga";        DisplayPattern = "QEMU";       Category = "QEMU Guest Agent" }
        @{ Name = "vmicheartbeat";  DisplayPattern = "Hyper-V";    Category = "Hyper-V Integration" }
        @{ Name = "vmicrdv";        DisplayPattern = "Hyper-V";    Category = "Hyper-V Integration" }
        @{ Name = "vmictimesync";   DisplayPattern = "Hyper-V";    Category = "Hyper-V Integration" }
    )

    try {
        $runningServices = Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue
        foreach ($vmSvc in $vmServices) {
            $match = $runningServices | Where-Object { $_.Name -like "*$($vmSvc.Name)*" -or $_.DisplayName -like "*$($vmSvc.DisplayPattern)*" }
            if ($match) {
                foreach ($m in $match) {
                    $vmIndicators += @{
                        DetectionType = "VMService"
                        Source        = "CIM::Win32_Service"
                        MatchedID     = $m.Name
                        VMName        = $vmSvc.Category
                        Value         = $m.DisplayName
                    }
                    $vmScore++
                }
            }
        }
    }
    catch {
        Add-ErrorRecord -Category "VmDetection" -Detail "Service check failed" -Ex $_
    }

    # Check for known VM MAC address prefixes
    $vmMacPrefixes = @(
        @{ Prefix = "00:0C:29"; Name = "VMware" }
        @{ Prefix = "00:50:56"; Name = "VMware" }
        @{ Prefix = "00:05:69"; Name = "VMware" }
        @{ Prefix = "08:00:27"; Name = "VirtualBox" }
        @{ Prefix = "52:54:00"; Name = "QEMU/KVM" }
        @{ Prefix = "00:1C:42"; Name = "Parallels" }
        @{ Prefix = "00:03:FF"; Name = "Microsoft Hyper-V" }
    )

    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
        foreach ($adapter in $adapters) {
            $mac = ($adapter.MacAddress -replace '-', ':').ToUpper()
            foreach ($prefix in $vmMacPrefixes) {
                if ($mac -and $mac.StartsWith($prefix.Prefix.ToUpper())) {
                    $vmIndicators += @{
                        DetectionType = "MACAddress"
                        Source        = "Get-NetAdapter"
                        MatchedID     = $prefix.Prefix
                        VMName        = $prefix.Name
                        Value         = $mac
                    }
                    $vmScore++
                }
            }
        }
    }
    catch {
        Add-ErrorRecord -Category "VmDetection" -Detail "MAC address check failed" -Ex $_
    }

    # Check for VM-specific processes (best-effort)
    $vmProcesses = @("vmtoolsd", "VBoxTray", "VBoxMouse", "qemu-ga", "xenservice")
    try {
        $runningProcs = Get-Process -ErrorAction SilentlyContinue
        foreach ($p in $runningProcs) {
            if ($p.ProcessName -in $vmProcesses) {
                $vmIndicators += @{
                    DetectionType = "VMProcess"
                    Source        = "Get-Process"
                    MatchedID     = $p.ProcessName
                    VMName        = "Unknown VM"
                    Value         = $p.ProcessName
                }
                $vmScore++
            }
        }
    }
    catch {
        # Best-effort
    }

    Write-TimedMessage -Message "  -> Found $($vmIndicators.Count) VM indicators (score: $vmScore)."
    return @{
        VMScore        = $vmScore
        VMDetected     = ($vmScore -gt 0)
        Indicators     = $vmIndicators
    }
}

# ---------------------------------------------------------------------------
# 9. Clipboard Monitor / Listener Detection
# ---------------------------------------------------------------------------
function Invoke-ClipboardMonitorDetection {
    Write-TimedMessage -Message "[9/10] Checking for clipboard monitor / listener processes..."

    $suspiciousProcesses = @()
    $clipboardApis = @()

    # Known clipboard-monitoring process names (common proctoring tools)
    $suspiciousNames = @(
        "Clipboard", "ClipMon", "ClipboardListener", "ClipClient",
        "Monitor", "Proctoring", "Proctor", "SecureExam", "Respondus",
        "LockDown", "HonorLock", "ProctorU", "Examity", "PSI",
        "BVirtual", "Pearson", "ProProctor", "SEB", "SafeExamBrowser",
        "Wiris", "Mettl", "Mercer", "TalentLens", "ExamSoft",
        "RPNow", "ProctorTrack", "Proctortrack", "Kryterion"
    )

    try {
        $allProcs = Get-Process -ErrorAction SilentlyContinue
        foreach ($proc in $allProcs) {
            $name = $proc.ProcessName
            foreach ($susp in $suspiciousNames) {
                if ($name -like "*$susp*") {
                    $suspiciousProcesses += @{
                        ProcessName = $name
                        ProcessId   = $proc.Id
                        MatchedPattern = $susp
                        SessionId   = $proc.SessionId
                        MainWindowTitle = $proc.MainWindowTitle
                    }
                    break
                }
            }
        }
        Write-TimedMessage -Message "  -> Found $($suspiciousProcesses.Count) potentially suspicious proctoring processes."
    }
    catch {
        Add-ErrorRecord -Category "ClipboardMonitor" -Detail "Process scan for clipboard monitors failed" -Ex $_
    }

    # Check for user32.dll clipboard API usage in loaded modules
    # This uses Get-CimInstance Win32_ProcessStartup to look at command lines
    try {
        $processDetails = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
                          Where-Object { $_.CommandLine -match '(?i)(clipboard|hook|monitor|proctoring)' }
        foreach ($p in $processDetails) {
            $clipboardApis += @{
                ProcessName = $p.Name
                ProcessId   = $p.ProcessId
                CommandLine = $p.CommandLine
                MatchedOn   = "CommandLineKeyword"
            }
        }
    }
    catch {
        # Best-effort
    }

    # Check for SetClipboardViewer / AddClipboardFormatListener pinvoke usage
    # at process level (heuristic: processes with user32.dll loaded in non-standard contexts)
    try {
        $procsHighAlert = Get-Process | Where-Object {
            $_.ProcessName -match '(?i)(hook|spy|watch|monitor|agent|helper)' -and
            $_.MainWindowTitle -ne "" -and
            -not ($_.MainWindowTitle -match '(?i)(Visual Studio|Code|Browser|Chrome|Firefox|Explorer|Outlook)')
        } -ErrorAction SilentlyContinue
        foreach ($p in $procsHighAlert) {
            # Avoid duplicates
            $already = $suspiciousProcesses | Where-Object { $_.ProcessId -eq $p.Id }
            if (-not $already) {
                $suspiciousProcesses += @{
                    ProcessName = $p.ProcessName
                    ProcessId   = $p.Id
                    MatchedPattern = "Heuristic:HookMonitor"
                    SessionId   = $p.SessionId
                    MainWindowTitle = $p.MainWindowTitle
                }
            }
        }
    }
    catch {
        # Best-effort
    }

    return @{
        SuspiciousProcesses  = $suspiciousProcesses
        ClipboardApiMatches  = $clipboardApis
        TotalSuspiciousCount = $suspiciousProcesses.Count + $clipboardApis.Count
    }
}

# ---------------------------------------------------------------------------
# 10. Aggregation & JSON Output
# ---------------------------------------------------------------------------
function Export-DetectionReport {
    param(
        [hashtable]$Processes,
        [hashtable]$Signatures,
        [array]$TcpConnections,
        [array]$WindowTitles,
        [array]$DisplayAffinity,
        [hashtable]$Monitors,
        [array]$Services,
        [hashtable]$VmDetection,
        [hashtable]$ClipboardMonitors
    )

    $endTime = Get-Date
    $duration = $endTime - $script:StartTime

    Write-TimedMessage -Message "[10/10] Aggregating results and writing JSON report..."

    $report = @{
        Metadata = @{
            ScriptName       = "detection_sandbox.ps1"
            Version          = "1.0"
            Target           = "Windows 10/11 x64"
            RunTimestamp     = $script:StartTime.ToString("o")
            CompletionTime   = $endTime.ToString("o")
            DurationSeconds  = [math]::Round($duration.TotalSeconds, 3)
            ComputerName     = $env:COMPUTERNAME
            Username         = $env:USERNAME
            IsElevated       = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            OSVersion        = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        }
        DetectionCategories = @{
            ProcessEnumeration = @{
                Category    = "Process Detection"
                SimulatedAPI = "EnumProcesses"
                Technique   = "Enumerate running processes to find unauthorized tools"
                TotalProcesses = $Processes.Count
                Processes   = $Processes
            }
            SignatureVerification = @{
                Category     = "Digital Signature Verification"
                SimulatedAPI = "WinVerifyTrust"
                Technique    = "Verify digital signatures of running EXEs to detect unsigned/untrusted binaries"
                SampleSize   = $Signatures.SampleSize
                SignedCount  = $Signatures.SignedCount
                UnsignedCount = $Signatures.UnsignedCount
                Signatures   = $Signatures.Signatures
            }
            TcpConnectionMapping = @{
                Category      = "Network Traffic Analysis"
                SimulatedAPI  = "GetExtendedTcpTable"
                Technique     = "Map TCP connections to owning PIDs to detect unauthorized remote access"
                TotalConnections = $TcpConnections.Count
                Connections   = $TcpConnections
            }
            WindowTitles = @{
                Category      = "Process Detection"
                SimulatedAPI  = "GetForegroundWindow / EnumWindows"
                Technique     = "Enumerate visible window titles to detect suspicious applications"
                TotalWindows  = $WindowTitles.Count
                Windows       = $WindowTitles
            }
            DisplayAffinity = @{
                Category      = "Overlay/Anomaly Detection"
                SimulatedAPI  = "GetWindowDisplayAffinity"
                Technique     = "Check for windows with display affinity (WDA_MONITOR) indicating hidden overlays"
                TotalAffinityWindows = $DisplayAffinity.Count
                Windows       = $DisplayAffinity
            }
            MonitorEnumeration = @{
                Category      = "Overlay/Anomaly Detection"
                SimulatedAPI  = "EnumDisplayMonitors"
                Technique     = "Enumerate monitors to detect virtual displays or inconsistencies"
                TotalMonitors = $Monitors.Count
                PrimaryInfo   = $Monitors.PrimaryInfo
                Monitors      = $Monitors.Monitors
            }
            ServiceEnumeration = @{
                Category      = "Process Detection"
                SimulatedAPI  = "EnumServicesStatusEx"
                Technique     = "Enumerate running services with binary paths and signatures"
                TotalServices  = $Services.Count
                Services      = $Services
            }
            VmDetection = @{
                Category      = "VM Detection"
                SimulatedAPI  = "Registry Enumeration + MAC Check + Process Check"
                Technique     = "Detect virtualized environment via hardware IDs, services, MAC prefixes, and processes"
                VMScore       = $VmDetection.VMScore
                VMDetected    = $VmDetection.VMDetected
                Indicators    = $VmDetection.Indicators
            }
            ClipboardMonitorDetection = @{
                Category      = "Process Detection"
                SimulatedAPI  = "Process Scan + CommandLine Heuristics"
                Technique     = "Detect clipboard monitoring / proctoring software via process names and command lines"
                SuspiciousCount = $ClipboardMonitors.TotalSuspiciousCount
                SuspiciousProcesses = $ClipboardMonitors.SuspiciousProcesses
                ClipboardApiMatches = $ClipboardMonitors.ClipboardApiMatches
            }
        }
        Errors = $script:Errors
        TotalErrors = $script:Errors.Count
    }

    # Write JSON output
    $outputDir = Split-Path -Path $OutputPath -Parent
    if (-not (Test-Path -LiteralPath $outputDir)) {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        Write-TimedMessage -Message "  -> Created output directory: $outputDir"
    }

    try {
        $reportJson = $report | ConvertTo-Json -Depth 10 -ErrorAction Stop
        Set-Content -Path $OutputPath -Value $reportJson -Encoding UTF8 -ErrorAction Stop
        Write-TimedMessage -Message "  -> Report written to: $OutputPath"
        Write-TimedMessage -Message "  -> File size: $((Get-Item -Path $OutputPath).Length) bytes"
    }
    catch {
        Add-ErrorRecord -Category "JsonOutput" -Detail "Failed to write JSON report" -Ex $_
        # Fallback: write to temp
        $fallbackPath = Join-Path -Path $env:TEMP -ChildPath "detection_sandbox_fallback.json"
        try {
            $report | ConvertTo-Json -Depth 10 | Set-Content -Path $fallbackPath -Encoding UTF8
            Write-TimedMessage -Message "  -> Fallback report written to: $fallbackPath" -Level "WARN"
        }
        catch {
            Add-ErrorRecord -Category "JsonOutput" -Detail "Fallback write also failed" -Ex $_
        }
    }

    return $report
}

# ---------------------------------------------------------------------------
# Main Orchestrator
# ---------------------------------------------------------------------------
function Invoke-DetectionSandbox {
    Write-TimedMessage -Message "==============================================" -Level "INFO"
    Write-TimedMessage -Message " DETECTION SANDBOX v1.0" -Level "INFO"
    Write-TimedMessage -Message " Stealth Remote Control Project" -Level "INFO"
    Write-TimedMessage -Message "==============================================" -Level "INFO"
    Write-TimedMessage -Message "Started at: $($script:StartTime.ToString('o'))"
    Write-TimedMessage -Message "Output:     $OutputPath"
    Write-TimedMessage -Message ""

    # Run all detection phases
    $processes   = Invoke-ProcessEnumeration
    $signatures  = Invoke-SignatureCheck -Processes $processes
    $tcpConns    = Invoke-TcpConnectionMapping
    $windows     = Invoke-WindowTitleCheck
    $affinity    = Invoke-DisplayAffinityCheck
    $monitors    = Invoke-MonitorEnumeration
    $services    = Invoke-ServiceEnumeration
    $vmDetection = Invoke-VmDetection
    $clipboards  = Invoke-ClipboardMonitorDetection

    Write-TimedMessage -Message ""
    Write-TimedMessage -Message "Aggregating and exporting report..."
    $report = Export-DetectionReport -Processes $processes -Signatures $signatures -TcpConnections $tcpConns `
        -WindowTitles $windows -DisplayAffinity $affinity -Monitors $monitors -Services $services `
        -VmDetection $vmDetection -ClipboardMonitors $clipboards

    Write-TimedMessage -Message ""
    Write-TimedMessage -Message "==============================================" -Level "INFO"
    Write-TimedMessage -Message " DETECTION SANDBOX COMPLETE" -Level "INFO"
    Write-TimedMessage -Message " Total errors: $($script:Errors.Count)" -Level "INFO"
    if ($script:Errors.Count -gt 0) {
        Write-TimedMessage -Message " Review Errors array in JSON for details." -Level "WARN"
    }
    Write-TimedMessage -Message "==============================================" -Level "INFO"

    return $report
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
# Resolve output path relative to script location if relative
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath $OutputPath
}

# Ensure we resolve ../ relative parts
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

$null = Invoke-DetectionSandbox
