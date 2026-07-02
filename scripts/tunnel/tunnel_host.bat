@echo off
REM ============================================================================
REM tunnel_host.bat — Stealth RDP REVERSE SSH Tunnel (Host side)
REM
REM SUMMARY: Run this on the exam PC (Host) to create a reverse SSH tunnel
REM          to the VPS. The VPS's port 3390 is forwarded to the Host's
REM          local RDP server on 127.0.0.1:3390.
REM
REM          Architecture:
REM            Host (RDP :3390)  ←reverse→  VPS (:3390)  ←forward→  Client
REM
REM USAGE:
REM   1. Edit the CONFIGURATION section below with your VPS details
REM   2. Run this script — it will keep the tunnel alive and auto-reconnect
REM   3. Press Ctrl+C to stop
REM ============================================================================
setlocal enabledelayedexpansion

REM ============================================================================
REM CONFIGURATION — EDIT THESE VALUES
REM ============================================================================

REM VPS connection details
set VPS_IP=YOUR_VPS_IP_HERE
set USER=tunneladmin
set SSH_PORT=443

REM Local RDP port on the Host (RDP listener)
set LOCAL_RDP_PORT=3390

REM Remote port on the VPS that maps back to Host's RDP
set REMOTE_FWD_PORT=3390

REM Path to your SSH private key
set SSH_KEY_PATH=%USERPROFILE%\.ssh\stealth_remote

REM Log file
set LOG_FILE=%~dpn0.log

REM ============================================================================
REM END CONFIGURATION
REM ============================================================================

call :log "=== Host Tunnel Started ==="
call :log "VPS: %USER%@%VPS_IP%:%SSH_PORT%"
call :log "Tunnel: VPS:%REMOTE_FWD_PORT% -R-> Host:127.0.0.1:%LOCAL_RDP_PORT%"

REM --------------------------------------------------------------------------
REM Prerequisite checks
REM --------------------------------------------------------------------------

REM Check 1: OpenSSH client
where ssh.exe >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    call :log "FATAL: ssh.exe not found. Run setup_ssh_key.bat first."
    echo [!] ERROR: OpenSSH client not found.
    echo      Run setup_ssh_key.bat to install it.
    pause
    exit /b 1
)

REM Check 2: SSH key exists
if not exist "%SSH_KEY_PATH%" (
    call :log "FATAL: SSH key not found at %SSH_KEY_PATH%"
    echo [!] ERROR: SSH private key not found.
    echo      Expected at: %SSH_KEY_PATH%
    echo      Run setup_ssh_key.bat to generate one.
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
REM Tunnel loop — keep the connection alive with auto-reconnect
REM --------------------------------------------------------------------------
echo.
echo ============================================================
echo   SSH Reverse Tunnel - HOST MODE
echo ============================================================
echo   VPS:      %USER%@%VPS_IP%:%SSH_PORT%
echo   Tunnel:   VPS:%REMOTE_FWD_PORT% ^<-- Host:127.0.0.1:%LOCAL_RDP_PORT%
echo   Key:      %SSH_KEY_PATH%
echo   Log:      %LOG_FILE%
echo ============================================================
echo.
echo   Press Ctrl+C to stop the tunnel.
echo.

:retry_loop

REM Build the SSH command
REM   -i          : identity file (private key)
REM   -R          : reverse forward — VPS_port:host:host_port
REM   -N          : no remote command (pure tunnel)
REM   -o          : options (see below)
REM
REM Options:
REM   ServerAliveInterval=30     : send keepalive every 30s
REM   ExitOnForwardFailure=yes   : abort if port already bound
REM   StrictHostKeyChecking=accept-new : auto-accept first connection

set SSH_CMD=ssh -i "%SSH_KEY_PATH%" -R %REMOTE_FWD_PORT%:127.0.0.1:%LOCAL_RDP_PORT% -N ^
    -o ServerAliveInterval=30 ^
    -o ExitOnForwardFailure=yes ^
    -o StrictHostKeyChecking=accept-new ^
    %USER%@%VPS_IP% -p %SSH_PORT%

call :log "Connecting with: ssh -i ... -R %REMOTE_FWD_PORT%:127.0.0.1:%LOCAL_RDP_PORT% -N ... %USER%@%VPS_IP%:%SSH_PORT%"

REM Execute the tunnel
%SSH_CMD%

REM If we reach here, the connection dropped
set EXIT_CODE=%ERRORLEVEL%
call :log "Tunnel disconnected with exit code %EXIT_CODE% at %date% %time%"

echo [!] Tunnel disconnected (exit code: %EXIT_CODE%).
echo     Reconnecting in 5 seconds...
timeout /t 5 /nobreak >nul

REM Loop back and retry
goto retry_loop

REM --------------------------------------------------------------------------
REM Helper: Log a message to console and log file
REM --------------------------------------------------------------------------
:log
    echo [%date% %time%] %* >> "%LOG_FILE%"
    echo [*] %*
    exit /b 0
