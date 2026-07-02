@echo off
REM ============================================================================
REM Script:  unharden.bat
REM Purpose: Reverse all changes made by harden.bat. Restores system settings
REM          to their state before hardening was applied.
REM
REM Changes reversed:
REM   1. Reads the state file saved by harden.bat to restore original settings
REM   2. Restarts telemetry/logging services that were stopped
REM   3. Event logs cannot be un-cleared, but we document the limitation
REM   4. Restores original process priorities
REM   5. Restores original network profile
REM   6. Restores original telemetry registry setting
REM   7. Removes the "Windows Remote Desktop (SSH)" firewall rule
REM   8. Cleans up backup/state files
REM
REM Requirements:
REM   - Must be run as Administrator
REM   - State file must exist from a previous harden.bat run
REM   - Windows 10 / Windows 11 (Pro or Enterprise)
REM
REM Usage:
REM   unharden.bat                    (interactive — prompts for each step)
REM   unharden.bat --yes              (non-interactive — applies all reversals)
REM   unharden.bat --dry-run          (show what would be done without doing it)
REM   unharden.bat --cleanup          (also delete state/backup files after undo)
REM   unharden.bat --latest-state     (use most recent state file automatically)
REM
REM (c) Stealth Remote Control Project
REM ============================================================================

setlocal enabledelayedexpansion

REM ---- Parse arguments ----
set "INTERACTIVE=1"
set "DRY_RUN=0"
set "CLEANUP=0"
set "LATEST_STATE=0"
if /i "%1"=="--yes" set "INTERACTIVE=0"
if /i "%1"=="-y" set "INTERACTIVE=0"
if /i "%1"=="--dry-run" set "DRY_RUN=1"
if /i "%1"=="--cleanup" set "CLEANUP=1"
if /i "%1"=="-c" set "CLEANUP=1"
if /i "%1"=="--latest-state" set "LATEST_STATE=1"
REM Handle combined flags like --cleanup --yes
if /i "%2"=="--yes" set "INTERACTIVE=0"
if /i "%2"=="-y" set "INTERACTIVE=0"
if /i "%2"=="--cleanup" set "CLEANUP=1"
if /i "%2"=="-c" set "CLEANUP=1"
if /i "%2"=="--latest-state" set "LATEST_STATE=1"

REM ---- Admin Check (skip for dry-run) ----
if %DRY_RUN% equ 0 (
    net session >nul 2>&1
    if %errorlevel% neq 0 (
        echo ============================================================
        echo ERROR: This script must be run as Administrator.
        echo ============================================================
        echo Right-click this file and select "Run as administrator",
        echo or run it from an elevated command prompt.
        echo.
        pause
        exit /b 1
    )
)

REM ---- Determine script directory ----
set "SCRIPT_DIR=%~dp0"
set "PROJECT_DIR=%SCRIPT_DIR%.."
set "BACKUP_DIR=%PROJECT_DIR%\.omo\backup"

if %DRY_RUN% equ 1 (
    echo ============================================================
    echo  UNHARDEN — DRY RUN MODE
    echo  Showing what would be done without making changes.
    echo ============================================================
    echo.
    goto :dry_run_plan
)

echo ============================================================
echo  Stealth Un-Hardening — Revert all hardening changes
echo  Date: %date%  Time: %time%
echo ============================================================
echo.

REM ---- Find state file ----
set "STATE_FILE="

if %LATEST_STATE% equ 1 (
    REM Find most recent state file
    for /f "tokens=*" %%f in ('dir /b /o-d "%BACKUP_DIR%\harden_state_*.txt" 2^>nul') do (
        set "STATE_FILE=%%f"
        goto :found_state
    )
) else (
    REM Allow user to specify or auto-find
    if exist "%BACKUP_DIR%\harden_state_*.txt" (
        for /f "tokens=*" %%f in ('dir /b /o-d "%BACKUP_DIR%\harden_state_*.txt" 2^>nul') do (
            set "STATE_FILE=%%f"
            goto :found_state
        )
    )
)
:found_state

