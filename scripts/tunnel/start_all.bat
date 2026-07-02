@echo off
REM ============================================================================
REM start_all.bat — One-click start for the Host tunnel
REM
REM Checks if RDP on alternate port 3390 is configured. If not, calls
REM the enable_rdp_stealth.bat script (in the parent directory).
REM Then launches tunnel_host.bat in a new window.
REM
REM USAGE:
REM   Double-click this file or run from command prompt.
REM   The tunnel window will open and auto-reconnect on failure.
REM ============================================================================
setlocal enabledelayedexpansion

echo ============================================================
echo   Stealth Remote Control — Starting Host Tunnel
echo ============================================================
echo.

REM --------------------------------------------------------------------------
REM Step 1: Determine the directory of this script
REM --------------------------------------------------------------------------
set SCRIPT_DIR=%~dp0
set PARENT_DIR=%SCRIPT_DIR%..

REM --------------------------------------------------------------------------
REM Step 2: Check if RDP is listening on port 3390
REM --------------------------------------------------------------------------
echo [*] Checking if RDP is configured on port 3390...
netstat -an 2>nul | findstr "0.0.0.0:3390" | findstr LISTEN >nul
if %ERRORLEVEL% EQU 0 (
    echo [*] RDP is listening on port 3390. Good.
) else (
    echo [!] RDP does not appear to be listening on port 3390.
    echo     Attempting to configure stealth RDP...
    
    REM Check if the enable script exists
    if exist "%PARENT_DIR%\enable_rdp_stealth.bat" (
        echo [*] Running enable_rdp_stealth.bat...
        call "%PARENT_DIR%\enable_rdp_stealth.bat"
        
        REM Re-check after running the enable script
        netstat -an 2>nul | findstr "0.0.0.0:3390" | findstr LISTEN >nul
        if !ERRORLEVEL! EQU 0 (
            echo [*] RDP is now configured on port 3390.
        ) else (
            echo [!] WARNING: RDP still not detected on port 3390.
            echo      The tunnel will still be attempted but may not work.
            echo.
            echo      Make sure Windows Remote Desktop is enabled:
            echo      System Properties ^> Remote ^> "Allow Remote Desktop"
            echo      Then run:  netstat -an ^| findstr 3390
        )
    ) else (
        echo [!] enable_rdp_stealth.bat not found at:
        echo      %PARENT_DIR%\enable_rdp_stealth.bat
        echo.
        echo      Please configure RDP manually on port 3390 first.
        echo      See the main README for instructions.
    )
)

echo.

REM --------------------------------------------------------------------------
REM Step 3: Verify tunnel_host.bat exists
REM --------------------------------------------------------------------------
if not exist "%SCRIPT_DIR%tunnel_host.bat" (
    echo [!!] FATAL: tunnel_host.bat not found in %SCRIPT_DIR%
    echo      Cannot start the tunnel.
    pause
    exit /b 1
)

REM --------------------------------------------------------------------------
REM Step 4: Launch tunnel_host.bat in a new window
REM --------------------------------------------------------------------------
echo [*] Launching tunnel_host.bat in a new window...
start "SSH-Tunnel-Host" cmd /c "%SCRIPT_DIR%tunnel_host.bat"

REM Wait a moment, then check if the window/process started
timeout /t 2 /nobreak >nul
tasklist /fi "WINDOWTITLE eq SSH-Tunnel-Host*" /nh 2>nul | findstr /i cmd >nul
if %ERRORLEVEL% EQU 0 (
    echo [*] Tunnel host window launched successfully.
) else (
    echo [!] Could not verify tunnel window. It may still open...
)

echo.
echo ============================================================
echo   SUMMARY
echo ============================================================
echo   Tunnel Host:   %SCRIPT_DIR%tunnel_host.bat
echo   Window Title:  SSH-Tunnel-Host
echo   Status:        Launched ^(see the new window for status^)
echo   VPS Config:    Edit tunnel_host.bat to set VPS_IP and USER
echo.
echo   To stop:       Run stop_tunnels.bat
echo   To connect:    On the Client PC, run tunnel_client.bat
echo ============================================================
echo.

exit /b 0
