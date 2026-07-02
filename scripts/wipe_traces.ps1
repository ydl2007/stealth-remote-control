<#
.SYNOPSIS
    Wipe Traces — deep forensic trace removal script for post-exam cleanup.

.DESCRIPTION
    Removes digital traces left behind during a stealth remote-control session.
    Designed for Windows 10/11, PowerShell 5.1 compatible.
    
    Operations (some require admin — degrades gracefully):
      1. Clear Security event log (admin, optional)
      2. Clear Application event log (optional)
      3. Remove our VPS SSH host key from known_hosts
      4. Clear RDP client connection history from registry
      5. Clear RDP server connection logs from registry
      6. Clear Windows jump lists (AutomaticDestinations)
      7. Flush DNS cache
      8. Scan for remaining processes matching our naming patterns
      9. Remove network drives mapped during the session
     10. Output structured cleanup report

.PARAMETER VpsIp
    The VPS IP address to remove from SSH known_hosts. If not supplied,
    the script attempts to extract it from tunnel configuration files.

.PARAMETER ReportPath
    Path for the cleanup report JSON. Defaults to
    .omo/evidence/task-7-wipe-report.json relative to the script.

.PARAMETER Silent
    If set, suppresses confirmation prompts. Useful for automated cleanup.

.EXAMPLE
    .\wipe_traces.ps1
    .\wipe_traces.ps1 -VpsIp "203.0.113.10" -Silent

.NOTES
    Author: Stealth Remote Control Project
    Version: 1.0
    Target: Windows 10/11, PowerShell 5.1
    Idempotent: YES. Safe to run multiple times.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$VpsIp = "",

    [Parameter(Mandatory = $false)]
    [string]$ReportPath = $(Join-Path -Path $PSScriptRoot -ChildPath "..\.omo\evidence\task-7-wipe-report.json"),

    [Parameter(Mandatory = $false)]
    [switch]$Silent = $false
)

#Requires -Version 5.1

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
$script:StartTime = Get-Date
$script:Actions = @()
$script:Errors = @()
$script:Warnings = @()

# Check admin
$script:IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Write-TimedMessage {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Write-Host "[$ts] [$Level] $Message"
}

function Add-ActionRecord {
    param([string]$Operation, [string]$Target, [string]$Status, [string]$Detail = "")
    $script:Actions += @{
        Operation   = $Operation
        Target      = $Target
        Status      = $Status
        Detail      = $Detail
        Timestamp   = (Get-Date -Format "o")
    }
}

function Add-ErrorRecord {
    param([string]$Operation, [string]$Detail, [string]$Exception = "")
    $script:Errors += @{
        Operation   = $Operation
        Detail      = $Detail
        Exception   = $Exception
        Timestamp   = (Get-Date -Format "o")
    }
}

function Add-WarningRecord {
    param([string]$Operation, [string]$Detail)
    $script:Warnings += @{
        Operation   = $Operation
        Detail      = $Detail
        Timestamp   = (Get-Date -Format "o")
    }
}

# ---------------------------------------------------------------------------
# Helper: Try to extract VPS_IP from tunnel configuration files
# ---------------------------------------------------------------------------
function Get-VpsIpFromConfig {
    $candidates = @()

    # Check tunnel_host.bat
    $hostScript = Join-Path -Path $PSScriptRoot -ChildPath "tunnel\tunnel_host.bat"
    if (Test-Path -LiteralPath $hostScript) {
        try {
            $content = Get-Content -Path $hostScript -Raw -ErrorAction Stop
            $pattern = 'set\s+VPS_IP=([^\r\n]+)'
            $match = [regex]::Match($content, $pattern)
            if ($match.Success) {
                $ip = $match.Groups[1].Value.Trim()
                if ($ip -ne "YOUR_VPS_IP_HERE" -and $ip -ne "") {
                    $candidates += $ip
                }
            }
        }
        catch {
            # Best-effort
        }
    }

    # Check tunnel_client.bat
    $clientScript = Join-Path -Path $PSScriptRoot -ChildPath "tunnel\tunnel_client.bat"
    if (Test-Path -LiteralPath $clientScript) {
        try {
            $content = Get-Content -Path $clientScript -Raw -ErrorAction Stop
            $pattern = 'set\s+VPS_IP=([^\r\n]+)'
            $match = [regex]::Match($content, $pattern)
            if ($match.Success) {
                $ip = $match.Groups[1].Value.Trim()
                if ($ip -ne "YOUR_VPS_IP_HERE" -and $ip -ne "") {
                    # Avoid duplicates
                    if ($ip -notin $candidates) {
                        $candidates += $ip
                    }
                }
            }
        }
        catch {
            # Best-effort
        }
    }

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }
    return $null
}

