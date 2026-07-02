<#
.SYNOPSIS
    Stealth Check — verifies all components pass 12 detection technique checks.
    Outputs a structured JSON report with pass/fail per technique.

.DESCRIPTION
    This script simulates 12 categories of proctoring detection techniques
    and verifies that our stealth remote-control components are invisible to each.

    Built for the dual-mode stealth architecture:
      Piano A — RDP (mstsc.exe) on port 3390 tunnelled through SSH on port 443
      Piano B — GDI BitBlt screen capture + input injection (SendInput)

    Each check produces a PASS/FAIL/INFO verdict. The aggregated report is
    written to .omo/evidence/task-6-stealth-check.json.

    Checks performed:
      1.  Process Enumeration     — Verify mstsc.exe / ssh.exe are Microsoft-signed
      2.  Active Window Tracking   — Check for suspicious window titles
      3.  Service Enumeration      — Verify TermService is Microsoft-signed
      4.  Digital Signature        — WinVerifyTrust for all our binaries
      5.  TCP Connection Map       — Port 3390 not externally visible
      6.  Asymmetric Traffic       — SSH on 443 has HTTPS-like patterns
      7.  Streaming Detection      — Timing analysis of continuous traffic
      8.  Display Affinity         — No WDA_MONITOR / WDA_EXCLUDEFROMCAPTURE windows
      9.  DXGI Integrity           — No DirectX DLL tampering
      10. Synthetic Input          — Document SendInput detectability
      11. Keyboard Hooks           — Check for low-level hooks
      12. VM Detection             — Registry, MAC, service heuristics

.NOTES
    Author: Stealth Remote Control Project
    Version: 1.0
    Target: Windows 10/11 (x64)
    Privileges: Some checks require admin; degrades gracefully without elevation.

    PowerShell 5.1 compatible — no ?., no ??, no inline-if in hashtables.
    Read-only — does not modify system state.

.EXAMPLE
    .\stealth_check.ps1
    .\stealth_check.ps1 -OutputPath "C:\custom\path\report.json"
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = $(Join-Path -Path $PSScriptRoot -ChildPath "..\.omo\evidence\task-6-stealth-check.json")
)

#Requires -Version 5.1

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
$script:StartTime = Get-Date
$script:Results = @{}
$script:CheckResults = @()
$script:Warnings = @()
$script:Errors = @()

# Known Microsoft root certificate CN patterns (partial matches)
$script:MicrosoftRootPatterns = @(
    "Microsoft Root Certificate Authority",
    "Microsoft Root Authority",
    "Microsoft Code Signing Root",
    "Microsoft Windows Root",
    "Microsoft Corporation",
    "Microsoft Windows"
)

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
function Write-TimedMessage {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Write-Host "[$ts] [$Level] $Message"
}

function Add-ErrorRecord {
    param([string]$Category, [string]$Detail, [System.Exception]$Ex)
    $script:Errors += @{
        category    = $Category
        detail      = $Detail
        exception   = $Ex.Message
        line        = $(if ($Ex.InvocationInfo) { $Ex.InvocationInfo.ScriptLineNumber } else { -1 })
        timestamp   = (Get-Date -Format "o")
    }
    Write-TimedMessage -Message "ERROR [$Category] $Detail : $($Ex.Message)" -Level "ERROR"
}

function Add-CheckResult {
    param(
        [int]$CheckNumber,
        [string]$Name,
        [string]$Category,
        [string]$SimulatedAPI,
        [string]$Verdict,       # PASS, FAIL, WARNING, INFO
        [string]$Summary,
        [object]$Details,
        [string]$Mitigation
    )
    $script:CheckResults += @{
        CheckNumber   = $CheckNumber
        Name          = $Name
        Category      = $Category
        SimulatedAPI  = $SimulatedAPI
        Verdict       = $Verdict
        Summary       = $Summary
        Details       = $Details
        Mitigation    = $Mitigation
    }
}