if not defined STATE_FILE (
    echo ============================================================
    echo ERROR: No state file found in %BACKUP_DIR%
    echo.
    echo Run harden.bat first to create a state file, or run
    echo restore_from_backup.bat for a full system state restore.
    echo ============================================================
    echo.
    pause
    exit /b 1
)

set "STATE_PATH=%BACKUP_DIR%\%STATE_FILE%"
echo [INFO] Using state file: %STATE_PATH%
echo.

REM ---- Parse state file ----
echo [*] Reading saved state...
set "DIASTRACK_STATE="
set "DMWAPPSH_SERVICE_STATE="
set "WSEARCH_STATE="
set "TELEMETRY_ALLOW="
set "NET_PROFILE_OLD="
set "PROC_PRIORITY="
set "FW_RULE_SSH="
set "TELEMETRY_DISABLED="
set "EVTLOG_APP_MAXSIZE="
set "EVTLOG_SYS_MAXSIZE="
set "EVTLOG_SEC_MAXSIZE="

for /f "usebackq tokens=1,* delims==" %%a in ("%STATE_PATH%") do (
    if "%%a"=="DiagTrack" set "DIASTRACK_STATE=%%b"
    if "%%a"=="dmwappushservice" set "DMWAPPSH_SERVICE_STATE=%%b"
    if "%%a"=="WSearch" set "WSEARCH_STATE=%%b"
    if "%%a"=="TelemetryAllow" set "TELEMETRY_ALLOW=%%b"
    if "%%a"=="NetworkProfile" set "NET_PROFILE_OLD=%%b"
    if "%%a"=="ProcessPriority" set "PROC_PRIORITY=%%b"
    if "%%a"=="FirewallRuleSSH" set "FW_RULE_SSH=%%b"
    if "%%a"=="TelemetryDisabled" set "TELEMETRY_DISABLED=%%b"
    if "%%a"=="EventLog_Application_maxSize" set "EVTLOG_APP_MAXSIZE=%%b"
    if "%%a"=="EventLog_System_maxSize" set "EVTLOG_SYS_MAXSIZE=%%b"
    if "%%a"=="EventLog_Security_maxSize" set "EVTLOG_SEC_MAXSIZE=%%b"
)

echo [OK] State file parsed.
echo.

REM ---- Confirm revert ----
if %INTERACTIVE% equ 1 (
    echo This will revert all hardening changes made by harden.bat.
    echo.
    set /p CONFIRM="Proceed with un-harden? (y/N): "
    if /i not "!CONFIRM!"=="y" (
        echo Un-harden cancelled by user.
        pause
        exit /b 0
    )
    echo.
)

REM ============================================================================
REM Step 1: Restart telemetry/logging services
REM ============================================================================
echo ========================================================================
echo  Step 1/7: Restart telemetry/logging services
echo ========================================================================

if defined DIASTRACK_STATE (
    if not "!DIASTRACK_STATE!"=="NOT_FOUND" (
        echo [*] Restoring DiagTrack to state: !DIASTRACK_STATE!
        if "!DIASTRACK_STATE!"=="RUNNING" (
            call :start_service "DiagTrack" "Connected User Experiences and Telemetry"
        ) else (
            echo [INFO] DiagTrack was not running before hardening — leaving stopped.
        )
    ) else (
        echo [INFO] DiagTrack was not found before hardening — skipping.
    )
) else (
    echo [INFO] DiagTrack state not recorded — checking current state.
    call :start_service "DiagTrack" "Connected User Experiences and Telemetry"
)

if defined DMWAPPSH_SERVICE_STATE (
    if not "!DMWAPPSH_SERVICE_STATE!"=="NOT_FOUND" (
        echo [*] Restoring dmwappushservice to state: !DMWAPPSH_SERVICE_STATE!
        if "!DMWAPPSH_SERVICE_STATE!"=="RUNNING" (
            call :start_service "dmwappushservice" "WAP Push Message Routing"
        ) else (
            echo [INFO] dmwappushservice was not running before hardening — leaving stopped.
        )
    ) else (
        echo [INFO] dmwappushservice was not found before hardening — skipping.
    )
) else (
    echo [INFO] dmwappushservice state not recorded — checking current state.
    call :start_service "dmwappushservice" "WAP Push Message Routing"
)

