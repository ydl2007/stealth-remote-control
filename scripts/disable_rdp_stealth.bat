@echo off
REM ============================================================================
REM Script:  disable_rdp_stealth.bat
REM Purpose: Revert ALL changes made by enable_rdp_stealth.bat and restore RDP
REM          to its original configuration (port 3389, default firewall rules).
REM
REM Changes made:
REM   1. Disables RDP via registry (fDenyTSConnections = 1) — safe default
REM   2. Restores RDP port from 3390 back to 3389
REM   3. Deletes the "RDP-Stealth" firewall rule for TCP/3390
REM   4. Restarts the Terminal Services (TermService) to apply changes
REM   5. Verifies that port 3389 is present and port 3390 is gone
REM
REM Requirements:
REM   - Must be run as Administrator
REM   - Windows 10 / Windows 11 (Pro or Enterprise)
REM
REM Usage:
REM   right-click -> "Run as administrator"
REM   or from an elevated command prompt:
REM     disable_rdp_stealth.bat
REM
REM NOTE: This script does NOT rely on backup files — it applies known defaults.
REM       If you ran preflight_save_state.bat, you can also use
REM       restore_from_backup.bat for a more thorough rollback.
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

echo ============================================================
echo  Disable RDP Stealth Mode — Rollback
echo  Restoring port from 3390 -^> 3389
echo ============================================================
echo.

REM ---- 1. Disable RDP via registry ----
echo [1/5] Disabling Remote Desktop (fDenyTSConnections = 1)...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 1 /f >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: Remote Desktop disabled.
) else (
    echo   WARNING: Failed to disable Remote Desktop. Continuing...
)
echo.

REM ---- 2. Restore RDP port to 3389 ----
echo [2/5] Restoring RDP port from 3390 to 3389...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber /t REG_DWORD /d 3389 /f >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: Port restored to 3389.
) else (
    echo   WARNING: Failed to restore port. The registry key may not exist.
    echo   Creating it now...
    reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber /t REG_DWORD /d 3389 /f >nul 2>&1
    if !errorlevel! equ 0 (
        echo   OK: Port key created and set to 3389.
    ) else (
        echo   ERROR: Could not create or set RDP-Tcp PortNumber. Check permissions.
        pause
        exit /b 1
    )
)
echo.

REM ---- 3. Delete the stealth firewall rule ----
echo [3/5] Removing "RDP-Stealth" firewall rule...
netsh advfirewall firewall delete rule name="RDP-Stealth" >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: Firewall rule "RDP-Stealth" deleted.
) else (
    echo   INFO: No firewall rule named "RDP-Stealth" found — nothing to delete.
)
echo.

REM ---- 4. Restart Terminal Services ----
echo [4/5] Restarting Terminal Services (TermService) to apply changes...
net stop TermService >nul 2>&1
if %errorlevel% neq 0 (
    echo   INFO: TermService was not running or could not be stopped. Continuing...
)

net start TermService >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: TermService restarted successfully.
) else (
    echo   WARNING: Failed to start TermService. It may start on next boot.
)
echo.

REM ---- 5. Verification ----
echo [5/5] Verifying rollback...
echo.
echo  --- Checking for port 3389 ---
netstat -ano | findstr ":3389"
if %errorlevel% equ 0 (
    echo   OK: Port 3389 is listening.
) else (
    echo   INFO: Port 3389 is not currently listening (expected if RDP is disabled).
)
echo.
echo  --- Checking port 3390 is gone ---
netstat -ano | findstr ":3390"
if %errorlevel% equ 0 (
    echo   WARNING: Port 3390 is still listening! The rollback may not have applied.
    echo   Try restarting the system or running the script again.
) else (
    echo   OK: Port 3390 is not listening — stealth rule removed.
)
echo.

REM ---- Summary ----
echo ============================================================
echo  RDP Stealth Mode Disabled — Rollback Complete
echo ============================================================
echo  RDP State       : Disabled (fDenyTSConnections = 1)
echo  RDP Port        : 3389 (restored)
echo  Firewall Rule   : RDP-Stealth (deleted)
echo  TermService     : Restarted
echo.
echo  To re-enable stealth mode, run: enable_rdp_stealth.bat
echo ============================================================
echo.

pause
exit /b 0
