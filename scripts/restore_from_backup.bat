@echo off
REM ============================================================================
REM Script:  restore_from_backup.bat
REM Purpose: Restore RDP configuration from backup files created by
REM          preflight_save_state.bat.
REM
REM What this script does:
REM   1. Scans the script directory for backup files (rdp_backup_*.reg,
REM      firewall_backup_*.txt, ports_backup_*.txt, termservice_backup_*.txt)
REM   2. Uses the most recent backup of each type
REM   3. Imports the registry backup to restore original RDP settings
REM   4. Removes the "RDP-Stealth" firewall rule if present
REM   5. Restarts TermService to apply changes
REM   6. Optionally cleans up backup files
REM
REM Requirements:
REM   - Must be run as Administrator
REM   - Backup files must exist (run preflight_save_state.bat first)
REM   - Windows 10 / Windows 11 (Pro or Enterprise)
REM
REM Usage:
REM   right-click -> "Run as administrator"
REM   or from an elevated command prompt:
REM     restore_from_backup.bat
REM     restore_from_backup.bat --cleanup   (also delete backup files after restore)
REM
REM (c) Stealth Remote Control Project
REM ============================================================================

setlocal enabledelayedexpansion

REM ---- Admin Check ----
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

set "SCRIPT_DIR=%~dp0"

REM ---- Parse command-line arguments ----
set "CLEANUP=0"
if /i "%1"=="--cleanup" set "CLEANUP=1"
if /i "%1"=="-c" set "CLEANUP=1"

echo ============================================================
echo  Restore RDP Configuration from Backup
echo ============================================================
echo.
echo  Looking for backup files in: %SCRIPT_DIR%
echo.

REM ---- Find the most recent backup files ----
echo Scanning for backup files...
echo.

REM Find latest RDP registry backup
set "REG_FILE="
for /f "tokens=*" %%f in ('dir /b /o-d "%SCRIPT_DIR%rdp_backup_*.reg" 2^>nul') do (
    set "REG_FILE=%%f"
    goto :found_reg
)
:found_reg

REM Find latest firewall backup
set "FW_FILE="
for /f "tokens=*" %%f in ('dir /b /o-d "%SCRIPT_DIR%firewall_backup_*.txt" 2^>nul') do (
    set "FW_FILE=%%f"
    goto :found_fw
)
:found_fw

REM Find latest ports backup
set "PORTS_FILE="
for /f "tokens=*" %%f in ('dir /b /o-d "%SCRIPT_DIR%ports_backup_*.txt" 2^>nul') do (
    set "PORTS_FILE=%%f"
    goto :found_ports
)
:found_ports

REM Check if we found any backups
if not defined REG_FILE (
    echo ============================================================
    echo ERROR: No RDP registry backup files found (*.reg).
    echo Please run preflight_save_state.bat first to create backups.
    echo ============================================================
    echo.
    pause
    exit /b 1
)

echo  Found backups:
if defined REG_FILE    echo    Registry : !REG_FILE!
if defined FW_FILE     echo    Firewall : !FW_FILE!
if defined PORTS_FILE  echo    Ports    : !PORTS_FILE!
echo.

REM ---- Confirm restore ----
echo WARNING: This will overwrite the current RDP configuration with
echo the backed-up state. Any changes made since the backup will be lost.
echo.
set /p CONFIRM="Proceed with restore? (y/N): "
if /i not "!CONFIRM!"=="y" (
    echo Restore cancelled by user.
    pause
    exit /b 0
)
echo.

REM ---- 1. Import registry backup ----
echo [1/4] Importing registry backup...
reg import "%SCRIPT_DIR%!REG_FILE!" >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: Registry restored from !REG_FILE!
) else (
    echo   ERROR: Failed to import registry backup.
    pause
    exit /b 1
)
echo.

REM ---- 2. Remove stealth firewall rule ----
echo [2/4] Removing "RDP-Stealth" firewall rule...
netsh advfirewall firewall delete rule name="RDP-Stealth" >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: Firewall rule "RDP-Stealth" deleted.
) else (
    echo   INFO: No "RDP-Stealth" rule found — nothing to remove.
)
echo.

REM ---- 3. Restart Terminal Services ----
echo [3/4] Restarting Terminal Services (TermService)...
net stop TermService >nul 2>&1
net start TermService >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: TermService restarted.
) else (
    echo   WARNING: TermService may not have started. Try rebooting.
)
echo.

REM ---- 4. Optional: Clean up backup files ----
echo [4/4] Backup file cleanup...
if %CLEANUP% equ 1 (
    echo   --cleanup flag detected. Deleting backup files...
    if defined REG_FILE (
        del "%SCRIPT_DIR%!REG_FILE!" >nul 2>&1
        echo   Deleted: !REG_FILE!
    )
    if defined FW_FILE (
        del "%SCRIPT_DIR%!FW_FILE!" >nul 2>&1
        echo   Deleted: !FW_FILE!
    )
    if defined PORTS_FILE (
        del "%SCRIPT_DIR%!PORTS_FILE!" >nul 2>&1
        echo   Deleted: !PORTS_FILE!
    )
    echo.
    echo   All backup files cleaned up.
) else (
    echo   Backup files retained. To delete them, re-run with --cleanup:
    echo     restore_from_backup.bat --cleanup
)
echo.

REM ---- Verification ----
echo  --- Post-restore status ---
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections 2^>nul ^| findstr "REG_DWORD"') do (
        if "%%a"=="0x0" echo   RDP State: Enabled
        if "%%a"=="0x1" echo   RDP State: Disabled
    )
)

for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber 2^>nul ^| findstr "REG_DWORD"') do (
    set /a "p=%%a"
    echo   RDP Port: !p!
)
echo.

echo ============================================================
echo  Restore complete!
echo ============================================================
echo  To verify current state, run:  check_rdp_status.bat
echo ============================================================
echo.

pause
exit /b 0
