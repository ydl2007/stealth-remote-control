@echo off
REM ============================================================================
REM Script:  check_rdp_status.bat
REM Purpose: Diagnostic tool to inspect current RDP configuration. Checks:
REM           - Whether RDP is enabled or disabled in the registry
REM           - Current RDP listening port number
REM           - Windows Firewall rules related to RDP
REM           - TermService (Terminal Services) running state
REM           - All listening TCP ports (so you can see what's active)
REM
REM Requirements:
REM   - Some checks require Administrator (firewall rules, service state).
REM     If not admin, most checks still work but may show limited info.
REM   - Windows 10 / Windows 11 (Pro or Enterprise)
REM
REM Usage:
REM   Double-click or run from command prompt:
REM     check_rdp_status.bat
REM
REM (c) Stealth Remote Control Project
REM ============================================================================

setlocal enabledelayedexpansion

echo ============================================================
echo  RDP Stealth — Diagnostic Status Check
echo  Date: %date%  Time: %time%
echo ============================================================
echo.

REM ---- Check admin ----
net session >nul 2>&1
set "IS_ADMIN=No"
if %errorlevel% equ 0 set "IS_ADMIN=Yes"
echo [INFO] Running as Administrator: %IS_ADMIN%
echo.

REM ---- 1. Check if RDP is enabled ----
echo ----[ 1. RDP Enabled Status ]----
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections 2^>nul ^| findstr "REG_DWORD"') do (
        set /a "RDP_VAL=%%a"
    )
    if !RDP_VAL! equ 0 (
        echo   RDP is: ENABLED (fDenyTSConnections = 0)
    ) else if !RDP_VAL! equ 1 (
        echo   RDP is: DISABLED (fDenyTSConnections = 1)
    ) else (
        echo   RDP value: !RDP_VAL! (unexpected)
    )
) else (
    echo   WARNING: RDP registry key not found. Terminal Server may not be installed.
)
echo.

REM ---- 2. Check current RDP port ----
echo ----[ 2. Current RDP Port ]----
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber 2^>nul ^| findstr "REG_DWORD"') do (
        set /a "RDP_PORT=%%a"
    )
    if !RDP_PORT! equ 3389 (
        echo   RDP Port: 3389 (default) ^<-- standard, detectable
    ) else if !RDP_PORT! equ 3390 (
        echo   RDP Port: 3390 (stealth) ^<-- stealth mode active
    ) else (
        echo   RDP Port: !RDP_PORT! (custom)
    )
) else (
    echo   WARNING: RDP-Tcp key not found. RDP may not be configured.
)
echo.

REM ---- 3. Check Windows Firewall rules for RDP ----
echo ----[ 3. Firewall Rules (RDP-related) ]----
netsh advfirewall firewall show rule name=all dir=in | findstr /i /c:"RDP" >nul 2>&1
if %errorlevel% equ 0 (
    echo   Found RDP-related inbound firewall rules:
    netsh advfirewall firewall show rule name=all dir=in | findstr /i /c:"RDP"
) else (
    echo   No RDP-related inbound firewall rules found (or not running as admin).
)
echo.

REM ---- Specifically check for RDP-Stealth rule ----
netsh advfirewall firewall show rule name="RDP-Stealth" >nul 2>&1
if %errorlevel% equ 0 (
    echo   [+] Stealth firewall rule "RDP-Stealth" IS present (TCP/3390 allowed)
) else (
    echo   [-] Stealth firewall rule "RDP-Stealth" is NOT present
)
echo.

REM ---- 4. Check TermService state ----
echo ----[ 4. Terminal Services (TermService) Status ]----
sc query TermService >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=2 delims=: " %%s in ('sc query TermService ^| findstr "STATE" 2^>nul') do (
        set "SVC_STATE=%%s"
    )
    if "!SVC_STATE!"=="RUNNING" (
        echo   TermService: RUNNING
    ) else if "!SVC_STATE!"=="STOPPED" (
        echo   TermService: STOPPED
    ) else if "!SVC_STATE!"=="PAUSED" (
        echo   TermService: PAUSED
    ) else if not "!SVC_STATE!"=="" (
        echo   TermService: !SVC_STATE!
    ) else (
        echo   TermService: Could not determine state
    )
) else (
    echo   TermService: NOT FOUND or not installed
)
echo.

REM ---- 5. Listening ports (filtered to RDP-relevant) ----
echo ----[ 5. Listening TCP Ports (RDP-relevant) ]----
netstat -ano | findstr ":3389"
if %errorlevel% equ 0 (
    echo   ^^^ Port 3389 is listening (default RDP)
) else (
    echo   Port 3389 is NOT listening
)

netstat -ano | findstr ":3390"
if %errorlevel% equ 0 (
    echo   ^^^ Port 3390 is listening (stealth RDP)
) else (
    echo   Port 3390 is NOT listening
)
echo.

REM ---- 6. All listening ports (summary) ----
echo ----[ 6. All Listening Ports (TCP) ]----
netstat -ano | findstr "LISTENING"
echo.

REM ---- Summary ----
echo ============================================================
echo  Diagnostic Summary
echo ============================================================
echo  Administrator : %IS_ADMIN%
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections 2^>nul ^| findstr "REG_DWORD"') do (
        if "%%a"=="0x0" echo  RDP Enabled    : Yes
        if "%%a"=="0x1" echo  RDP Enabled    : No
    )
)
for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber 2^>nul ^| findstr "REG_DWORD"') do (
    set /a "p=%%a"
    echo  RDP Port       : !p!
)
sc query TermService 2>nul | findstr "RUNNING" >nul && echo  TermService    : Running || echo  TermService    : Stopped
netsh advfirewall firewall show rule name="RDP-Stealth" >nul 2>&1 && echo  Stealth Rule   : Present || echo  Stealth Rule   : Not present
echo ============================================================
echo.
echo  Need to enable stealth mode?  Run: enable_rdp_stealth.bat
echo  Need to rollback?             Run: disable_rdp_stealth.bat
echo ============================================================
echo.

pause
exit /b 0
