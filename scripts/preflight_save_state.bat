@echo off
REM ============================================================================
REM Script:  preflight_save_state.bat
REM Purpose: Save the original system state before making any RDP stealth changes.
REM          Creates backup files that restore_from_backup.bat can use later.
REM
REM Requirements:
REM   - Must be run as Administrator (reg export and netsh require elevation)
REM   - Windows 10 / Windows 11 (Pro or Enterprise)
REM
REM Backups created in the same directory as this script:
REM   rdp_backup_<timestamp>.reg     - RDP Terminal Server registry hive export
REM   firewall_backup_<timestamp>.txt - Full Windows Firewall rules export
REM   ports_backup_<timestamp>.txt    - All listening TCP/UDP ports (netstat)
REM
REM Usage:
REM   right-click -> "Run as administrator"
REM   or from an elevated command prompt:
REM     preflight_save_state.bat
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

REM ---- Determine script directory and backup location ----
set "SCRIPT_DIR=%~dp0"
set "BACKUP_DIR=%SCRIPT_DIR%"

REM ---- Generate timestamp (YYYY-MM-DD_HH-MM-SS) ----
for /f "tokens=1-6 delims=/:., " %%a in ('wmic os get localdatetime ^| find "."') do (
    set "dt=%%a"
)
set "TIMESTAMP=%dt:~0,4%-%dt:~4,2%-%dt:~6,2%_%dt:~8,2%-%dt:~10,2%-%dt:~12,2%"

echo ============================================================
echo  Preflight State Save
echo  Timestamp: %TIMESTAMP%
echo ============================================================
echo.

REM ---- 1. Export RDP-related registry keys ----
echo [1/4] Exporting RDP Terminal Server registry keys...
set "REG_FILE=%BACKUP_DIR%rdp_backup_%TIMESTAMP%.reg"
reg export "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" "%REG_FILE%" /y >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: Registry exported to %REG_FILE%
) else (
    echo   WARNING: Registry export failed or key does not exist.
    echo   The script will proceed, but backup may be incomplete.
)
echo.

REM ---- 2. Export Windows Firewall rules ----
echo [2/4] Exporting all Windows Firewall rules...
set "FW_FILE=%BACKUP_DIR%firewall_backup_%TIMESTAMP%.txt"
netsh advfirewall firewall show rule name=all verbose > "%FW_FILE%" 2>&1
if %errorlevel% equ 0 (
    echo   OK: Firewall rules exported to %FW_FILE%
) else (
    echo   WARNING: Firewall rules export failed.
)
echo.

REM ---- 3. Save current listening ports ----
echo [3/4] Saving current listening port state...
set "PORTS_FILE=%BACKUP_DIR%ports_backup_%TIMESTAMP%.txt"
netstat -ano > "%PORTS_FILE%" 2>&1
if %errorlevel% equ 0 (
    echo   OK: Port state saved to %PORTS_FILE%
) else (
    echo   WARNING: Netstat export failed.
)
echo.

REM ---- 4. Save TermService current state ----
echo [4/4] Recording TermService status...
set "SVC_FILE=%BACKUP_DIR%termservice_backup_%TIMESTAMP%.txt"
sc query TermService 2>&1 > "%SVC_FILE%"
echo.
echo   OK: Service state saved to %SVC_FILE%

echo ============================================================
echo  Preflight save complete!
echo  All backup files are in: %BACKUP_DIR%
echo  Registry : rdp_backup_%TIMESTAMP%.reg
echo  Firewall : firewall_backup_%TIMESTAMP%.txt
echo  Ports    : ports_backup_%TIMESTAMP%.txt
echo  Service  : termservice_backup_%TIMESTAMP%.txt
echo ============================================================
echo.

pause
exit /b 0