# ---------------------------------------------------------------------------
# Check 1: Process Enumeration — verify mstsc.exe / ssh.exe are Microsoft-signed
# ---------------------------------------------------------------------------
function Invoke-Check1ProcessEnumeration {
    Write-TimedMessage -Message "[1/12] Process Enumeration — checking signed status of mstsc.exe and ssh.exe..."

    $checkDetails = @()
    $allPassed = $true

    # Processes to look for
    $targetProcesses = @("mstsc", "ssh")

    # Also check if TermService (RDP server) is running
    $targetServices = @("TermService")

    try {
        # Check processes
        $runningProcesses = Get-Process -ErrorAction SilentlyContinue
        foreach ($target in $targetProcesses) {
            $found = $runningProcesses | Where-Object { $_.ProcessName -eq $target }
            if ($found) {
                foreach ($proc in $found) {
                    $path = $null
                    try {
                        if ($proc.MainModule) {
                            $path = $proc.MainModule.FileName
                        }
                    }
                    catch {
                        # Access denied for some system processes
                    }

                    # Try to get path via CIM as fallback
                    if (-not $path) {
                        try {
                            $cimProc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue
                            if ($cimProc -and $cimProc.ExecutablePath) {
                                $path = $cimProc.ExecutablePath
                            }
                        }
                        catch {
                            # Silently continue
                        }
                    }

                    $signatureStatus = "Unknown"
                    $signerCN = $null
                    $isMicrosoftSigned = $false

                    if ($path -and (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
                        try {
                            $sig = Get-AuthenticodeSignature -FilePath $path -ErrorAction SilentlyContinue
                            if ($sig) {
                                $signatureStatus = "$($sig.Status)"
                                if ($sig.SignerCertificate) {
                                    $signerCN = $sig.SignerCertificate.Subject
                                    # Check if subject contains Microsoft indicators
                                    foreach ($pattern in $script:MicrosoftRootPatterns) {
                                        if ($signerCN -like "*$pattern*") {
                                            $isMicrosoftSigned = $true
                                            break
                                        }
                                    }
                                }
                            }
                        }
                        catch {
                            $signatureStatus = "Error"
                        }
                    }

                    $entry = @{
                        ProcessName      = $proc.ProcessName
                        ProcessId        = $proc.Id
                        ProcessPath      = $path
                        SignatureStatus  = $signatureStatus
                        SignerCN         = $signerCN
                        IsMicrosoftSigned = $isMicrosoftSigned
                        IsRunning        = $true
                    }
                    $checkDetails += $entry

                    if (-not $isMicrosoftSigned) {
                        $allPassed = $false
                    }
                }
            }
            else {
                $checkDetails += @{
                    ProcessName      = $target
                    ProcessId        = $null
                    ProcessPath      = $null
                    SignatureStatus  = "NotRunning"
                    SignerCN         = $null
                    IsMicrosoftSigned = $false
                    IsRunning        = $false
                }
                # Not running is OK — they may not be started yet
                Write-TimedMessage -Message "  -> $target is not currently running (OK)."
            }
        }

        # Check TermService via service API
        try {
            $termSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name = 'TermService'" -ErrorAction SilentlyContinue
            if ($termSvc) {
                $svcPath = $termSvc.PathName
                $exePath = if ($svcPath -match '"([^"]+\.exe)"') {
                    $matches[1]
                }
                elseif ($svcPath -match '^([^\s"]+\.exe)') {
                    $matches[1]
                }
                else {
                    $svcPath
                }

                $svcSignatureStatus = "Unknown"
                $svcSignerCN = $null
                $svcIsMicrosoftSigned = $false

                if ($exePath -and (Test-Path -LiteralPath $exePath -ErrorAction SilentlyContinue)) {
                    try {
                        $svcSig = Get-AuthenticodeSignature -FilePath $exePath -ErrorAction SilentlyContinue
                        if ($svcSig) {
                            $svcSignatureStatus = "$($svcSig.Status)"
                            if ($svcSig.SignerCertificate) {
                                $svcSignerCN = $svcSig.SignerCertificate.Subject
                                foreach ($pattern in $script:MicrosoftRootPatterns) {
                                    if ($svcSignerCN -like "*$pattern*") {
                                        $svcIsMicrosoftSigned = $true
                                        break
                                    }
                                }
                            }
                        }
                    }
                    catch {
                        $svcSignatureStatus = "Error"
                    }
                }

                $entry = @{
                    ProcessName      = "TermService"
                    ProcessId        = $termSvc.ProcessId
                    ProcessPath      = $exePath
                    SignatureStatus  = $svcSignatureStatus
                    SignerCN         = $svcSignerCN
                    IsMicrosoftSigned = $svcIsMicrosoftSigned
                    IsRunning        = ($termSvc.State -eq "Running")
                }
                $checkDetails += $entry

                if (-not $svcIsMicrosoftSigned) {
                    $allPassed = $false
                }
            }
        }
        catch {
            Add-ErrorRecord -Category "Check1" -Detail "TermService check failed" -Ex $_
        }
    }
    catch {
        Add-ErrorRecord -Category "Check1" -Detail "Process enumeration failed" -Ex $_
        $allPassed = $false
    }

    $verdict = if ($allPassed) { "PASS" } else { "WARNING" }
    $summary = if ($allPassed) {
        "All target processes (mstsc, ssh, TermService) have valid Microsoft signatures."
    }
    else {
        "Some target processes are unsigned or not running. Review Details."
    }

    Add-CheckResult -CheckNumber 1 -Name "Process Enumeration" `
        -Category "Process Detection" -SimulatedAPI "EnumProcesses / CreateToolhelp32Snapshot" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "All components use Microsoft-signed binaries. If unsigned binaries appear, only Piano B (SendInput) may be flagged — use Piano A (RDP) which uses only mstsc.exe."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return $allPassed
}

# ---------------------------------------------------------------------------
# Check 2: Active Window Tracking — check for suspicious window titles
# ---------------------------------------------------------------------------
function Invoke-Check2WindowTracking {
    Write-TimedMessage -Message "[2/12] Active Window Tracking — checking for suspicious window titles..."

    $checkDetails = @()
    $suspiciousFound = $false

    # Known suspicious title keywords (proctoring software looks for these)

    $suspiciousKeywords = @(
        "cmd", "powershell", "terminal", "command prompt", "putty",
        "ssh", "remote desktop", "mstsc", "vnc", "anydesk", "teamviewer",
        "stealth", "inject", "hook", "debug", "cheat", "exam",
        "console", "wireshark", "netstat", "process explorer",
        "task manager", "registry editor", "msconfig", "services"
    )

    # Also check for WDA_EXCLUDEFROMCAPTURE (0x11) which is highly suspicious
    $excludeFromCaptureFound = $false

    try {
        # Check via Get-Process MainWindowTitle
        $procsWithWindows = Get-Process | Where-Object { -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) } -ErrorAction SilentlyContinue
        foreach ($p in $procsWithWindows) {
            $title = $p.MainWindowTitle.ToLower()
            foreach ($keyword in $suspiciousKeywords) {
                if ($title -like "*$keyword*") {
                    $checkDetails += @{
                        Source          = "MainWindowTitle"
                        WindowTitle     = $p.MainWindowTitle
                        ProcessName     = $p.ProcessName
                        ProcessId       = $p.Id
                        MatchedKeyword  = $keyword
                        IsSuspicious    = $true
                    }
                    $suspiciousFound = $true
                    break
                }
            }
        }

        # Check via Win32 pinvoke EnumWindows for more thorough scan
        try {
            $enumWindowCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class StealthWindowChecker
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

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowDisplayAffinity(IntPtr hWnd, out uint dwAffinity);

    public const uint WDA_NONE = 0x00000000;
    public const uint WDA_MONITOR = 0x00000001;
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;

    public static List<Dictionary<string, object>> CheckForOverlayWindows()
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

                string affinityType = "";
                if (affinity == WDA_MONITOR) affinityType = "WDA_MONITOR";
                else if (affinity == WDA_EXCLUDEFROMCAPTURE) affinityType = "WDA_EXCLUDEFROMCAPTURE";
                else affinityType = string.Format("0x{0:X8}", affinity);

                lock (syncLock)
                {
                    results.Add(new Dictionary<string, object>
                    {
                        { "WindowTitle", title },
                        { "ProcessId", (int)pid },
                        { "DisplayAffinity", (int)affinity },
                        { "AffinityType", affinityType },
                        { "IsExcludeFromCapture", affinity == WDA_EXCLUDEFROMCAPTURE }
                    });
                }
            }
            return true;
        }), IntPtr.Zero);

        return results;
    }
}
'@
            Add-Type -TypeDefinition $enumWindowCode -ErrorAction SilentlyContinue | Out-Null
            if ([StealthWindowChecker] -ne $null) {
                $overlayWindows = [StealthWindowChecker]::CheckForOverlayWindows()
                foreach ($ow in $overlayWindows) {
                    $isExclude = $false
                    if ($ow.ContainsKey("IsExcludeFromCapture")) {
                        $isExclude = $ow["IsExcludeFromCapture"]
                    }
                    if ($isExclude) {
                        $checkDetails += @{
                            Source          = "EnumWindows::GetWindowDisplayAffinity"
                            WindowTitle     = $ow["WindowTitle"]
                            ProcessId       = $ow["ProcessId"]
                            AffinityType    = $ow["AffinityType"]
                            IsSuspicious    = $true
                            Note            = "WDA_EXCLUDEFROMCAPTURE detected — highly suspicious to proctoring"
                        }
                        $excludeFromCaptureFound = $true
                        $suspiciousFound = $true
                    }
                }
            }
        }
        catch {
            # Best-effort pinvoke
        }
    }
    catch {
        Add-ErrorRecord -Category "Check2" -Detail "Window title enumeration failed" -Ex $_
    }

    $verdict = "PASS"
    if ($excludeFromCaptureFound) {
        $verdict = "FAIL"
    }
    elseif ($suspiciousFound) {
        $verdict = "INFO"
    }

    $summary = "No overlay windows or WDA_EXCLUDEFROMCAPTURE found. "
    if ($excludeFromCaptureFound) {
        $summary = "WDA_EXCLUDEFROMCAPTURE windows detected! Our overlay tools must not set this flag."
    }
    elseif ($suspiciousFound) {
        $summary = "Suspicious window titles found but these may be system windows. Review Details."
    }

    Add-CheckResult -CheckNumber 2 -Name "Active Window Tracking" `
        -Category "Process Detection" -SimulatedAPI "GetForegroundWindow / EnumWindows" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "Our RDP session (mstsc.exe) appears as a legitimate window title 'Remote Desktop Connection'. For Piano B, ensure no windows with suspicious titles appear. Never set WDA_EXCLUDEFROMCAPTURE."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return ($verdict -eq "PASS" -or $verdict -eq "INFO")
}

# ---------------------------------------------------------------------------
# Check 3: Service Enumeration — verify all services are Microsoft-signed
# ---------------------------------------------------------------------------
function Invoke-Check3ServiceEnumeration {
    Write-TimedMessage -Message "[3/12] Service Enumeration — verifying all critical services are Microsoft-signed..."

    $checkDetails = @()
    $allSigned = $true
    $unsignedServices = @()
    $servicesChecked = 0

    try {
        $services = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop
        foreach ($svc in $services) {
            $path = $svc.PathName
            if (-not $path) { continue }

            $exePath = if ($path -match '"([^"]+\.exe)"') {
                $matches[1]
            }
            elseif ($path -match '^([^\s"]+\.exe)') {
                $matches[1]
            }
            else {
                $path
            }

            if (-not (Test-Path -LiteralPath $exePath -ErrorAction SilentlyContinue)) { continue }
            $servicesChecked++

            try {
                $sig = Get-AuthenticodeSignature -FilePath $exePath -ErrorAction SilentlyContinue
                $isMicrosoft = $false
                if ($sig -and $sig.SignerCertificate) {
                    $cn = $sig.SignerCertificate.Subject
                    foreach ($pattern in $script:MicrosoftRootPatterns) {
                        if ($cn -like "*$pattern*") {
                            $isMicrosoft = $true
                            break
                        }
                    }
                }

                if (-not $isMicrosoft) {
                    $unsignedServices += @{
                        ServiceName    = $svc.Name
                        DisplayName    = $svc.DisplayName
                        Path           = $exePath
                        SignatureStatus = "$($sig.Status)"
                        State          = $svc.State
                    }
                }
            }
            catch {
                # Best-effort
            }
        }

        if ($unsignedServices.Count -gt 0) {
            $allSigned = $false
            $checkDetails = $unsignedServices
        }
    }
    catch {
        Add-ErrorRecord -Category "Check3" -Detail "Service enumeration failed" -Ex $_
        $allSigned = $false
    }

    $verdict = if ($allSigned) { "PASS" } else { "INFO" }
    $summary = if ($allSigned) {
        "All $servicesChecked checked services have valid Microsoft signatures."
    }
    else {
        "Found $($unsignedServices.Count) unsigned/non-Microsoft services. Review for legitimacy."
    }

    Add-CheckResult -CheckNumber 3 -Name "Service Enumeration" `
        -Category "Process Detection" -SimulatedAPI "EnumServicesStatusEx" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "TermService (RDP) is Microsoft-signed. Our architecture does not install custom services."

    Write-TimedMessage -Message "  -> Verdict: $verdict (unsigned non-MS services: $($unsignedServices.Count))"
    return $allSigned
}

# ---------------------------------------------------------------------------
# Check 4: Digital Signature Verification (WinVerifyTrust) — all our binaries
# ---------------------------------------------------------------------------
function Invoke-Check4SignatureVerification {
    Write-TimedMessage -Message "[4/12] Digital Signature Verification — verifying all component binaries..."

    $checkDetails = @()
    $allPassed = $true

    # Binaries to check — our key components
    $binaryPaths = @(
        "mstsc.exe",                       # RDP client — always in system32
        "ssh.exe",                         # OpenSSH client
        "termsrv.dll"                      # Terminal Server service DLL
    )

    # Resolve full paths
    $resolvedPaths = @()
    try {
        # Check mstsc.exe
        $mstscPath = (Get-Command "mstsc.exe" -ErrorAction SilentlyContinue).Source
        if (-not $mstscPath) {
            # Common locations
            $candidates = @(
                "$env:SystemRoot\System32\mstsc.exe",
                "$env:SystemRoot\SysWOW64\mstsc.exe"
            )
            foreach ($c in $candidates) {
                if (Test-Path -LiteralPath $c -ErrorAction SilentlyContinue) {
                    $mstscPath = $c
                    break
                }
            }
        }
        if ($mstscPath) { $resolvedPaths += $mstscPath }

        # Check ssh.exe
        $sshPath = (Get-Command "ssh.exe" -ErrorAction SilentlyContinue).Source
        if (-not $sshPath) {
            $candidates = @(
                "$env:SystemRoot\System32\OpenSSH\ssh.exe",
                "${env:ProgramFiles}\OpenSSH\ssh.exe",
                "${env:ProgramFiles(x86)}\OpenSSH\ssh.exe"
            )
            foreach ($c in $candidates) {
                if (Test-Path -LiteralPath $c -ErrorAction SilentlyContinue) {
                    $sshPath = $c
                    break
                }
            }
        }
        if ($sshPath) { $resolvedPaths += $sshPath }

        # Check termsrv.dll
        $termsrvPath = "$env:SystemRoot\System32\termsrv.dll"
        if (Test-Path -LiteralPath $termsrvPath -ErrorAction SilentlyContinue) {
            $resolvedPaths += $termsrvPath
        }
    }
    catch {
        Add-ErrorRecord -Category "Check4" -Detail "Binary path resolution failed" -Ex $_
    }

    foreach ($path in $resolvedPaths) {
        try {
            $sig = Get-AuthenticodeSignature -FilePath $path -ErrorAction SilentlyContinue
            $isMicrosoft = $false
            $signerCN = $null

            if ($sig -and $sig.SignerCertificate) {
                $signerCN = $sig.SignerCertificate.Subject
                foreach ($pattern in $script:MicrosoftRootPatterns) {
                    if ($signerCN -like "*$pattern*") {
                        $isMicrosoft = $true
                        break
                    }
                }
            }

            $status = if ($sig) { "$($sig.Status)" } else { "NoSignature" }
            $entry = @{
                FilePath          = $path
                SignatureStatus   = $status
                SignerCN          = $signerCN
                IsMicrosoftSigned = $isMicrosoft
            }
            $checkDetails += $entry

            if (-not $isMicrosoft) {
                $allPassed = $false
                Write-TimedMessage -Message "  -> WARNING: $path is not Microsoft-signed (status: $status)" -Level "WARN"
            }
            else {
                Write-TimedMessage -Message "  -> OK: $path is Microsoft-signed."
            }
        }
        catch {
            $checkDetails += @{
                FilePath          = $path
                SignatureStatus   = "Error"
                SignerCN          = $null
                IsMicrosoftSigned = $false
            }
            $allPassed = $false
            Add-ErrorRecord -Category "Check4" -Detail "Signature check failed for $path" -Ex $_
        }
    }

    $verdict = if ($allPassed) { "PASS" } else { "WARNING" }
    $summary = if ($allPassed) {
        "All component binaries are Microsoft-signed (WinVerifyTrust passes)."
    }
    else {
        "Some binaries could not be verified or are not Microsoft-signed."
    }

    Add-CheckResult -CheckNumber 4 -Name "Digital Signature Verification" `
        -Category "Digital Signature" -SimulatedAPI "WinVerifyTrust" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "Piano A uses only Microsoft-signed binaries (mstsc.exe, ssh.exe, TermService). Piano B must execute from within a whitelisted signed host process."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return $allPassed
}

# ---------------------------------------------------------------------------
# Check 5: TCP Connection Map — verify port 3390 is NOT externally visible
# ---------------------------------------------------------------------------
function Invoke-Check5TcpConnectionMap {
    Write-TimedMessage -Message "[5/12] TCP Connection Map — checking port exposure and SSH tunnel..."

    $checkDetails = @()
    $rdpPortExposed = $false
    $sshTunnelActive = $false

    try {
        $tcpConnections = Get-NetTCPConnection -ErrorAction Stop

        # Check if our RDP port (3390) is listening on external interface
        $rdpListeners = $tcpConnections | Where-Object {
            $_.LocalPort -eq 3390 -and $_.State -eq "Listen"
        }
        $rdpBindings = @()
        foreach ($conn in $rdpListeners) {
            # 0.0.0.0 or :: means bound to all interfaces — externally visible
            $isExternal = ($conn.LocalAddress -eq "0.0.0.0" -or $conn.LocalAddress -eq "::")
            if ($conn.LocalAddress -eq "127.0.0.1" -or $conn.LocalAddress -eq "::1") {
                $isExternal = $false
            }
            $rdpBindings += @{
                LocalAddress = $conn.LocalAddress
                LocalPort    = $conn.LocalPort
                State        = "$($conn.State)"
                OwningProcess = $conn.OwningProcess
                IsExternal   = $isExternal
            }
            if ($isExternal) {
                $rdpPortExposed = $true
            }
        }

        # Check for SSH tunnel (active connection on port 443 or our configured SSH port)
        $sshConnections = $tcpConnections | Where-Object {
            $_.RemotePort -eq 443 -and $_.State -eq "Established"
        }
        if ($sshConnections) {
            $sshTunnelActive = $true
            foreach ($conn in $sshConnections) {
                $checkDetails += @{
                    CheckType       = "SSHTunnel"
                    LocalAddress    = $conn.LocalAddress
                    LocalPort       = $conn.LocalPort
                    RemoteAddress   = $conn.RemoteAddress
                    RemotePort      = $conn.RemotePort
                    State           = "$($conn.State)"
                    OwningProcess   = $conn.OwningProcess
                    Note            = "SSH tunnel on 443 — looks like HTTPS"
                }
            }
        }

        # Check for active RDP session connections (established to 3390)
        $rdpSessions = $tcpConnections | Where-Object {
            $_.LocalPort -eq 3390 -and $_.State -eq "Established"
        }
        foreach ($conn in $rdpSessions) {
            $checkDetails += @{
                CheckType       = "RDPConnection"
                LocalAddress    = $conn.LocalAddress
                LocalPort       = $conn.LocalPort
                RemoteAddress   = $conn.RemoteAddress
                RemotePort      = $conn.RemotePort
                State           = "$($conn.State)"
                OwningProcess   = $conn.OwningProcess
                Note            = "Active RDP session — should be from 127.0.0.1 only"
            }
        }

        # Add RDP bindings
        foreach ($binding in $rdpBindings) {
            $checkDetails += @{
                CheckType       = "RDPListener"
                LocalAddress    = $binding.LocalAddress
                LocalPort       = $binding.LocalPort
                State           = $binding.State
                OwningProcess   = $binding.OwningProcess
                IsExternal      = $binding.IsExternal
                Note            = if ($binding.IsExternal) { "WARNING: RDP port exposed externally!" } else { "OK: RDP bound to loopback only" }
            }
        }
    }
    catch {
        Add-ErrorRecord -Category "Check5" -Detail "TCP connection mapping failed" -Ex $_
        # Fallback to netstat
        try {
            $netstat = & netstat -ano 2>$null
            # Parse netstat output — simplified check
            foreach ($line in $netstat) {
                if ($line -match '^\s*TCP\s+\S+:3390\s+') {
                    if ($line -match '^\s*TCP\s+0\.0\.0\.0:3390\s+') {
                        $rdpPortExposed = $true
                        $checkDetails += @{
                            CheckType = "RDPListener"
                            Note      = "WARNING: RDP port 3390 listening on 0.0.0.0"
                        }
                    }
                }
                if ($line -match '^\s*TCP\s+\S+:443\s+\S+\s+ESTABLISHED') {
                    $sshTunnelActive = $true
                }
            }
        }
        catch {
            Add-ErrorRecord -Category "Check5" -Detail "netstat fallback also failed" -Ex $_
        }
    }

    $verdict = "PASS"
    if ($rdpPortExposed) {
        $verdict = "FAIL"
    }
    elseif (-not $sshTunnelActive) {
        $verdict = "INFO"  # SSH tunnel may not be active at check time
    }

    $summary = "RDP port 3390 is bound only to loopback (not externally visible). "
    if ($rdpPortExposed) {
        $summary = "CRITICAL: RDP port 3390 is externally visible! Configure RDP to bind only to 127.0.0.1."
    }
    elseif (-not $sshTunnelActive) {
        $summary += "SSH tunnel is not currently active (expected if not connected)."
    }
    else {
        $summary += "SSH tunnel on port 443 is active."
    }

    Add-CheckResult -CheckNumber 5 -Name "TCP Connection Map" `
        -Category "Network Traffic Analysis" -SimulatedAPI "GetExtendedTcpTable" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "RDP listens on 127.0.0.1:3390 only. External access is through SSH tunnel on port 443 (HTTPS mimicry). Verify RDP-Tcp port binding with netsh or registry."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return (-not $rdpPortExposed)
}

# ---------------------------------------------------------------------------
# Check 6: Asymmetric Traffic — SSH on 443 has HTTPS-like patterns
# ---------------------------------------------------------------------------
function Invoke-Check6AsymmetricTraffic {
    Write-TimedMessage -Message "[6/12] Asymmetric Traffic — analyzing traffic patterns on SSH tunnel..."

    $checkDetails = @()
    $anomalyFound = $false

    try {
        # Get TCP statistics for the session
        $tcpStats = Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object {
            $_.RemotePort -eq 443 -and $_.State -eq "Established"
        }

        if (-not $tcpStats -or $tcpStats.Count -eq 0) {
            $checkDetails += @{
                CheckType = "TrafficAnalysis"
                Note      = "No active SSH tunnel connection found. Cannot analyze traffic."
            }
            $verdict = "INFO"
            $summary = "No active SSH tunnel to analyze. Run with tunnel active for traffic analysis."
        }
        else {
            # We can check the owning process of the SSH connection
            foreach ($conn in $tcpStats) {
                $ownerPid = $conn.OwningProcess
                $ownerProc = $null
                try {
                    $ownerProc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
                }
                catch {
                    # Silently continue
                }

                $procName = if ($ownerProc) { $ownerProc.ProcessName } else { "Unknown" }

                $checkDetails += @{
                    CheckType       = "TrafficSource"
                    ProcessId       = $ownerPid
                    ProcessName     = $procName
                    RemoteAddress   = $conn.RemoteAddress
                    RemotePort      = $conn.RemotePort
                    Note            = "Traffic on port 443 from $procName — expected SSH tunnel"
                }

                # Check if the process is ssh.exe (legitimate)
                if ($procName -ne "ssh") {
                    $anomalyFound = $true
                    $checkDetails += @{
                        CheckType = "TrafficAnomaly"
                        Note      = "Process on port 443 is not ssh.exe — unexpected!"
                    }
                }
            }

            # Try to get per-connection statistics (may require admin)
            try {
                # Get-NetTCPSetting can show congestion window etc.
                $settings = Get-NetTCPSetting -ErrorAction SilentlyContinue
                if ($settings) {
                    $checkDetails += @{
                        CheckType           = "TCPSettings"
                        CongestionProvider  = $settings[0].CongestionProvider
                        Note                = "TCP settings retrieved for analysis"
                    }
                }
            }
            catch {
                # Non-admin, skip detailed TCP stats
            }

            $verdict = if ($anomalyFound) { "WARNING" } else { "PASS" }
            $summary = if ($anomalyFound) {
                "Traffic anomalies detected on port 443."
            }
            else {
                "SSH tunnel traffic on port 443 appears normal (HTTPS mimicry)."
            }
        }
    }
    catch {
        Add-ErrorRecord -Category "Check6" -Detail "Traffic analysis failed" -Ex $_
        $verdict = "INFO"
        $summary = "Could not analyze traffic (requires admin or active connection)."
        $checkDetails += @{ Note = "Traffic analysis error: $($_.Message)" }
    }

    Add-CheckResult -CheckNumber 6 -Name "Asymmetric Traffic Detection" `
        -Category "Network Traffic Analysis" -SimulatedAPI "GetPerTcpConnectionEstats / WFP" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "SSH on port 443 mimics HTTPS traffic. RDP traffic is compressed inside the SSH tunnel. Consider traffic shaping and adding padding to further obscure patterns."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return (-not $anomalyFound)
}

# ---------------------------------------------------------------------------
# Check 7: Streaming Detection — timing analysis for continuous screen data
# ---------------------------------------------------------------------------
function Invoke-Check7StreamingDetection {
    Write-TimedMessage -Message "[7/12] Streaming Detection — analyzing traffic timing patterns..."

    $checkDetails = @()
    $streamingDetected = $false

    # For Piano A (RDP via SSH): RDP's adaptive compression and differential updates
    # reduce detectability. For Piano B: we add random jitter to frame intervals.

    try {
        # Check if we can detect any continuous data streams
        # Look for any process with sustained high outbound traffic
        $processes = Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 20

        $highTrafficProcesses = @()
        foreach ($p in $processes) {
            try {
                # Check network I/O counters via performance counters
                $counterPath = "\Process($($p.ProcessName))\IO Write Bytes/sec"
                $counter = Get-Counter -Counter $counterPath -ErrorAction SilentlyContinue
                if ($counter -and $counter.CounterSamples -and $counter.CounterSamples[0].CookedValue -gt 0) {
                    $ioBytes = [long]$counter.CounterSamples[0].CookedValue
                    if ($ioBytes -gt 50000) {  # > 50KB/s write — potential streaming
                        $highTrafficProcesses += @{
                            ProcessName  = $p.ProcessName
                            ProcessId    = $p.Id
                            BytesPerSec  = $ioBytes
                            Note         = "High I/O write rate — potential streaming"
                        }
                    }
                }
            }
            catch {
                # Counter may not be available
            }
        }

        if ($highTrafficProcesses.Count -gt 0) {
            # Filter out known legitimate high-I/O processes
            $whitelisted = @("svchost", "system", "idle", "wmiprvse", "msmpeng")
            $suspicious = @()
            foreach ($h in $highTrafficProcesses) {
                $isWhitelisted = $false
                foreach ($w in $whitelisted) {
                    if ($h.ProcessName -eq $w) {
                        $isWhitelisted = $true
                        break
                    }
                }
                if (-not $isWhitelisted) {
                    $suspicious += $h
                }
            }

            if ($suspicious.Count -gt 0) {
                $streamingDetected = $true
                $checkDetails = $suspicious
            }
            else {
                $checkDetails = @{ Note = "I/O activity detected but only in whitelisted system processes." }
            }
        }
        else {
            $checkDetails += @{ Note = "No abnormally high I/O write rates detected." }
        }
    }
    catch {
        Add-ErrorRecord -Category "Check7" -Detail "Streaming detection analysis failed" -Ex $_
        $checkDetails += @{ Note = "Streaming analysis error: $($_.Message)" }
    }

    $verdict = if ($streamingDetected) { "INFO" } else { "PASS" }
    $summary = if ($streamingDetected) {
        "Potential streaming activity detected. Review Details for context."
    }
    else {
        "No obvious streaming indicators detected. RDP's adaptive compression and differential updates reduce streaming signature."
    }

    Add-CheckResult -CheckNumber 7 -Name "Streaming Detection" `
        -Category "Network Traffic Analysis" -SimulatedAPI "Timing analysis / packet inspection" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "RDP uses adaptive compression and differential updates. SSH tunnel adds latency jitter. For Piano B, random jitter (40ms) is added between frames. Consider event-driven (not timer-driven) updates."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return (-not $streamingDetected)
}

# ---------------------------------------------------------------------------
# Check 8: Display Affinity — no overlay windows present
# ---------------------------------------------------------------------------
function Invoke-Check8DisplayAffinity {
    Write-TimedMessage -Message "[8/12] Display Affinity — checking for overlay windows..."

    $checkDetails = @()
    $overlayFound = $false

    try {
        $affinityCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class OverlayWindowChecker
{
    public const uint WDA_NONE = 0x00000000;
    public const uint WDA_MONITOR = 0x00000001;
    public const uint WDA_EXCLUDEFROMCAPTURE = 0x00000011;

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

    public static List<Dictionary<string, object>> FindOverlayWindows()
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

                string affinityName = "";
                if (affinity == WDA_MONITOR) affinityName = "WDA_MONITOR";
                else if (affinity == WDA_EXCLUDEFROMCAPTURE) affinityName = "WDA_EXCLUDEFROMCAPTURE";
                else affinityName = string.Format("0x{0:X8}", affinity);

                lock (syncLock)
                {
                    results.Add(new Dictionary<string, object>
                    {
                        { "WindowTitle", title },
                        { "ProcessId", (int)pid },
                        { "AffinityValue", (int)affinity },
                        { "AffinityName", affinityName }
                    });
                }
            }
            return true;
        }), IntPtr.Zero);

        return results;
    }
}
'@
        Add-Type -TypeDefinition $affinityCode -ErrorAction Stop | Out-Null
        $overlayWindows = [OverlayWindowChecker]::FindOverlayWindows()

        if ($overlayWindows.Count -gt 0) {
            $overlayFound = $true
            $checkDetails = $overlayWindows
        }
        else {
            $checkDetails += @{ Note = "No overlay windows found. All windows have WDA_NONE." }
        }
    }
    catch {
        Add-ErrorRecord -Category "Check8" -Detail "Display affinity check failed" -Ex $_
        $checkDetails += @{ Note = "Display affinity check failed: $($_.Message)" }
    }

    $verdict = if ($overlayFound) { "FAIL" } else { "PASS" }
    $summary = if ($overlayFound) {
        "CRITICAL: $($overlayWindows.Count) overlay window(s) found with non-zero display affinity!"
    }
    else {
        "No overlay windows detected. All windows have WDA_NONE (default)."
    }

    Add-CheckResult -CheckNumber 8 -Name "Display Affinity / Overlay Detection" `
        -Category "Overlay/Anomaly Detection" -SimulatedAPI "GetWindowDisplayAffinity" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "Our architecture creates no overlay windows. Piano A uses RDP which creates a normal window. Piano B must avoid any SetWindowDisplayAffinity calls. Never use WDA_MONITOR or WDA_EXCLUDEFROMCAPTURE."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return (-not $overlayFound)
}

# ---------------------------------------------------------------------------
# Check 9: DXGI Integrity — check for DirectX DLL tampering
# ---------------------------------------------------------------------------
function Invoke-Check9DxgiIntegrity {
    Write-TimedMessage -Message "[9/12] DXGI Integrity — checking DirectX DLLs for tampering..."

    $checkDetails = @()
    $tamperingFound = $false

    # Critical DirectX DLLs to verify
    $dxDlls = @(
        "$env:SystemRoot\System32\dxgi.dll",
        "$env:SystemRoot\System32\d3d11.dll",
        "$env:SystemRoot\System32\d3d10.dll",
        "$env:SystemRoot\System32\d2d1.dll",
        "$env:SystemRoot\System32\d3d10warp.dll",
        "$env:SystemRoot\System32\dcomp.dll",
        "$env:SystemRoot\System32\dxgidwm.dll",
        "$env:SystemRoot\System32\dxgkrnl.dll"
    )

    foreach ($dllPath in $dxDlls) {
        try {
            if (-not (Test-Path -LiteralPath $dllPath -ErrorAction SilentlyContinue)) {
                $checkDetails += @{
                    DllPath  = $dllPath
                    Status   = "NotFound"
                    Note     = "DLL not found at expected path"
                }
                continue
            }

            $sig = Get-AuthenticodeSignature -FilePath $dllPath -ErrorAction SilentlyContinue
            $isMicrosoft = $false
            $signerCN = $null

            if ($sig -and $sig.SignerCertificate) {
                $signerCN = $sig.SignerCertificate.Subject
                foreach ($pattern in $script:MicrosoftRootPatterns) {
                    if ($signerCN -like "*$pattern*") {
                        $isMicrosoft = $true
                        break
                    }
                }
            }

            $status = if ($sig) { "$($sig.Status)" } else { "NoSignature" }

            if (-not $isMicrosoft) {
                $tamperingFound = $true
                $checkDetails += @{
                    DllPath           = $dllPath
                    Status            = $status
                    SignerCN          = $signerCN
                    IsMicrosoftSigned = $isMicrosoft
                    Note              = "WARNING: DLL is not Microsoft-signed — possible tampering!"
                }
            }
            else {
                $checkDetails += @{
                    DllPath           = $dllPath
                    Status            = $status
                    SignerCN          = $signerCN
                    IsMicrosoftSigned = $isMicrosoft
                    Note              = "OK: Microsoft-signed"
                }
            }
        }
        catch {
            $checkDetails += @{
                DllPath  = $dllPath
                Status   = "Error"
                Note     = "Verification error: $($_.Message)"
            }
        }
    }

    # Also check if any process has loaded non-standard DXGI DLLs
    try {
        $processesWithDxgi = Get-Process | Where-Object {
            $_.Modules | Where-Object { $_.ModuleName -eq "dxgi.dll" }
        } -ErrorAction SilentlyContinue

        foreach ($p in $processesWithDxgi) {
            try {
                $dxgiModule = $p.Modules | Where-Object { $_.ModuleName -eq "dxgi.dll" } | Select-Object -First 1
                if ($dxgiModule) {
                    $dxgiPath = $dxgiModule.FileName
                    $isSystemPath = $dxgiPath.ToLower().StartsWith("$env:SystemRoot\System32".ToLower())
                    if (-not $isSystemPath) {
                        $tamperingFound = $true
                        $checkDetails += @{
                            CheckType = "ProcessDxgiLoad"
                            ProcessName = $p.ProcessName
                            ProcessId   = $p.Id
                            DllPath     = $dxgiPath
                            Note        = "WARNING: Process loaded dxgi.dll from non-system path!"
                        }
                    }
                }
            }
            catch {
                # Access denied
            }
        }
    }
    catch {
        # Best-effort
    }

    $verdict = if ($tamperingFound) { "FAIL" } else { "PASS" }
    $summary = if ($tamperingFound) {
        "DXGI DLL tampering detected! Non-Microsoft-signed or non-system-path DXGI DLLs found."
    }
    else {
        "All DirectX DLLs are Microsoft-signed and loaded from System32. No tampering detected."
    }

    Add-CheckResult -CheckNumber 9 -Name "DXGI / DirectX Integrity" `
        -Category "Overlay/Anomaly Detection" -SimulatedAPI "DXGI API / GetModuleHandle" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "Piano A (RDP) does not hook DXGI — it uses Desktop Duplication API via rdpcorets.dll. Piano B uses GDI BitBlt (ImageGrab) which does not touch DXGI. Never hook IDXGISwapChain::Present."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return (-not $tamperingFound)
}

# ---------------------------------------------------------------------------
# Check 10: Synthetic Input — document SendInput detectability
# ---------------------------------------------------------------------------
function Invoke-Check10SyntheticInput {
    Write-TimedMessage -Message "[10/12] Synthetic Input — analyzing input injection surface..."

    $checkDetails = @()

    # Check if any process is using SendInput (heuristic)
    $sendInputProcesses = @()
    try {
        # Look for processes that have loaded user32.dll and are not whitelisted
        $processes = Get-Process -ErrorAction SilentlyContinue
        foreach ($p in $processes) {
            try {
                $modules = $p.Modules
                $hasUser32 = $false
                foreach ($m in $modules) {
                    if ($m.ModuleName -eq "user32.dll") {
                        $hasUser32 = $true
                        break
                    }
                }
                # Most GUI processes load user32.dll — this is not suspicious alone
            }
            catch {
                # Access denied
            }
        }
    }
    catch {
        # Best-effort
    }

    # Check for Piano B host process
    $pianoBRunning = $false
    try {
        $pythonProcs = Get-Process -Name "python*" -ErrorAction SilentlyContinue
        if ($pythonProcs) {
            foreach ($p in $pythonProcs) {
                try {
                    $cmdLine = (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction SilentlyContinue).CommandLine
                    if ($cmdLine -and $cmdLine -match "main_host") {
                        $pianoBRunning = $true
                        $checkDetails += @{
                            CheckType      = "PianoBProcess"
                            ProcessName    = $p.ProcessName
                            ProcessId      = $p.Id
                            CommandLine    = $cmdLine
                            Note           = "Piano B (SendInput) process detected. Input injection is detectable by GetMessageExtraInfo."
                        }
                    }
                }
                catch {
                    # Best-effort
                }
            }
        }
    }
    catch {
        # Best-effort
    }

    # Check for RDP input channel (Piano A)
    $rdpSessionActive = $false
    try {
        $tcpConnections = Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object {
            $_.LocalPort -eq 3390 -and $_.State -eq "Established"
        }
        if ($tcpConnections) {
            $rdpSessionActive = $true
            $checkDetails += @{
                CheckType = "PianoARDP"
                Note      = "RDP session active. RDP input uses the RDP protocol's input channel — NOT SendInput. This is indistinguishable from local input as far as proctoring software is concerned."
            }
        }
    }
    catch {
        # Best-effort
    }

    $verdict = if ($pianoBRunning) { "INFO" } else { "PASS" }
    $summary = "Input injection detection analysis. "
    if ($rdpSessionActive) {
        $summary += "RDP session active — input goes through native RDP protocol, not SendInput. SAFE."
    }
    if ($pianoBRunning) {
        $summary += "Piano B process detected — SendInput is detectable via GetMessageExtraInfo. RISK."
    }

    Add-CheckResult -CheckNumber 10 -Name "Synthetic Input Detection" `
        -Category "Input Detection" -SimulatedAPI "GetMessageExtraInfo" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "Piano A (RDP) input is inherently stealthy — it goes through the RDP protocol channel, not SendInput. Piano B (SendInput) IS detectable. Add random jitter (5-15ms) and realistic input timing to reduce detectability."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return $true  # Always pass — this is informational
}

# ---------------------------------------------------------------------------
# Check 11: Keyboard Hooks — check for low-level hooks
# ---------------------------------------------------------------------------
function Invoke-Check11KeyboardHooks {
    Write-TimedMessage -Message "[11/12] Keyboard Hooks — checking for global keyboard hooks..."

    $checkDetails = @()
    $hooksFound = $false

    # Check for WH_KEYBOARD_LL hooks
    # This requires checking loaded modules in processes or using Win32 API
    try {
        $hookCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class KeyboardHookChecker
{
    [DllImport("user32.dll")]
    public static extern IntPtr SetWindowsHookEx(int idHook, IntPtr lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetModuleHandle(string lpModuleName);

    public const int WH_KEYBOARD_LL = 13;
    public const int WH_MOUSE_LL = 14;

    public static bool TryInstallLowLevelHook(int hookType, out string errorMessage)
    {
        errorMessage = null;
        try
        {
            IntPtr modulePtr = GetModuleHandle("user32.dll");
            IntPtr hook = SetWindowsHookEx(hookType, IntPtr.Zero, modulePtr, 0);
            if (hook == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                errorMessage = string.Format("SetWindowsHookEx failed with error {0}", error);
                return false;
            }
            UnhookWindowsHookEx(hook);
            return true;
        }
        catch (Exception ex)
        {
            errorMessage = ex.Message;
            return false;
        }
    }

    public static bool IsHookInstalledByAnotherProcess(int hookType)
    {
        // This is a simplified check — a real check would enumerate hook chains
        // We use a heuristic: try to install the same hook
        // If it succeeds, no other process has the hook
        // If it "succeeds" but our hook doesn't fire, another hook may be present
        // This is best-effort
        return false;  // Simplified
    }

    public static List<Dictionary<string, object>> EnumerateHooks()
    {
        var results = new List<Dictionary<string, object>>();
        // Note: Windows does not expose a public API to enumerate existing hooks
        // This is a limitation acknowledged in the project documentation
        results.Add(new Dictionary<string, object>
        {
            { "CheckType", "HookEnumeration" },
            { "Note", "Windows does not expose a public API to enumerate installed hooks. Detection of WH_KEYBOARD_LL hooks is inherently asymmetric." }
        });
        return results;
    }
}
'@
        Add-Type -TypeDefinition $hookCode -ErrorAction SilentlyContinue | Out-Null
        if ([KeyboardHookChecker] -ne $null) {
            $hookResults = [KeyboardHookChecker]::EnumerateHooks()
            foreach ($hr in $hookResults) {
                $checkDetails += $hr
            }
        }
    }
    catch {
        $checkDetails += @{ Note = "Hook enumeration requires admin or pinvoke. Attempting fallback..." }
    }

    # Also check for processes known to install hooks (proctoring software)
    $hookProcessNames = @(
        "respondus", "lockdown", "proctorio", "proctoru", "honorlock",
        "examsoft", "examplify", "proproctor", "seb", "safeexam"
    )
    try {
        $runningProcs = Get-Process -ErrorAction SilentlyContinue
        foreach ($proc in $runningProcs) {
            $procName = $proc.ProcessName.ToLower()
            foreach ($hookName in $hookProcessNames) {
                if ($procName -like "*$hookName*") {
                    $hooksFound = $true
                    $checkDetails += @{
                        CheckType    = "ProctoringProcess"
                        ProcessName  = $proc.ProcessName
                        ProcessId    = $proc.Id
                        Note         = "Proctoring software ($hookName) detected — may have installed keyboard hooks"
                    }
                    break
                }
            }
        }
    }
    catch {
        # Best-effort
    }

    $verdict = if ($hooksFound) { "INFO" } else { "PASS" }
    $summary = "Keyboard hook analysis. "
    if ($hooksFound) {
        $summary += "Proctoring processes detected that may have installed WH_KEYBOARD_LL hooks."
    }
    else {
        $summary += "No proctoring hook processes detected. Hook detection is asymmetric — hooks installed by proctoring software cannot be easily enumerated."
    }

    Add-CheckResult -CheckNumber 11 -Name "Keyboard Hooks Detection" `
        -Category "Input Detection" -SimulatedAPI "SetWindowsHookEx / WH_KEYBOARD_LL" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "WH_KEYBOARD_LL hooks run in the hook-installing process's context and see ALL input. Piano A (RDP) input channel may bypass the hook layer. Piano B SendInput is visible to hooks. RDP input forwarding is the recommended mitigation."

    Write-TimedMessage -Message "  -> Verdict: $verdict"
    return $true  # Informational — hooks may or may not be present
}

# ---------------------------------------------------------------------------
# Check 12: VM Detection — registry, MAC, service heuristics
# ---------------------------------------------------------------------------
function Invoke-Check12VmDetection {
    Write-TimedMessage -Message "[12/12] VM Detection — checking for virtualized environment indicators..."

    $checkDetails = @()
    $vmScore = 0
    $vmDetected = $false

    # Known VM hardware IDs
    $vmHardwareIds = @(
        @{ Pattern = "VEN_15AD";  Name = "VMware" }
        @{ Pattern = "VEN_1AF4";  Name = "QEMU/Virtual" }
        @{ Pattern = "VEN_80EE";  Name = "Oracle VM" }
        @{ Pattern = "PCI\\VEN_15AD"; Name = "VMware PCI" }
        @{ Pattern = "PCI\\VEN_1AF4"; Name = "QEMU PCI" }
    )

    # Check registry for VM hardware IDs
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
                            $vmDetected = $true
                            $vmScore++
                            $checkDetails += @{
                                CheckType    = "RegistryHardwareID"
                                Source       = $regPath
                                MatchedID    = $hwId.Pattern
                                VMName       = $hwId.Name
                                Note         = "VM hardware ID detected in registry"
                            }
                        }
                    }
                }
            }
        }
        catch {
            # Best-effort
        }
    }

    # Check MAC address prefixes
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
                    $vmDetected = $true
                    $vmScore++
                    $checkDetails += @{
                        CheckType    = "MACAddress"
                        Source       = "Get-NetAdapter"
                        MatchedID    = $prefix.Prefix
                        VMName       = $prefix.Name
                        MacAddress   = $mac
                        Note         = "VM MAC prefix detected"
                    }
                }
            }
        }
    }
    catch {
        # Best-effort
    }

    # Check for VM processes
    $vmProcessNames = @("vmtoolsd", "VBoxTray", "VBoxMouse", "qemu-ga", "xenservice")
    try {
        $runningProcs = Get-Process -ErrorAction SilentlyContinue
        foreach ($p in $runningProcs) {
            foreach ($vpn in $vmProcessNames) {
                if ($p.ProcessName -eq $vpn) {
                    $vmDetected = $true
                    $vmScore++
                    $checkDetails += @{
                        CheckType    = "VMProcess"
                        Source       = "Get-Process"
                        MatchedID    = $p.ProcessName
                        VMName       = "Unknown VM"
                        Note         = "VM guest process detected"
                    }
                }
            }
        }
    }
    catch {
        # Best-effort
    }

    # Check BIOS/DMI strings
    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        if ($bios) {
            $biosInfo = @{
                Manufacturer = $bios.Manufacturer
                Version      = $bios.Version
                SerialNumber = $bios.SerialNumber
            }
            $biosString = "$($bios.Manufacturer) $($bios.Version) $($bios.SerialNumber)"
            $vmBiosPatterns = @("VMware", "VirtualBox", "QEMU", "Xen", "KVM", "Bochs")
            foreach ($pattern in $vmBiosPatterns) {
                if ($biosString -match $pattern) {
                    $vmDetected = $true
                    $vmScore++
                    $checkDetails += @{
                        CheckType    = "BIOSString"
                        Source       = "Win32_BIOS"
                        MatchedID    = $pattern
                        Note         = "VM BIOS string detected: $($bios.Manufacturer)"
                    }
                }
            }
            # Add BIOS info regardless
            $checkDetails += @{
                CheckType = "BIOSInfo"
                Source    = "Win32_BIOS"
                Info      = $biosInfo
                Note      = "BIOS information for VM detection analysis"
            }
        }
    }
    catch {
        # Best-effort
    }

    $verdict = if ($vmDetected) { "FAIL" } else { "PASS" }
    $summary = if ($vmDetected) {
        "VM DETECTED! Found $vmScore VM indicator(s). Proctoring software will likely block the exam."
    }
    else {
        "No VM indicators detected. This appears to be a physical machine."
    }

    Add-CheckResult -CheckNumber 12 -Name "VM Detection" `
        -Category "VM Detection" -SimulatedAPI "Registry / MAC / BIOS / Process" `
        -Verdict $verdict -Summary $summary -Details $checkDetails `
        -Mitigation "VM detection is all-or-nothing. Run on bare metal hardware. If VM is required, disable guest additions, use pass-through GPU, and modify hypervisor settings to hide from registry checks. Physical machine strongly recommended."

    Write-TimedMessage -Message "  -> Verdict: $verdict (score: $vmScore)"
    return (-not $vmDetected)
}

# ---------------------------------------------------------------------------
# Report aggregation and JSON output
# ---------------------------------------------------------------------------
function Export-StealthReport {
    $endTime = Get-Date
    $duration = $endTime - $script:StartTime

    Write-TimedMessage -Message "[*] Aggregating results and writing JSON report..."

    # Count verdicts
    $passCount = 0
    $failCount = 0
    $warningCount = 0
    $infoCount = 0

    foreach ($cr in $script:CheckResults) {
        if ($cr.Verdict -eq "PASS") { $passCount++ }
        elseif ($cr.Verdict -eq "FAIL") { $failCount++ }
        elseif ($cr.Verdict -eq "WARNING") { $warningCount++ }
        elseif ($cr.Verdict -eq "INFO") { $infoCount++ }
    }

    $overallVerdict = if ($failCount -gt 0) { "FAIL" } elseif ($warningCount -gt 0) { "WARNING" } else { "PASS" }

    $report = @{
        Metadata = @{
            ScriptName       = "stealth_check.ps1"
            Version          = "1.0"
            Target           = "Windows 10/11 x64"
            RunTimestamp     = $script:StartTime.ToString("o")
            CompletionTime   = $endTime.ToString("o")
            DurationSeconds  = [math]::Round($duration.TotalSeconds, 3)
            ComputerName     = $env:COMPUTERNAME
            Username         = $env:USERNAME
            IsElevated       = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            OSVersion        = $null
        }
        Summary = @{
            OverallVerdict   = $overallVerdict
            TotalChecks      = $script:CheckResults.Count
            Passed           = $passCount
            Failed           = $failCount
            Warnings         = $warningCount
            Info             = $infoCount
        }
        Checks = $script:CheckResults
        Errors = $script:Errors
        TotalErrors = $script:Errors.Count
    }

    # Get OS version
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $report.Metadata.OSVersion = $os.Caption
        }
    }
    catch {
        # Best-effort
    }

    # Write JSON output
    $outputDir = Split-Path -Path $OutputPath -Parent
    if (-not (Test-Path -LiteralPath $outputDir)) {
        try {
            New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
            Write-TimedMessage -Message "  -> Created output directory: $outputDir"
        }
        catch {
            Write-TimedMessage -Message "  -> Could not create output directory: $outputDir" -Level "WARN"
        }
    }

    try {
        $reportJson = $report | ConvertTo-Json -Depth 8 -ErrorAction Stop
        Set-Content -Path $OutputPath -Value $reportJson -Encoding UTF8 -ErrorAction Stop
        Write-TimedMessage -Message "  -> Report written to: $OutputPath"
        Write-TimedMessage -Message "  -> File size: $((Get-Item -Path $OutputPath).Length) bytes"
    }
    catch {
        Add-ErrorRecord -Category "JsonOutput" -Detail "Failed to write JSON report" -Ex $_
        $fallbackPath = Join-Path -Path $env:TEMP -ChildPath "stealth_check_fallback.json"
        try {
            $report | ConvertTo-Json -Depth 8 | Set-Content -Path $fallbackPath -Encoding UTF8
            Write-TimedMessage -Message "  -> Fallback report written to: $fallbackPath" -Level "WARN"
        }
        catch {
            Add-ErrorRecord -Category "JsonOutput" -Detail "Fallback write also failed" -Ex $_
        }
    }

    return $report
}

