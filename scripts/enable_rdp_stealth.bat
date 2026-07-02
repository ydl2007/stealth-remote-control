@echo off
REM ============================================================================
REM Script:  enable_rdp_stealth.bat
REM Purpose: Enable RDP in stealth mode — changes the default RDP port from 3389
REM          to 3390 and adds a matching Windows Firewall inbound rule.
REM
REM          This helps avoid detection by port scanners or proctoring software
REM          that only check for the well-known RDP port (3389).
REM
REM Changes made (all reversible by disable_rdp_stealth.bat):
REM   1. Enables RDP via registry (fDenyTSConnections = 0)
REM   2. Changes RDP port from 3389 to 3390
REM   3. Creates "RDP-Stealth" firewall rule for TCP/3390
REM   4. Restarts the Terminal Services (TermService) to apply changes
REM   5. Verifies the new port is listening
REM
REM Requirements:
REM   - Must be run as Administrator
REM   - Preflight save recommended: run preflight_save_state.bat first
REM   - Windows 10 / Windows 11 (Pro or Enterprise)
REM
REM Usage:
REM   right-click -> "Run as administrator"
REM   or from an elevated command prompt:
REM     enable_rdp_stealth.bat
REM
REM Rollback: Run disable_rdp_stealth.bat
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
echo  Enable RDP Stealth Mode
echo  Port: 3389 -^> 3390
echo ============================================================
echo.

REM ---- 1. Enable RDP via registry ----
echo [1/5] Enabling Remote Desktop (fDenyTSConnections = 0)...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: Remote Desktop enabled.
) else (
    echo   ERROR: Failed to enable Remote Desktop.
    pause
    exit /b 1
)
echo.

REM ---- 2. Change RDP port to 3390 ----
echo [2/5] Changing RDP port from 3389 to 3390...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber /t REG_DWORD /d 3390 /f >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: Port changed to 3390.
) else (
    echo   ERROR: Failed to change RDP port.
    pause
    exit /b 1
)
echo.

REM ---- 3. Add Windows Firewall rule for port 3390 ----
echo [3/5] Adding Windows Firewall rule for TCP port 3390...
netsh advfirewall firewall add rule name="RDP-Stealth" dir=in action=allow protocol=TCP localport=3390 >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: Firewall rule "RDP-Stealth" added for TCP/3390.
) else (
    echo   WARNING: Firewall rule may already exist or failed to add.
    netsh advfirewall firewall show rule name="RDP-Stealth" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   Firewall rule "RDP-Stealth" already exists — continuing.
    ) else (
        echo   ERROR: Could not create firewall rule. Check permissions.
        pause
        exit /b 1
    )
)
echo.

REM ---- 4. Restart Terminal Services ----
echo [4/5] Restarting Terminal Services (TermService)...
net stop TermService >nul 2>&1
if %errorlevel% neq 0 (
    echo   WARNING: Could not stop TermService (may already be stopped). Continuing...
)

net start TermService >nul 2>&1
if %errorlevel% equ 0 (
    echo   OK: TermService restarted successfully.
) else (
    echo   ERROR: Failed to start TermService.
    pause
    exit /b 1
)
echo.

REM ---- 5. Verification ----
echo [5/5] Verifying stealth configuration...
echo.
echo  --- Listening on TCP port 3390 ---
netstat -ano | findstr ":3390"
echo.
if %errorlevel% equ 0 (
    echo   OK: Port 3390 is now listening.
) else (
    echo   WARNING: Port 3390 is not yet listening. The service may need more time.
    echo   Run 'check_rdp_status.bat' to diagnose.
)
echo.

REM ---- Summary ----
echo ============================================================
echo  RDP Stealth Mode Enabled
echo ============================================================
echo  RDP State       : Enabled
echo  RDP Port        : 3390
echo  Firewall Rule   : RDP-Stealth (TCP/3390)
echo  TermService     : Running
echo.
echo  Connect from client with: mstsc /v:IP_ADDRESS:3390
echo.
echo  To rollback, run: disable_rdp_stealth.bat
echo ============================================================
echo.

pause
exit /b 0