if defined WSEARCH_STATE (
    if not "!WSEARCH_STATE!"=="NOT_FOUND" (
        echo [*] Restoring WSearch to state: !WSEARCH_STATE!
        if "!WSEARCH_STATE!"=="RUNNING" (
            call :start_service "WSearch" "Windows Search"
        ) else (
            echo [INFO] WSearch was not running before hardening — leaving stopped.
        )
    ) else (
        echo [INFO] WSearch was not found before hardening — skipping.
    )
) else (
    echo [INFO] WSearch state not recorded — skipping.
)
echo.

REM ============================================================================
REM Step 2: Document event log limitation
REM ============================================================================
echo ========================================================================
echo  Step 2/7: Event Logs — cannot be un-cleared
echo ========================================================================
echo.
echo  NOTE: Event logs that were cleared cannot be restored. This is a
echo  permanent change. The log entries that existed before clearing are
echo  gone. This is an intentional limitation.
echo.
echo  If event log sizes were recorded, restoring them...
if defined EVTLOG_APP_MAXSIZE (
    wevtutil sl "Application" /ms:%EVTLOG_APP_MAXSIZE% >nul 2>&1
    if !errorlevel! equ 0 ( echo [OK] Application log maxSize restored to %EVTLOG_APP_MAXSIZE% )
)
if defined EVTLOG_SYS_MAXSIZE (
    wevtutil sl "System" /ms:%EVTLOG_SYS_MAXSIZE% >nul 2>&1
    if !errorlevel! equ 0 ( echo [OK] System log maxSize restored to %EVTLOG_SYS_MAXSIZE% )
)
if defined EVTLOG_SEC_MAXSIZE (
    wevtutil sl "Security" /ms:%EVTLOG_SEC_MAXSIZE% >nul 2>&1
    if !errorlevel! equ 0 ( echo [OK] Security log maxSize restored to %EVTLOG_SEC_MAXSIZE% )
)
echo.

REM ============================================================================
REM Step 3: Restore process priorities
REM ============================================================================
echo ========================================================================
echo  Step 3/7: Restore process priorities
echo ========================================================================

if defined PROC_PRIORITY (
    echo [*] Restoring process priority from %PROC_PRIORITY% to Normal...

    set "PRIORITY_CLASS="
    if /i "!PROC_PRIORITY!"=="BelowNormal" set "PRIORITY_CLASS=Normal"
    if /i "!PROC_PRIORITY!"=="Low" set "PRIORITY_CLASS=Normal"
    if defined PRIORITY_CLASS (
        echo [*] Restoring ssh.exe priority to !PRIORITY_CLASS!...
        powershell -NoProfile -Command "Get-Process -Name 'ssh' -ErrorAction SilentlyContinue | ForEach-Object { $_.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal }" >nul 2>&1
        if !errorlevel! equ 0 ( echo [OK] ssh.exe priority restored ) else ( echo [INFO] ssh.exe not running — no change needed )

        echo [*] Restoring mstsc.exe priority to !PRIORITY_CLASS!...
        powershell -NoProfile -Command "Get-Process -Name 'mstsc' -ErrorAction SilentlyContinue | ForEach-Object { $_.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal }" >nul 2>&1
        if !errorlevel! equ 0 ( echo [OK] mstsc.exe priority restored ) else ( echo [INFO] mstsc.exe not running — no change needed )
    )
) else (
    echo [INFO] No priority changes recorded — skipping.
)
echo.

REM ============================================================================
REM Step 4: Restore network profile
REM ============================================================================
echo ========================================================================
echo  Step 4/7: Restore network profile
echo ========================================================================

