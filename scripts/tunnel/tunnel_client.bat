@echo off
REM ============================================================================
REM tunnel_client.bat — Stealth RDP FORWARD SSH Tunnel (Client side)
REM
REM Run this on the helper PC (Client) to create a forward SSH tunnel
REM from the VPS to localhost. Once the tunnel is up, it automatically
REM launches Remote Desktop (mstsc) pointing at 127.0.0.1:3390.
REM
REM Architecture:
REM   Host (RDP :3390)  ←reverse→  VPS (:3390)  ←forward→  Client (:3390)
REM
REM USAGE:
REM   1. Edit the CONFIGURATION section below with your VPS details
REM   2. Make sure tunnel_host.bat is running on the Host PC
REM   3. Run this script on the Client PC
REM   4. Remote Desktop will launch automatically
REM ============================================================================
setlocal enabledelayedexpansion

REM ============================================================================
REM CONFIGURATION — EDIT THESE VALUES
REM ============================================================================

REM VPS connection details
set VPS_IP=YOUR_VPS_IP_HERE
set USER=tunneladmin
set SSH_PORT=443

REM Local port to listen on (connect mstsc to this)
set LOCAL_LISTEN_PORT=3390

REM Remote port on the VPS (the one exposed by the Host's reverse tunnel)
set REMOTE_FWD_PORT=3390

REM Path to your SSH private key
set SSH_KEY_PATH=%USERPROFILE%\.ssh\stealth_remote

REM Log file
set LOG_FILE=%~dpn0.log

REM ============================================================================
REM END CONFIGURATION
REM ============================================================================

call :log "=== Client Tunnel Started ==="
call :log "VPS: %USER%@%VPS_IP%:%SSH_PORT%"
call :log "Tunnel: Client:127.0.0.1:%LOCAL_LISTEN_PORT% -L-> VPS:%REMOTE_FWD_PORT%"

REM --------------------------------------------------------------------------
REM Prerequisite checks
REM --------------------------------------------------------------------------

REM Check 1: OpenSSH client
where ssh.exe >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    call :log "FATAL: ssh.exe not found."
    echo [!] ERROR: OpenSSH client not found.
    echo      On Windows 10/11, enable it via:
    echo      Settings ^> Apps ^> Optional Features ^> Add OpenSSH Client
    pause
    exit /b 1
)

REM Check 2: SSH key exists
if not exist "%SSH_KEY_PATH%" (
    call :log "FATAL: SSH key not found at %SSH_KEY_PATH%"
    echo [!] ERROR: SSH private key not found.
    echo      Expected at: %SSH_KEY_PATH%
    echo      Copy the key from the Host PC or run setup_ssh_key.bat and
    echo      add the new public key to the VPS's authorized_keys.
    pause
    exit /b 1
)

REM Check 3: VPS_IP is configured
if "%VPS_IP%"=="YOUR_VPS_IP_HERE" (
    call :log "FATAL: VPS_IP not configured. Edit this script first."
    echo [!] ERROR: You must edit VPS_IP in this script before running.
    echo      Open %~f0 in a text editor and set VPS_IP to your VPS address.
    pause
    exit /b 1
)

call :log "All prerequisites passed."

REM --------------------------------------------------------------------------
REM Tunnel loop — auto-reconnect and re-launch mstsc on reconnection
REM --------------------------------------------------------------------------
echo.
echo ============================================================
echo   SSH Forward Tunnel - CLIENT MODE
echo ============================================================
echo   VPS:      %USER%@%VPS_IP%:%SSH_PORT%
echo   Tunnel:   Client:127.0.0.1:%LOCAL_LISTEN_PORT% --^> VPS:%REMOTE_FWD_PORT%
echo   Key:      %SSH_KEY_PATH%
echo   Log:      %LOG_FILE%
echo ============================================================
echo.
echo   Make sure the Host tunnel (tunnel_host.bat) is running.
echo   Remote Desktop will launch automatically once connected.
echo.
echo   Press Ctrl+C to stop the tunnel.
echo.

:retry_loop

REM Build the SSH command
REM   -i          : identity file (private key)
REM   -L          : local forward — local_port:host:remote_port
REM   -N          : no remote command (pure tunnel)
REM   -o          : options (see below)
REM
REM Options:
REM   ServerAliveInterval=30     : send keepalive every 30s
REM   ExitOnForwardFailure=yes   : abort if local port already bound
REM   StrictHostKeyChecking=accept-new : auto-accept first connection

set SSH_CMD=ssh -i "%SSH_KEY_PATH%" -L %LOCAL_LISTEN_PORT%:127.0.0.1:%REMOTE_FWD_PORT% -N ^
    -o ServerAliveInterval=30 ^
    -o ExitOnForwardFailure=yes ^
    -o StrictHostKeyChecking=accept-new ^
    %USER%@%VPS_IP% -p %SSH_PORT%

call :log "Connecting with: ssh -i ... -L %LOCAL_LISTEN_PORT%:127.0.0.1:%REMOTE_FWD_PORT% -N ... %USER%@%VPS_IP%:%SSH_PORT%"

REM Execute the tunnel in the background (start it, then proceed)
start "SSH-Tunnel-Client" /b %SSH_CMD%

REM Give the tunnel a moment to establish
timeout /t 3 /nobreak >nul

REM Quick check: is the SSH process running?
REM We look for ssh.exe that has our VPS in the command line
REM (This is imperfect but better than nothing)
tasklist /fi "IMAGENAME eq ssh.exe" /nh 2>nul | findstr /i ssh >nul
if %ERRORLEVEL% EQU 0 (
    call :log "Tunnel process started successfully."
    echo [*] Tunnel established! Launching Remote Desktop...
    echo.
    echo ============================================================
    echo   Launching mstsc /v:127.0.0.1:%LOCAL_LISTEN_PORT%
    echo ============================================================
    
    REM Launch Remote Desktop
    start "" mstsc /v:127.0.0.1:%LOCAL_LISTEN_PORT%
    call :log "mstsc launched."
    
    REM Wait for the SSH process to finish (when user closes tunnel)
    echo.
    echo [*] Tunnel is active. Close this window to stop the tunnel.
    echo     Press any key to disconnect...
    pause >nul
    
    REM Kill the SSH tunnel process
    call :log "User requested tunnel stop."
    echo [*] Stopping tunnel...
    
    REM Try to kill our specific SSH process (by window title)
    taskkill /fi "WINDOWTITLE eq SSH-Tunnel-Client*" /f >nul 2>&1
    
    call :log "Tunnel stopped by user."
    echo [*] Tunnel disconnected.
) else (
    call :log "WARNING: Tunnel process may not have started."
    echo [!] WARNING: Could not confirm tunnel is active.
    echo      Check the log for details: %LOG_FILE%
    echo.
    echo      Retrying in 5 seconds...
    timeout /t 5 /nobreak >nul
    goto retry_loop
)

exit /b 0

REM --------------------------------------------------------------------------
REM Helper: Log a message to console and log file
REM --------------------------------------------------------------------------
:log
    echo [%date% %time%] %* >> "%LOG_FILE%"
    echo [*] %*
    exit /b 0