# ---------------------------------------------------------------------------
# 1. Clear Security Event Log (admin only)
# ---------------------------------------------------------------------------
function Invoke-ClearSecurityLog {
    Write-TimedMessage -Message "[1/9] Clearing Security event log..."

    if (-not $script:IsElevated) {
        Add-WarningRecord -Operation "ClearSecurityLog" -Detail "Skipped — requires admin"
        Write-TimedMessage -Message "  -> SKIP: Requires Administrator." -Level "WARN"
        Add-ActionRecord -Operation "ClearEventLog" -Target "Security" -Status "Skipped" -Detail "Not elevated"
        return
    }

    if ($Silent -or $script:IsElevated) {
        try {
            Clear-EventLog -LogName Security -ErrorAction Stop
            Add-ActionRecord -Operation "ClearEventLog" -Target "Security" -Status "Success"
            Write-TimedMessage -Message "  -> OK: Security event log cleared."
        }
        catch {
            Add-ErrorRecord -Operation "ClearEventLog" -Detail "Security log" -Exception $_.Exception.Message
            Write-TimedMessage -Message "  -> ERROR: Failed to clear Security log: $($_.Exception.Message)" -Level "ERROR"
            Add-ActionRecord -Operation "ClearEventLog" -Target "Security" -Status "Failed" -Detail $_.Exception.Message
        }
    }
    else {
        Add-ActionRecord -Operation "ClearEventLog" -Target "Security" -Status "Skipped" -Detail "User declined"
        Write-TimedMessage -Message "  -> SKIP: User declined."
    }
}