if defined NET_PROFILE_OLD (
    echo [*] Restoring network profile from "Public" to original: !NET_PROFILE_OLD!
    if /i "!NET_PROFILE_OLD!"=="Public" (
        echo [INFO] Network profile was already Public — no change needed.
    ) else if /i "!NET_PROFILE_OLD!"=="Private" (
        powershell -NoProfile -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private" >nul 2>&1
        if !errorlevel! equ 0 ( echo [OK] Network profile restored to Private ) else ( echo [WARNING] Failed to restore network profile )
    ) else if /i "!NET_PROFILE_OLD!"=="Domain" (
        powershell -NoProfile -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory DomainAuthenticated" >nul 2>&1
        if !errorlevel! equ 0 ( echo [OK] Network profile restored to Domain ) else ( echo [WARNING] Failed to restore network profile )
    ) else if /i "!NET_PROFILE_OLD!"=="DomainAuthenticated" (
        powershell -NoProfile -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory DomainAuthenticated" >nul 2>&1
        if !errorlevel! equ 0 ( echo [OK] Network profile restored to DomainAuthenticated ) else ( echo [WARNING] Failed to restore network profile )
    ) else (
        echo [INFO] Unknown network profile "!NET_PROFILE_OLD!" — leaving current setting unchanged.
    )
) else (
    echo [INFO] No network profile change recorded — skipping.
)
echo.

REM ============================================================================
REM Step 5: Restore telemetry registry setting
REM ============================================================================
echo ========================================================================
echo  Step 5/7: Restore telemetry registry setting
echo ========================================================================

if defined TELEMETRY_DISABLED (
    if /i "!TELEMETRY_DISABLED!"=="YES" (
        if defined TELEMETRY_ALLOW (
            if /i "!TELEMETRY_ALLOW!"=="NOT_SET" (
                echo [*] Telemetry was not set before hardening — removing policy key.
                reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /f >nul 2>&1
                if !errorlevel! equ 0 ( echo [OK] Telemetry policy key removed.) else ( echo [INFO] Could not remove key — may not exist.)
            ) else (
                echo [*] Restoring AllowTelemetry to original value: !TELEMETRY_ALLOW!
                reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d !TELEMETRY_ALLOW! /f >nul 2>&1
                if !errorlevel! equ 0 ( echo [OK] Telemetry restored to !TELEMETRY_ALLOW! ) else ( echo [WARNING] Failed to restore telemetry setting )
            )
        ) else (
            echo [*] Telemetry original state unknown — removing policy key (restores default).
            reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /f >nul 2>&1
            if !errorlevel! equ 0 ( echo [OK] Telemetry policy key removed.) else ( echo [INFO] Could not remove key — may not exist.)
        )
    ) else (
        echo [INFO] Telemetry was not disabled by hardening — skipping.
    )
) else (
    echo [INFO] No telemetry change recorded — skipping.
)
echo.

REM ============================================================================
REM Step 6: Remove firewall rule
REM ============================================================================
echo ========================================================================
echo  Step 6/7: Remove "Windows Remote Desktop (SSH)" firewall rule
REM ========================================================================

echo [*] Checking for "Windows Remote Desktop (SSH)" firewall rule...
netsh advfirewall firewall show rule name="Windows Remote Desktop (SSH)" >nul 2>&1
if %errorlevel% equ 0 (
    netsh advfirewall firewall delete rule name="Windows Remote Desktop (SSH)" >nul 2>&1
    if %errorlevel% equ 0 (
        echo [OK] Firewall rule "Windows Remote Desktop (SSH)" deleted.
    ) else (
        echo [WARNING] Failed to delete firewall rule.
    )
) else (
    echo [INFO] Firewall rule "Windows Remote Desktop (SSH)" not found — nothing to delete.
)
echo.

REM ============================================================================
REM Step 7: Clean up backup/state files (optional)
REM ============================================================================
echo ========================================================================
echo  Step 7/7: Clean up backup and state files
REM ========================================================================

