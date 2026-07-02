@echo off
REM ============================================================================
REM stop_tunnels.bat — Kill all active SSH tunnel processes
REM
REM Finds and terminates SSH processes that are running tunnel connections
REM (reverse or forward). Uses a targeted approach:
REM   1. Try to find SSH processes by window title (created by our scripts)
REM   2. Try to terminate by SSH command-line patterns
REM   3. Fall back to gentle process termination
REM   4. Last resort: force-kill all ssh.exe (with confirmation)
REM
REM Also cleans up any lingering port forward listeners.
REM ============================================================================
setlocal enabledelayedexpansion

echo ============================================================
echo   Stopping SSH Tunnel Processes
echo ============================================================
echo.

set LOG_FILE=%~dpn0.log
echo [%date% %time%] === Stop Tunnels === >> "%LOG_FILE%"

REM --------------------------------------------------------------------------
REM Helper: log and echo
REM --------------------------------------------------------------------------
:log
    echo [%date% %time%] %* >> "%LOG_FILE%"
    echo [*] %*
    exit /b 0

REM --------------------------------------------------------------------------
REM Step 1: Find and kill tunnel windows by title
REM --------------------------------------------------------------------------
call :log "Looking for tunnel windows..."

REM Window titles set by start_all.bat and tunnel_client.bat
set "TITLES=SSH-Tunnel-Host SSH-Tunnel-Client"
set FOUND_ANY=0

for %%t in (%TITLES%) do (
    tasklist /fi "WINDOWTITLE eq %%t*" /nh 2>nul | findstr /i "cmd.exe" >nul
    if !ERRORLEVEL! EQU 0 (
        call :log "Found tunnel window: %%t"
        echo [!] Stopping tunnel: %%t
        taskkill /fi "WINDOWTITLE eq %%t*" /t /f >nul 2>&1
        if !ERRORLEVEL! EQU 0 (
            call :log "Killed: %%t"
            echo [*] Killed: %%t
            set FOUND_ANY=1
        ) else (
            call :log "Could not kill %%t (may already be stopped)"
        )
    )
)

REM --------------------------------------------------------------------------
REM Step 2: Find SSH processes that look like our tunnels (by command line)
REM --------------------------------------------------------------------------
call :log "Looking for SSH processes with 3390 forwarding..."
echo [*] Checking for SSH tunnel processes on port 3390...

REM wmic is deprecated in newer Windows but still works on most installs.
REM We look for ssh.exe processes whose command line contains "3390"
for /f "tokens=2 delims=," %%a in (
    'wmic process where "name='ssh.exe' and CommandLine like '%%3390%%'" get ProcessId /format:csv 2^>nul ^| findstr /v "ProcessId"'
) do (
    set "PID=%%a"
    if not "!PID!"=="" (
        call :log "Found tunnel SSH process with PID !PID!"
        echo [!] Killing SSH tunnel PID !PID!...
        taskkill /pid !PID! /f >nul 2>&1
        if !ERRORLEVEL! EQU 0 (
            echo [*] Killed PID !PID!
        )
        set FOUND_ANY=1
    )
)

REM Also try with the more direct wmic query (no CSV format)
for /f "skip=1" %%p in ('wmic process where "name='ssh.exe'" get ProcessId 2^>nul') do (
    if not "%%p"=="" (
        set "PID=%%p"
        set "PID=!PID: =!"
        if not "!PID!"=="" (
            rem Double-check: does this SSH process have command line with stealth key?
            wmic process where "ProcessId='!PID!'" get CommandLine 2>nul | findstr /i "stealth_remote" >nul
            if !ERRORLEVEL! EQU 0 (
                call :log "Found stealth SSH PID !PID! by key path"
                echo [!] Killing stealth SSH PID !PID!...
                taskkill /pid !PID! /f >nul 2>&1
                if !ERRORLEVEL! EQU 0 (
                    echo [*] Killed PID !PID!
                )
                set FOUND_ANY=1
            )
        )
    )
)

REM --------------------------------------------------------------------------
REM Step 3: If we didn't find any tunnels, try a broader check
REM --------------------------------------------------------------------------
if %FOUND_ANY% EQU 0 (
    call :log "No targeted tunnel processes found."
    echo [*] No active tunnel processes found by title or key path.
    
    REM Check if there are any ssh.exe processes running at all
    tasklist /fi "IMAGENAME eq ssh.exe" /nh 2>nul | findstr /i ssh >nul
    if !ERRORLEVEL! EQU 0 (
        echo [!] Other SSH processes are running (may not be tunnels).
        echo      Use option 4 below to force-kill all SSH.
    ) else (
        echo [*] No SSH processes running. All tunnels are stopped.
    )
) else (
    echo.
    call :log "All identified tunnel processes terminated."
)

REM --------------------------------------------------------------------------
REM Step 4: Offer to force-kill all ssh.exe (last resort)
REM --------------------------------------------------------------------------
echo.
echo ============================================================
echo   CLEANUP OPTIONS
echo ============================================================
echo   1. Done — exit
echo   2. Kill ALL ssh.exe processes (force)
echo   3. Check for lingering port 3390 listeners
echo ============================================================
echo.
set /p CLEANUP_CHOICE=Choose an option (1-3) [1]: 
if "%CLEANUP_CHOICE%"=="" set CLEANUP_CHOICE=1

if "%CLEANUP_CHOICE%"=="2" (
    echo.
    echo [!] WARNING: This will kill ALL SSH processes, including
    echo      any non-tunnel SSH sessions you may have open.
    echo.
    set /p CONFIRM=Type YES to confirm: 
    if /i "!CONFIRM!"=="YES" (
        call :log "User requested force-kill of all ssh.exe"
        echo [*] Force-killing all ssh.exe processes...
        taskkill /f /im ssh.exe >nul 2>&1
        echo [*] Done.
    ) else (
        echo [*] Cancelled.
    )
)

if "%CLEANUP_CHOICE%"=="3" (
    echo [*] Checking for processes listening on port 3390...
    netstat -ano 2>nul | findstr "0.0.0.0:3390" | findstr LISTEN >nul
    if !ERRORLEVEL! EQU 0 (
        echo [!] Port 3390 is still in use:
        netstat -ano 2>nul | findstr "0.0.0.0:3390" | findstr LISTEN
        echo.
        echo      The owning process may be RDP itself (expected)
        echo      or a leftover tunnel process.
    ) else (
        echo [*] Port 3390 is free. Good.
    )
)

echo.
call :log "=== Tunnel cleanup completed ==="
echo [*] Done.
echo.

exit /b 0