# ---------------------------------------------------------------------------
# 2. Clear Application Event Log (optional)
# ---------------------------------------------------------------------------
function Invoke-ClearApplicationLog {
    Write-TimedMessage -Message "[2/9] Clearing Application event log..."

    if ($Silent) {
        try {
            Clear-EventLog -LogName Application -ErrorAction Stop
            Add-ActionRecord -Operation "ClearEventLog" -Target "Application" -Status "Success"
            Write-TimedMessage -Message "  -> OK: Application event log cleared."
        }
        catch {
            # System event log typically requires admin
            if ($_.Exception.Message -match "access denied|denied|permission") {
                Add-WarningRecord -Operation "ClearApplicationLog" -Detail "Requires admin — skipped"
                Write-TimedMessage -Message "  -> SKIP: Requires Administrator." -Level "WARN"
                Add-ActionRecord -Operation "ClearEventLog" -Target "Application" -Status "Skipped" -Detail "Not elevated"
            }
            else {
                Add-ErrorRecord -Operation "ClearEventLog" -Detail "Application log" -Exception $_.Exception.Message
                Write-TimedMessage -Message "  -> ERROR: $($_.Exception.Message)" -Level "ERROR"
                Add-ActionRecord -Operation "ClearEventLog" -Target "Application" -Status "Failed" -Detail $_.Exception.Message
            }
        }
    }
    else {
        Write-Host ""
        $confirm = Read-Host "Clear Application event log? (y/N)"
        if ($confirm -eq "y" -or $confirm -eq "Y") {
            try {
                Clear-EventLog -LogName Application -ErrorAction Stop
                Add-ActionRecord -Operation "ClearEventLog" -Target "Application" -Status "Success"
                Write-TimedMessage -Message "  -> OK: Application event log cleared."
            }
            catch {
                if ($_.Exception.Message -match "access denied|denied|permission") {
                    Add-WarningRecord -Operation "ClearApplicationLog" -Detail "Requires admin"
                    Write-TimedMessage -Message "  -> SKIP: Requires Administrator." -Level "WARN"
                    Add-ActionRecord -Operation "ClearEventLog" -Target "Application" -Status "Skipped" -Detail "Not elevated"
                }
                else {
                    Add-ErrorRecord -Operation "ClearEventLog" -Detail "Application log" -Exception $_.Exception.Message
                    Write-TimedMessage -Message "  -> ERROR: $($_.Exception.Message)" -Level "ERROR"
                }
            }
        }
        else {
            Add-ActionRecord -Operation "ClearEventLog" -Target "Application" -Status "Skipped" -Detail "User declined"
            Write-TimedMessage -Message "  -> SKIP: User declined."
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Remove VPS SSH host key from known_hosts
# ---------------------------------------------------------------------------
function Invoke-RemoveKnownHostsEntry {
    param([string]$VpsIpAddress)
    Write-TimedMessage -Message "[3/9] Removing VPS SSH host key from known_hosts..."

    $knownHostsPath = Join-Path -Path $env:USERPROFILE -ChildPath ".ssh\known_hosts"
    if (-not (Test-Path -LiteralPath $knownHostsPath)) {
        Add-ActionRecord -Operation "RemoveKnownHosts" -Target $knownHostsPath -Status "Skipped" -Detail "File not found"
        Write-TimedMessage -Message "  -> INFO: known_hosts file not found — nothing to clean."
        return
    }

    if ([string]::IsNullOrWhiteSpace($VpsIpAddress)) {
        Add-WarningRecord -Operation "RemoveKnownHosts" -Detail "No VPS IP provided — scanning for non-local IPs in known_hosts is not safe"
        Write-TimedMessage -Message "  -> SKIP: No VPS IP provided. Pass -VpsIp parameter or configure tunnel scripts." -Level "WARN"
        Add-ActionRecord -Operation "RemoveKnownHosts" -Target $knownHostsPath -Status "Skipped" -Detail "No VPS IP specified"
        return
    }

    try {
        $content = Get-Content -Path $knownHostsPath -ErrorAction Stop
        $filtered = @()
        $removedCount = 0
        $hostPatterns = @($VpsIpAddress)

        # Also add hostname patterns (strip port if present with brackets)
        if ($VpsIpAddress -match '^\[?(\d+\.\d+\.\d+\.\d+)\]?(:\d+)?$') {
            $bareIp = $matches[1]
            $hostPatterns += $bareIp
        }

        foreach ($line in $content) {
            $remove = $false
            foreach ($pattern in $hostPatterns) {
                if ($line -match [regex]::Escape($pattern)) {
                    $remove = $true
                    $removedCount++
                    break
                }
            }
            if (-not $remove) {
                $filtered += $line
            }
        }

        if ($removedCount -gt 0) {
            $filtered | Set-Content -Path $knownHostsPath -Encoding ASCII -ErrorAction Stop
            Add-ActionRecord -Operation "RemoveKnownHosts" -Target $knownHostsPath -Status "Success" -Detail "Removed $removedCount line(s) matching $VpsIpAddress"
            Write-TimedMessage -Message "  -> OK: Removed $removedCount line(s) from known_hosts for IP $VpsIpAddress."
        }
        else {
            Add-ActionRecord -Operation "RemoveKnownHosts" -Target $knownHostsPath -Status "Success" -Detail "No matching entries found for $VpsIpAddress"
            Write-TimedMessage -Message "  -> INFO: No entries matching $VpsIpAddress found in known_hosts."
        }
    }
    catch {
        Add-ErrorRecord -Operation "RemoveKnownHosts" -Detail "Failed to edit $knownHostsPath" -Exception $_.Exception.Message
        Write-TimedMessage -Message "  -> ERROR: $($_.Exception.Message)" -Level "ERROR"
        Add-ActionRecord -Operation "RemoveKnownHosts" -Target $knownHostsPath -Status "Failed" -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 4. Clear RDP client connection history (registry — Default key)
# ---------------------------------------------------------------------------
function Invoke-ClearRdpClientHistory {
    param([string]$VpsIpAddress)
    Write-TimedMessage -Message "[4/9] Clearing RDP client connection history..."

    $rdpDefaultPath = "HKCU:\Software\Microsoft\Terminal Server Client\Default"

    if (-not (Test-Path -LiteralPath $rdpDefaultPath)) {
        Add-ActionRecord -Operation "ClearRdpClientHistory" -Target $rdpDefaultPath -Status "Skipped" -Detail "Registry key not found"
        Write-TimedMessage -Message "  -> INFO: RDP client history key not found — nothing to clean."
        return
    }

    try {
        $entries = Get-ItemProperty -Path $rdpDefaultPath -ErrorAction Stop
        $removedCount = 0

        # Get list of property names to check (skip PS* properties)
        $propNames = $entries.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object { $_.Name }

        if (-not [string]::IsNullOrWhiteSpace($VpsIpAddress)) {
            foreach ($name in $propNames) {
                $val = $entries.$name
                if ($val -and $val -match [regex]::Escape($VpsIpAddress)) {
                    Remove-ItemProperty -Path $rdpDefaultPath -Name $name -ErrorAction SilentlyContinue
                    $removedCount++
                    Write-TimedMessage -Message "  -> Removed MRU entry '$name' matching $VpsIpAddress"
                }
            }
        }

        if ($removedCount -gt 0) {
            Add-ActionRecord -Operation "ClearRdpClientHistory" -Target $rdpDefaultPath -Status "Success" -Detail "Removed $removedCount matching entry(ies)"
            Write-TimedMessage -Message "  -> OK: Removed $removedCount RDP MRU entry(ies)."
        }
        else {
            if ([string]::IsNullOrWhiteSpace($VpsIpAddress)) {
                Add-ActionRecord -Operation "ClearRdpClientHistory" -Target $rdpDefaultPath -Status "Skipped" -Detail "No VPS IP provided"
                Write-TimedMessage -Message "  -> SKIP: No VPS IP to match against. Provide -VpsIp to clean specific entries." -Level "WARN"
            }
            else {
                Add-ActionRecord -Operation "ClearRdpClientHistory" -Target $rdpDefaultPath -Status "Success" -Detail "No entries matching $VpsIpAddress"
                Write-TimedMessage -Message "  -> INFO: No RDP entries matching $VpsIpAddress found."
            }
        }
    }
    catch {
        Add-ErrorRecord -Operation "ClearRdpClientHistory" -Detail "Failed to edit registry" -Exception $_.Exception.Message
        Write-TimedMessage -Message "  -> ERROR: $($_.Exception.Message)" -Level "ERROR"
        Add-ActionRecord -Operation "ClearRdpClientHistory" -Target $rdpDefaultPath -Status "Failed" -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 5. Clear RDP server connection logs (registry — Servers key)
# ---------------------------------------------------------------------------
function Invoke-ClearRdpServerLogs {
    param([string]$VpsIpAddress)
    Write-TimedMessage -Message "[5/9] Clearing RDP server connection logs..."

    $rdpServersPath = "HKCU:\Software\Microsoft\Terminal Server Client\Servers"

    if (-not (Test-Path -LiteralPath $rdpServersPath)) {
        Add-ActionRecord -Operation "ClearRdpServerLogs" -Target $rdpServersPath -Status "Skipped" -Detail "Registry key not found"
        Write-TimedMessage -Message "  -> INFO: RDP Servers key not found — nothing to clean."
        return
    }

    try {
        $serverKeys = Get-ChildItem -Path $rdpServersPath -ErrorAction Stop
        $removedCount = 0

        foreach ($key in $serverKeys) {
            $keyName = $key.PSChildName
            $removeKey = $false

            # If we have a VPS IP, match against it
            if (-not [string]::IsNullOrWhiteSpace($VpsIpAddress)) {
                if ($keyName -match [regex]::Escape($VpsIpAddress)) {
                    $removeKey = $true
                }
                # Also check child values for our IP
                if (-not $removeKey) {
                    try {
                        $keyProps = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                        if ($keyProps) {
                            $propNames = $keyProps.PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } | ForEach-Object { $_.Name }
                            foreach ($pname in $propNames) {
                                $pval = $keyProps.$pname
                                if ($pval -and $pval -match [regex]::Escape($VpsIpAddress)) {
                                    $removeKey = $true
                                    break
                                }
                            }
                        }
                    }
                    catch {
                        # Best-effort
                    }
                }
            }

            if ($removeKey) {
                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                $removedCount++
                Write-TimedMessage -Message "  -> Removed server entry: $keyName"
            }
        }

        if ($removedCount -gt 0) {
            Add-ActionRecord -Operation "ClearRdpServerLogs" -Target $rdpServersPath -Status "Success" -Detail "Removed $removedCount server key(s)"
            Write-TimedMessage -Message "  -> OK: Removed $removedCount RDP server entry(ies)."
        }
        else {
            if ([string]::IsNullOrWhiteSpace($VpsIpAddress)) {
                Add-ActionRecord -Operation "ClearRdpServerLogs" -Target $rdpServersPath -Status "Skipped" -Detail "No VPS IP provided"
                Write-TimedMessage -Message "  -> SKIP: No VPS IP to match against." -Level "WARN"
            }
            else {
                Add-ActionRecord -Operation "ClearRdpServerLogs" -Target $rdpServersPath -Status "Success" -Detail "No entries matching $VpsIpAddress"
                Write-TimedMessage -Message "  -> INFO: No server entries matching $VpsIpAddress found."
            }
        }
    }
    catch {
        Add-ErrorRecord -Operation "ClearRdpServerLogs" -Detail "Failed to edit registry" -Exception $_.Exception.Message
        Write-TimedMessage -Message "  -> ERROR: $($_.Exception.Message)" -Level "ERROR"
        Add-ActionRecord -Operation "ClearRdpServerLogs" -Target $rdpServersPath -Status "Failed" -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 6. Clear jump lists (AutomaticDestinations)
# ---------------------------------------------------------------------------
function Invoke-ClearJumpLists {
    Write-TimedMessage -Message "[6/9] Clearing Windows jump lists..."

    $jumpListPath = Join-Path -Path $env:APPDATA -ChildPath "Microsoft\Windows\Recent\AutomaticDestinations"

    if (-not (Test-Path -LiteralPath $jumpListPath)) {
        Add-ActionRecord -Operation "ClearJumpLists" -Target $jumpListPath -Status "Skipped" -Detail "Directory not found"
        Write-TimedMessage -Message "  -> INFO: Jump lists directory not found."
        return
    }

    try {
        $files = Get-ChildItem -Path $jumpListPath -File -ErrorAction Stop
        $fileCount = $files.Count

        if ($fileCount -eq 0) {
            Add-ActionRecord -Operation "ClearJumpLists" -Target $jumpListPath -Status "Success" -Detail "No files to delete"
            Write-TimedMessage -Message "  -> INFO: No jump list files found."
            return
        }

        if ($Silent) {
            Remove-Item -Path "$jumpListPath\*" -Force -ErrorAction Stop
            Add-ActionRecord -Operation "ClearJumpLists" -Target $jumpListPath -Status "Success" -Detail "Deleted $fileCount file(s)"
            Write-TimedMessage -Message "  -> OK: Deleted $fileCount jump list file(s)."
        }
        else {
            Write-Host "    Found $fileCount jump list files."
            $confirm = Read-Host "    Clear all jump list files? (y/N)"
            if ($confirm -eq "y" -or $confirm -eq "Y") {
                Remove-Item -Path "$jumpListPath\*" -Force -ErrorAction Stop
                Add-ActionRecord -Operation "ClearJumpLists" -Target $jumpListPath -Status "Success" -Detail "Deleted $fileCount file(s)"
                Write-TimedMessage -Message "  -> OK: Deleted $fileCount jump list file(s)."
            }
            else {
                Add-ActionRecord -Operation "ClearJumpLists" -Target $jumpListPath -Status "Skipped" -Detail "User declined"
                Write-TimedMessage -Message "  -> SKIP: User declined."
            }
        }
    }
    catch {
        Add-ErrorRecord -Operation "ClearJumpLists" -Detail "Failed to clear jump lists" -Exception $_.Exception.Message
        Write-TimedMessage -Message "  -> ERROR: $($_.Exception.Message)" -Level "ERROR"
        Add-ActionRecord -Operation "ClearJumpLists" -Target $jumpListPath -Status "Failed" -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 7. Flush DNS cache
# ---------------------------------------------------------------------------
function Invoke-FlushDns {
    Write-TimedMessage -Message "[7/9] Flushing DNS cache..."

    try {
        $result = & ipconfig /flushdns 2>&1
        $output = $result -join "`n"
        if ($output -match "successfully|succès|flushed|vymazala|success") {
            Add-ActionRecord -Operation "FlushDns" -Target "DNS Cache" -Status "Success"
            Write-TimedMessage -Message "  -> OK: DNS cache flushed."
        }
        else {
            Add-WarningRecord -Operation "FlushDns" -Detail "Command ran but output unclear: $output"
            Add-ActionRecord -Operation "FlushDns" -Target "DNS Cache" -Status "Warning" -Detail $output
            Write-TimedMessage -Message "  -> WARNING: DNS flush may not have succeeded." -Level "WARN"
        }
    }
    catch {
        Add-ErrorRecord -Operation "FlushDns" -Detail "ipconfig /flushdns failed" -Exception $_.Exception.Message
        Write-TimedMessage -Message "  -> ERROR: $($_.Exception.Message)" -Level "ERROR"
        Add-ActionRecord -Operation "FlushDns" -Target "DNS Cache" -Status "Failed" -Detail $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 8. Scan for remaining processes matching our naming patterns
# ---------------------------------------------------------------------------
function Invoke-ScanRemainingProcesses {
    Write-TimedMessage -Message "[8/9] Scanning for remaining stealth processes..."

    $suspiciousPatterns = @(
        "stealth_remote"
        "SSH-Tunnel"
        "tunnel_host"
        "tunnel_client"
    )

    $foundProcesses = @()
    try {
        $allProcs = Get-Process -ErrorAction SilentlyContinue
        foreach ($proc in $allProcs) {
            $procName = $proc.ProcessName
            $cmdLine = ""
            try {
                $cimProc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue
                if ($cimProc) {
                    $cmdLine = $cimProc.CommandLine
                }
            }
            catch {
                # Best-effort
            }

            $matchedPattern = $null
            foreach ($pattern in $suspiciousPatterns) {
                if ($procName -match [regex]::Escape($pattern)) {
                    $matchedPattern = $pattern
                    break
                }
                if ($cmdLine -match [regex]::Escape($pattern)) {
                    if (-not $matchedPattern) {
                        $matchedPattern = "$pattern (command line)"
                    }
                    break
                }
            }

            if ($matchedPattern) {
                $foundProcesses += @{
                    ProcessName    = $procName
                    ProcessId      = $proc.Id
                    MatchedPattern = $matchedPattern
                    CommandLine    = $cmdLine
                }
            }
        }

        if ($foundProcesses.Count -gt 0) {
            Add-ActionRecord -Operation "ScanProcesses" -Target "Processes" -Status "Warning" -Detail "Found $($foundProcesses.Count) matching process(es)"
            Write-TimedMessage -Message "  -> WARNING: Found $($foundProcesses.Count) process(es) matching our patterns:" -Level "WARN"
            foreach ($fp in $foundProcesses) {
                Write-TimedMessage -Message "       PID $($fp.ProcessId): $($fp.ProcessName) (matched: $($fp.MatchedPattern))" -Level "WARN"
            }

            if (-not $Silent) {
                $confirm = Read-Host "    Kill these processes? (y/N)"
                if ($confirm -eq "y" -or $confirm -eq "Y") {
                    foreach ($fp in $foundProcesses) {
                        try {
                            Stop-Process -Id $fp.ProcessId -Force -ErrorAction Stop
                            Write-TimedMessage -Message "    -> Killed PID $($fp.ProcessId): $($fp.ProcessName)"
                        }
                        catch {
                            Add-WarningRecord -Operation "KillProcess" -Detail "Failed to kill PID $($fp.ProcessId): $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
        else {
            Add-ActionRecord -Operation "ScanProcesses" -Target "Processes" -Status "Success" -Detail "No matching processes found"
            Write-TimedMessage -Message "  -> OK: No matching processes found."
        }
    }
    catch {
        Add-ErrorRecord -Operation "ScanProcesses" -Detail "Process scan failed" -Exception $_.Exception.Message
        Write-TimedMessage -Message "  -> ERROR: $($_.Exception.Message)" -Level "ERROR"
        Add-ActionRecord -Operation "ScanProcesses" -Target "Processes" -Status "Failed" -Detail $_.Exception.Message
    }

    return $foundProcesses
}

# ---------------------------------------------------------------------------
# 9. Remove network drives mapped during session
# ---------------------------------------------------------------------------
function Invoke-RemoveNetworkDrives {
    Write-TimedMessage -Message "[9/9] Checking for mapped network drives..."

    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction Stop | Where-Object { $_.Root -match '^\\\\' }
        $driveList = @($drives)

        if ($driveList.Count -eq 0) {
            Add-ActionRecord -Operation "RemoveNetworkDrives" -Target "NetworkDrives" -Status "Success" -Detail "No mapped network drives found"
            Write-TimedMessage -Message "  -> OK: No mapped network drives found."
            return
        }

        Write-TimedMessage -Message "  -> Found $($driveList.Count) mapped network drive(s):"
        foreach ($d in $driveList) {
            Write-TimedMessage -Message "       $($d.Name) -> $($d.Root)"
        }

        if ($Silent) {
            foreach ($d in $driveList) {
                try {
                    net use "$($d.Name):" /delete /y 2>$null
                    Add-ActionRecord -Operation "RemoveNetworkDrive" -Target "$($d.Name):" -Status "Success"
                    Write-TimedMessage -Message "    -> Removed: $($d.Name):"
                }
                catch {
                    Add-WarningRecord -Operation "RemoveNetworkDrive" -Detail "Failed to remove $($d.Name):"
                }
            }
        }
        else {
            $confirm = Read-Host "    Remove these network drive(s)? (y/N)"
            if ($confirm -eq "y" -or $confirm -eq "Y") {
                foreach ($d in $driveList) {
                    try {
                        net use "$($d.Name):" /delete /y 2>$null
                        Add-ActionRecord -Operation "RemoveNetworkDrive" -Target "$($d.Name):" -Status "Success"
                        Write-TimedMessage -Message "    -> Removed: $($d.Name):"
                    }
                    catch {
                        Add-WarningRecord -Operation "RemoveNetworkDrive" -Detail "Failed to remove $($d.Name):"
                    }
                }
            }
            else {
                Add-ActionRecord -Operation "RemoveNetworkDrives" -Target "NetworkDrives" -Status "Skipped" -Detail "User declined"
                Write-TimedMessage -Message "  -> SKIP: User declined."
            }
        }
    }
    catch {
        Add-ErrorRecord -Operation "RemoveNetworkDrives" -Detail "Failed to enumerate drives" -Exception $_.Exception.Message
        Write-TimedMessage -Message "  -> ERROR: $($_.Exception.Message)" -Level "ERROR"
    }
}

# ---------------------------------------------------------------------------
# Report Writer
# ---------------------------------------------------------------------------
function Export-CleanupReport {
    param([array]$RemainingProcesses)

    $endTime = Get-Date
    $duration = $endTime - $script:StartTime

    Write-TimedMessage -Message "[10/10] Writing cleanup report..."

    # Resolve report path
    $resolvedReportPath = $ReportPath
    if (-not [System.IO.Path]::IsPathRooted($resolvedReportPath)) {
        $resolvedReportPath = Join-Path -Path $PSScriptRoot -ChildPath $resolvedReportPath
    }
    $resolvedReportPath = [System.IO.Path]::GetFullPath($resolvedReportPath)

    $report = @{
        Metadata = @{
            ScriptName        = "wipe_traces.ps1"
            Version           = "1.0"
            RunTimestamp      = $script:StartTime.ToString("o")
            CompletionTime    = $endTime.ToString("o")
            DurationSeconds   = [math]::Round($duration.TotalSeconds, 3)
            ComputerName      = $env:COMPUTERNAME
            Username          = $env:USERNAME
            IsElevated        = $script:IsElevated
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        }
        Operations = @{
            TotalActions      = $script:Actions.Count
            Successful        = @($script:Actions | Where-Object { $_.Status -eq "Success" }).Count
            Skipped           = @($script:Actions | Where-Object { $_.Status -eq "Skipped" }).Count
            Failed            = @($script:Actions | Where-Object { $_.Status -eq "Failed" }).Count
            Warnings          = @($script:Actions | Where-Object { $_.Status -eq "Warning" }).Count
        }
        ActionLog    = $script:Actions
        Errors       = $script:Errors
        Warnings     = $script:Warnings
        TotalErrors  = $script:Errors.Count
        RemainingProcesses = $RemainingProcesses
    }

    # Create output directory
    $outputDir = Split-Path -Path $resolvedReportPath -Parent
    if (-not (Test-Path -LiteralPath $outputDir)) {
        try {
            New-Item -Path $outputDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-TimedMessage -Message "  -> ERROR: Could not create output directory: $outputDir" -Level "ERROR"
            $fallbackDir = Join-Path -Path $env:TEMP -ChildPath "stealth-cleanup"
            New-Item -Path $fallbackDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            $resolvedReportPath = Join-Path -Path $fallbackDir -ChildPath "task-7-wipe-report.json"
            Write-TimedMessage -Message "  -> Falling back to: $resolvedReportPath" -Level "WARN"
        }
    }

    try {
        $reportJson = $report | ConvertTo-Json -Depth 5 -ErrorAction Stop
        Set-Content -Path $resolvedReportPath -Value $reportJson -Encoding UTF8 -ErrorAction Stop
        Write-TimedMessage -Message "  -> OK: Report written to $resolvedReportPath"
        Write-TimedMessage -Message "  -> File size: $((Get-Item -Path $resolvedReportPath).Length) bytes"
    }
    catch {
        Add-ErrorRecord -Operation "ExportReport" -Detail "Failed to write JSON report" -Exception $_.Exception.Message
        Write-TimedMessage -Message "  -> ERROR: Failed to write report: $($_.Exception.Message)" -Level "ERROR"
    }
}

# ---------------------------------------------------------------------------
# Main Orchestrator
# ---------------------------------------------------------------------------
function Invoke-WipeTraces {
    Write-TimedMessage -Message "=============================================="
    Write-TimedMessage -Message " WIPE TRACES v1.0"
    Write-TimedMessage -Message " Stealth Remote Control Project"
    Write-TimedMessage -Message "=============================================="
    Write-TimedMessage -Message "Started: $($script:StartTime.ToString('o'))"
    Write-TimedMessage -Message "Admin:   $script:IsElevated"
    Write-TimedMessage -Message "Silent:  $Silent"
    Write-TimedMessage -Message ""

    # Resolve VPS IP
    $effectiveVpsIp = $VpsIp
    if ([string]::IsNullOrWhiteSpace($effectiveVpsIp)) {
        $detectedIp = Get-VpsIpFromConfig
        if ($detectedIp) {
            $effectiveVpsIp = $detectedIp
            Write-TimedMessage -Message "Detected VPS IP from tunnel config: $effectiveVpsIp"
        }
        else {
            Write-TimedMessage -Message "VPS IP not provided and could not be auto-detected." -Level "WARN"
            Write-TimedMessage -Message "Some steps (known_hosts, RDP history) will be skipped." -Level "WARN"
        }
    }
    Write-TimedMessage -Message ""

    # Run all steps
    Invoke-ClearSecurityLog
    Write-TimedMessage -Message ""
    Invoke-ClearApplicationLog
    Write-TimedMessage -Message ""
    Invoke-RemoveKnownHostsEntry -VpsIpAddress $effectiveVpsIp
    Write-TimedMessage -Message ""
    Invoke-ClearRdpClientHistory -VpsIpAddress $effectiveVpsIp
    Write-TimedMessage -Message ""
    Invoke-ClearRdpServerLogs -VpsIpAddress $effectiveVpsIp
    Write-TimedMessage -Message ""
    Invoke-ClearJumpLists
    Write-TimedMessage -Message ""
    Invoke-FlushDns
    Write-TimedMessage -Message ""
    $remaining = Invoke-ScanRemainingProcesses
    Write-TimedMessage -Message ""
    Invoke-RemoveNetworkDrives
    Write-TimedMessage -Message ""

    # Write report
    Export-CleanupReport -RemainingProcesses $remaining

    # Summary
    Write-TimedMessage -Message ""
    Write-TimedMessage -Message "=============================================="
    Write-TimedMessage -Message " WIPE TRACES COMPLETE"
    Write-TimedMessage -Message "=============================================="
    $successCount = @($script:Actions | Where-Object { $_.Status -eq "Success" }).Count
    $skipCount = @($script:Actions | Where-Object { $_.Status -eq "Skipped" }).Count
    $failCount = @($script:Actions | Where-Object { $_.Status -eq "Failed" }).Count
    $warnCount = @($script:Actions | Where-Object { $_.Status -eq "Warning" }).Count
    Write-TimedMessage -Message "  Successful: $successCount"
    Write-TimedMessage -Message "  Skipped:    $skipCount"
    Write-TimedMessage -Message "  Warnings:   $warnCount"
    Write-TimedMessage -Message "  Failed:     $failCount"
    Write-TimedMessage -Message "  Errors:     $($script:Errors.Count)"
    if ($script:Errors.Count -gt 0) {
        Write-TimedMessage -Message "  Review Errors array in report for details." -Level "WARN"
    }
    Write-TimedMessage -Message "=============================================="

    if (-not $Silent) {
        Write-Host ""
        Read-Host "Press Enter to exit"
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# Resolve report path
if (-not [System.IO.Path]::IsPathRooted($ReportPath)) {
    $ReportPath = Join-Path -Path $PSScriptRoot -ChildPath $ReportPath
}
$ReportPath = [System.IO.Path]::GetFullPath($ReportPath)

$null = Invoke-WipeTraces