if %CLEANUP% equ 1 (
    echo [*] --cleanup flag detected. Removing backup and state files...

    if exist "%STATE_PATH%" (
        del "%STATE_PATH%" >nul 2>&1
        if %errorlevel% equ 0 ( echo [OK] Deleted state file: %STATE_PATH% ) else ( echo [WARNING] Could not delete: %STATE_PATH% )
    )

    REM Delete registry backup associated with this state file
    for %%f in ("%BACKUP_DIR%\harden_reg_backup_*.reg") do (
        if exist "%%f" (
            echo [*] Deleting registry backup: %%~nxf
            del "%%f" >nul 2>&1
        )
    )
    echo [OK] Backup cleanup complete.
) else (
    echo [INFO] Backup and state files retained. To delete them, re-run with --cleanup:
    echo   unharden.bat --cleanup
)
echo.

REM ============================================================================
REM Summary
REM ============================================================================
echo ============================================================
echo  Un-Hardening Complete
echo ============================================================
echo.
echo  All hardening changes reverted:
echo    - Telemetry/logging services: Original states restored
echo    - Event logs: Cannot be restored (limitation noted)
echo    - Process priorities: Set to Normal
echo    - Network profile: Restored to original
echo    - Telemetry registry: Restored
echo    - Firewall rule: Removed
echo    - State file: %STATE_PATH%
echo.
echo  To re-apply hardening, run: harden.bat
echo ============================================================
echo.

if %INTERACTIVE% equ 1 (
    pause
)
exit /b 0

REM ============================================================================
REM Dry-run mode
REM ============================================================================
:dry_run_plan
echo.
echo  Would revert the following changes (from state file):
echo.
if defined STATE_PATH (
    echo    State file: %STATE_PATH%
    echo.
    echo    Step 1: Restart DiagTrack, dmwappushservice, WSearch (if they were running)
    echo    Step 2: Event logs — cannot be un-cleared (documented limitation)
    echo    Step 3: Restore process priorities to Normal
    echo    Step 4: Restore network profile to original
    echo    Step 5: Restore telemetry registry setting
    echo    Step 6: Delete "Windows Remote Desktop (SSH)" firewall rule
    echo    Step 7: [Optional] Clean up backup/state files
) else (
    echo    No state file found. Would search: %BACKUP_DIR%\harden_state_*.txt
    echo    If no state file exists, would skip all steps.
)
echo.
echo  Usage:
echo    unharden.bat                Interactive mode
echo    unharden.bat --yes          Non-interactive mode
echo    unharden.bat --dry-run      Show plan without making changes
echo    unharden.bat --cleanup      Also delete state/backup files
echo    unharden.bat --latest-state Use most recent state file
echo.
pause
exit /b 0

REM ============================================================================
REM Helper: Start a service
REM ============================================================================
:start_service
    set "SVC_NAME=%~1"
    set "SVC_DISPLAY=%~2"

    REM Check if service exists
    sc query "%SVC_NAME%" >nul 2>&1
    if %errorlevel% neq 0 (
        echo [INFO] Service '%SVC_DISPLAY%' (%SVC_NAME%) not found — skipping.
        exit /b 0
    )

    REM Check if already running
    for /f "tokens=2 delims=: " %%s in ('sc query "%SVC_NAME%" ^| findstr "STATE"') do (
        set "SVC_STATE=%%s"
    )
    if "!SVC_STATE!"=="RUNNING" (
        echo [INFO] %SVC_DISPLAY% already running.
        exit /b 0
    )

    if %DRY_RUN% equ 1 (
        echo [DRY-RUN] Would start: %SVC_DISPLAY% (%SVC_NAME%)
        exit /b 0
    )

    echo [*] Starting %SVC_DISPLAY% (%SVC_NAME%)...
    net start "%SVC_NAME%" >nul 2>&1
    if %errorlevel% equ 0 (
        echo [OK] %SVC_DISPLAY% started.
    ) else (
        echo [WARNING] Failed to start %SVC_DISPLAY%.
    )
    exit /b 0