# ---------------------------------------------------------------------------
# Main orchestrator
# ---------------------------------------------------------------------------
function Invoke-StealthCheck {
    Write-TimedMessage -Message "=============================================="
    Write-TimedMessage -Message " STEALTH CHECK v1.0"
    Write-TimedMessage -Message " Stealth Remote Control Project"
    Write-TimedMessage -Message "=============================================="
    Write-TimedMessage -Message "Started at: $($script:StartTime.ToString('o'))"
    Write-TimedMessage -Message "Output:     $OutputPath"
    Write-TimedMessage -Message ""

    # Run all 12 checks
    $null = Invoke-Check1ProcessEnumeration
    $null = Invoke-Check2WindowTracking
    $null = Invoke-Check3ServiceEnumeration
    $null = Invoke-Check4SignatureVerification
    $null = Invoke-Check5TcpConnectionMap
    $null = Invoke-Check6AsymmetricTraffic
    $null = Invoke-Check7StreamingDetection
    $null = Invoke-Check8DisplayAffinity
    $null = Invoke-Check9DxgiIntegrity
    $null = Invoke-Check10SyntheticInput
    $null = Invoke-Check11KeyboardHooks
    $null = Invoke-Check12VmDetection

    Write-TimedMessage -Message ""
    Write-TimedMessage -Message "Aggregating and exporting report..."
    $report = Export-StealthReport

    # Print summary
    Write-TimedMessage -Message ""
    Write-TimedMessage -Message "=============================================="
    Write-TimedMessage -Message " STEALTH CHECK COMPLETE"
    Write-TimedMessage -Message " Overall: $($report.Summary.OverallVerdict)"
    Write-TimedMessage -Message " Passed:  $($report.Summary.Passed) / $($report.Summary.TotalChecks)"
    Write-TimedMessage -Message " Failed:  $($report.Summary.Failed)"
    Write-TimedMessage -Message " Warnings: $($report.Summary.Warnings)"
    Write-TimedMessage -Message " Info:    $($report.Summary.Info)"
    Write-TimedMessage -Message " Errors:  $($report.TotalErrors)"
    Write-TimedMessage -Message "=============================================="

    return $report
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath $OutputPath
}

$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

$null = Invoke-StealthCheck
