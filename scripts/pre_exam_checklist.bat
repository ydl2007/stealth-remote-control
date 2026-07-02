@echo off
REM ============================================================================
REM Script:  pre_exam_checklist.bat
REM Purpose: Verify everything is working BEFORE starting the exam session.
REM          Run this AFTER setting up the tunnel / RDP stealth.
REM
REM Checks performed:
REM   1. RDP port is set to 3390
REM   2. SSH tunnel is working (test connection / verify process)
REM   3. No proctoring-like processes are running
REM   4. Screen capture dependencies are ready (Python + PIL)
REM   5. Input injection dependencies are ready (Windows API access)
REM   6. Quick loopback test (connect to localhost)
REM
REM Output: Prints pass/fail for each check. Any FAIL prompts user before exit.
REM
REM Requirements:
REM   - Windows 10 / Windows 11
REM   - Some checks require Administrator
REM
REM Usage:
REM   Double-click or run from command prompt:
REM     pre_exam_checklist.bat
REM
REM (c) Stealth Remote Control Project
REM ============================================================================

setlocal enabledelayedexpansion

REM ---- Determine paths ----
set "SCRIPT_DIR=%~dp0"
set "PARENT_DIR=%SCRIPT_DIR%.."
set "HOST_SCRIPT=%PARENT_DIR%\host\main_host.py"
set "CLIENT_SCRIPT=%PARENT_DIR%\client\main_client.py"
set "LOG_FILE=%SCRIPT_DIR%pre_exam_checklist.log"

REM ---- Initialize counters ----
set "CHECKS_PASSED=0"
set "CHECKS_FAILED=0"
set "CHECKS_SKIPPED=0"
set "CHECKS_TOTAL=0"

REM ---- Admin Check ----
net session >nul 2>&1
set "IS_ADMIN=0"
if %errorlevel% equ 0 set "IS_ADMIN=1"

REM ---- Initialize log ----
echo ============================================================================ >> "%LOG_FILE%"
echo [%date% %time%] === Pre-Exam Checklist Started === >> "%LOG_FILE%"
echo ============================================================================ >> "%LOG_FILE%"

call :log "=== Pre-Exam Checklist ==="
call :log "Date: %date%  Time: %time%"
call :log "Administrator: %IS_ADMIN%"
echo.

echo ============================================================
echo   PRE-EXAM CHECKLIST
echo   Run this before starting your exam session.
echo   Date: %date%  Time: %time%
echo ============================================================
echo.
echo  Each check shows [PASS], [FAIL], or [SKIP].
echo  If any check FAILS, review the details before proceeding.
echo.

REM ============================================================================
REM CHECK 1: RDP port configured to 3390
REM ============================================================================
echo.
echo ---[ CHECK 1: RDP Port 3390 ]----------------------------------------------
call :log "[Check 1] Verifying RDP port 3390..."
set /a "CHECKS_TOTAL+=1"

REM Check registry for port 3390
set "RDP_PORT_FOUND=0"
for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber 2^>nul ^| findstr "REG_DWORD"') do (
    set /a "RDP_PORT_VAL=%%a"
    if !RDP_PORT_VAL! equ 3390 set "RDP_PORT_FOUND=1"
)

REM Also check netstat to confirm it's listening
set "RDP_LISTENING=0"
netstat -ano 2>nul | findstr "0.0.0.0:3390" | findstr LISTEN >nul 2>&1
if %errorlevel% equ 0 set "RDP_LISTENING=1"

if !RDP_PORT_FOUND! equ 1 (
    if !RDP_LISTENING! equ 1 (
        echo   [PASS] RDP is configured on port 3390 and listening.
        call :log "  PASS: RDP port 3390 configured and listening."
        set /a "CHECKS_PASSED+=1"
    ) else (
        echo   [PASS] RDP is configured on port 3390 (registry), but not yet listening.
        echo          This is normal if TermService hasn't restarted yet, or if
        echo          RDP is waiting for a connection. Proceed if tunnel is working.
        call :log "  PASS: RDP 3390 in registry (not listening — may be normal)."
        set /a "CHECKS_PASSED+=1"
    )
) else (
    echo   [FAIL] RDP port 3390 is NOT configured.
    echo          Run enable_rdp_stealth.bat as Administrator first.
    call :log "  FAIL: RDP port 3390 not configured."
    set /a "CHECKS_FAILED+=1"
)

REM ============================================================================
REM CHECK 2: SSH Tunnel status
REM ============================================================================
echo.
echo ---[ CHECK 2: SSH Tunnel ]--------------------------------------------------
call :log "[Check 2] Checking SSH tunnel status..."
set /a "CHECKS_TOTAL+=1"

set "TUNNEL_ACTIVE=0"
set "TUNNEL_PID="

REM Check for tunnel processes by window title
tasklist /fi "WINDOWTITLE eq SSH-Tunnel-Host*" /nh 2>nul | findstr /i "cmd.exe" >nul 2>&1
if %errorlevel% equ 0 (
    set "TUNNEL_ACTIVE=1"
    set "TUNNEL_TYPE=Host"
)

if !TUNNEL_ACTIVE! equ 0 (
    tasklist /fi "WINDOWTITLE eq SSH-Tunnel-Client*" /nh 2>nul | findstr /i "cmd.exe" >nul 2>&1
    if !errorlevel! equ 0 (
        set "TUNNEL_ACTIVE=1"
        set "TUNNEL_TYPE=Client"
    )
)

REM Also check for SSH processes with stealth_remote in command line
if !TUNNEL_ACTIVE! equ 0 (
    wmic process where "name='ssh.exe'" get CommandLine 2>nul | findstr /i "stealth_remote" >nul 2>&1
    if !errorlevel! equ 0 (
        set "TUNNEL_ACTIVE=1"
        set "TUNNEL_TYPE=SSH"
    )
)

REM Check if VPS_IP is configured in tunnel scripts
set "VPS_CONFIGURED=0"
if exist "%SCRIPT_DIR%tunnel\tunnel_host.bat" (
    findstr /i "YOUR_VPS_IP_HERE" "%SCRIPT_DIR%tunnel\tunnel_host.bat" >nul 2>&1
    if !errorlevel! neq 0 (
        set "VPS_CONFIGURED=1"
    )
)

if !TUNNEL_ACTIVE! equ 1 (
    echo   [PASS] Tunnel process is running (!TUNNEL_TYPE! mode).
    call :log "  PASS: Tunnel active (!TUNNEL_TYPE!)."
    set /a "CHECKS_PASSED+=1"
) else if !VPS_CONFIGURED! equ 1 (
    echo   [SKIP] No tunnel process running, but VPS IP is configured.
    echo          Start the tunnel with tunnel\start_all.bat or tunnel\tunnel_host.bat.
    call :log "  SKIP: Tunnel not running, VPS configured."
    set /a "CHECKS_SKIPPED+=1"
) else (
    echo   [FAIL] Tunnel not running AND VPS IP not configured.
    echo          Edit VPS_IP in tunnel\tunnel_host.bat (and tunnel_client.bat).
    echo          Then start the tunnel with tunnel\start_all.bat.
    call :log "  FAIL: Tunnel not configured."
    set /a "CHECKS_FAILED+=1"
)

REM Also verify SSH key exists
if exist "%USERPROFILE%\.ssh\stealth_remote" (
    echo     SSH key found at %%USERPROFILE%%\.ssh\stealth_remote
) else (
    echo     WARNING: SSH key not found at %%USERPROFILE%%\.ssh\stealth_remote
    echo     Run tunnel\setup_ssh_key.bat to generate one.
)

REM ============================================================================
REM CHECK 3: Proctoring-like processes
REM ============================================================================
echo.
echo ---[ CHECK 3: Suspicious Processes ]----------------------------------------
call :log "[Check 3] Scanning for proctoring-like processes..."
set /a "CHECKS_TOTAL+=1"

REM Known proctoring / monitoring process name fragments
set "SUSPICIOUS_NAMES=Respondus LockDown HonorLock ProctorU Proctortrack Examity ProProctor SEB SafeExamBrowser Kryterion Mettl Mercer PSI BVirtual ProctorTrack""
set "FOUND_SUSPICIOUS=0"
set "SUSPICIOUS_LIST="

for %%n in (%SUSPICIOUS_NAMES%) do (
    tasklist /fi "IMAGENAME eq %%n*" /nh 2>nul | findstr /i /v "INFO:" >nul 2>&1
    if !errorlevel! equ 0 (
        set "FOUND_SUSPICIOUS=1"
        set "SUSPICIOUS_LIST=!SUSPICIOUS_LIST!  [!!] %%n found running! "
    )
)

if !FOUND_SUSPICIOUS! equ 1 (
    echo   [FAIL] Potentially suspicious processes detected:
    echo   !SUSPICIOUS_LIST!
    call :log "  FAIL: Suspicious processes: !SUSPICIOUS_LIST!"
    set /a "CHECKS_FAILED+=1"
) else (
    echo   [PASS] No proctoring-like processes detected.
    call :log "  PASS: No suspicious processes."
    set /a "CHECKS_PASSED+=1"
)

REM Also check for screen recording / monitoring tools
tasklist /fi "IMAGENAME eq snagit.exe" /nh 2>nul | findstr /i /v "INFO:" >nul 2>&1
if !errorlevel! equ 0 (
    echo   [WARN] Snagit detected — may interfere with stealth screen capture.
)
tasklist /fi "IMAGENAME eq obs64.exe" /nh 2>nul | findstr /i /v "INFO:" >nul 2>&1
if !errorlevel! equ 0 (
    echo   [WARN] OBS detected — may be normal for streaming but keep in mind.
)

REM ============================================================================
REM CHECK 4: Screen capture dependencies
REM ============================================================================
echo.
echo ---[ CHECK 4: Screen Capture (Python + PIL) ]-------------------------------
call :log "[Check 4] Checking screen capture dependencies..."
set /a "CHECKS_TOTAL+=1"

REM Check Python
where python.exe >nul 2>&1
if %errorlevel% equ 0 (
    REM Check PIL/Pillow
    python -c "from PIL import Image, ImageGrab; print('OK')" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [PASS] Python + PIL (Pillow) are available.
        call :log "  PASS: Python+PIL ready."
        set /a "CHECKS_PASSED+=1"
    ) else (
        echo   [FAIL] Python found but PIL (Pillow) is NOT installed.
        echo          Run: pip install Pillow
        call :log "  FAIL: PIL not installed."
        set /a "CHECKS_FAILED+=1"
    )
) else (
    REM Check python3
    where python3.exe >nul 2>&1
    if !errorlevel! equ 0 (
        python3 -c "from PIL import Image, ImageGrab; print('OK')" >nul 2>&1
        if !errorlevel! equ 0 (
            echo   [PASS] Python3 + PIL (Pillow) are available.
            call :log "  PASS: Python3+PIL ready."
            set /a "CHECKS_PASSED+=1"
        ) else (
            echo   [FAIL] Python3 found but PIL (Pillow) is NOT installed.
            echo          Run: pip3 install Pillow
            call :log "  FAIL: PIL not installed for python3."
            set /a "CHECKS_FAILED+=1"
        )
    ) else (
        echo   [FAIL] Python is NOT installed or not in PATH.
        echo          Install Python 3.x from python.org and install Pillow.
        call :log "  FAIL: Python not found."
        set /a "CHECKS_FAILED+=1"
    )
)

REM Check if host script exists
if exist "%HOST_SCRIPT%" (
    echo     Host script found: %HOST_SCRIPT%
) else (
    echo   [WARN] Host script NOT found at %HOST_SCRIPT%
)

REM ============================================================================
REM CHECK 5: Input injection dependencies
REM ============================================================================
echo.
echo ---[ CHECK 5: Input Injection (Windows API) ]-------------------------------
call :log "[Check 5] Checking input injection dependencies..."
set /a "CHECKS_TOTAL+=1"

REM Check if we're on Windows (can use ctypes)
python -c "import ctypes, ctypes.wintypes; print('OK')" >nul 2>&1
if %errorlevel% equ 0 (
    echo   [PASS] Windows API access via ctypes is available.
    call :log "  PASS: ctypes+WinAPI ready."
    set /a "CHECKS_PASSED+=1"
) else (
    REM Try python3
    python3 -c "import ctypes, ctypes.wintypes; print('OK')" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [PASS] Windows API access via ctypes is available (python3).
        call :log "  PASS: ctypes+WinAPI ready (python3)."
        set /a "CHECKS_PASSED+=1"
    ) else (
        echo   [FAIL] Cannot import ctypes or ctypes.wintypes.
        echo          Input injection requires Windows + Python with ctypes.
        echo          This is expected on Linux/Mac but critical on Windows.
        call :log "  FAIL: ctypes not available."
        set /a "CHECKS_FAILED+=1"
    )
)

REM ============================================================================
REM CHECK 6: Quick loopback test
REM ============================================================================
echo.
echo ---[ CHECK 6: Loopback Test ]------------------------------------------------
call :log "[Check 6] Running loopback test..."
set /a "CHECKS_TOTAL+=1"

REM Try a simple TCP connection to verify the server
REM Check if port 3390 is actually accepting connections
echo     Testing connection to 127.0.0.1:3390...

set "LOOPBACK_OK=0"
python -c "
import socket;
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM);
s.settimeout(3);
try:
    s.connect(('127.0.0.1', 3390));
    print('OK');
except:
    print('FAIL');
finally:
    s.close()
" 2>nul | findstr "OK" >nul 2>&1

if %errorlevel% equ 0 (
    echo   [PASS] Loopback connection to 127.0.0.1:3390 successful.
    call :log "  PASS: Loopback OK."
    set /a "CHECKS_PASSED+=1"
) else (
    echo   [SKIP] Could not connect to 127.0.0.1:3390 (may be normal if Piano B).
    echo          For Piano B (custom protocol), start the host:
    echo            python "%HOST_SCRIPT%" 4444
    echo          Then test: python -c "import socket; s=socket.socket(); s.settimeout(3); s.connect(('127.0.0.1',4444)); print('OK'); s.close()"
    call :log "  SKIP: Loopback failed (expected if not running)."
    set /a "CHECKS_SKIPPED+=1"
)

REM Also check if the host script can at least be imported without errors
echo     Checking host script syntax...
python -c "import py_compile; py_compile.compile('%HOST_SCRIPT%', doraise=True)" >nul 2>&1
if %errorlevel% equ 0 (
    echo     Host script syntax: OK
) else (
    echo     Host script syntax: WARNING — may have errors
)

REM ============================================================================
REM SUMMARY
REM ============================================================================
echo.
echo ============================================================
echo   CHECKLIST SUMMARY
echo ============================================================
echo   Passed:  %CHECKS_PASSED% / %CHECKS_TOTAL%
echo   Failed:  %CHECKS_FAILED% / %CHECKS_TOTAL%
echo   Skipped: %CHECKS_SKIPPED% / %CHECKS_TOTAL%
echo ============================================================
echo.

call :log "Summary: %CHECKS_PASSED% passed, %CHECKS_FAILED% failed, %CHECKS_SKIPPED% skipped."

if %CHECKS_FAILED% gtr 0 (
    echo  !! %CHECKS_FAILED% check(s) FAILED. Review the details above.
    echo  !! Do not proceed with the exam until all critical checks pass.
    echo.
    echo  Common fixes:
    echo    - Run enable_rdp_stealth.bat as Administrator (Check 1)
    echo    - Configure VPS_IP in tunnel scripts and start tunnel (Check 2)
    echo    - Kill conflicting proctoring processes (Check 3)
    echo    - Install Python + Pillow:  pip install Pillow  (Check 4)
    echo    - Ensure you're on Windows with Python + ctypes (Check 5)
    echo.
    set /p CONTINUE="Continue anyway? (y/N): "
    if /i not "!CONTINUE!"=="y" (
        call :log "User chose not to continue after failures."
        echo.
        echo  Checklist aborted. Fix the issues and re-run this script.
        pause
        exit /b 1
    )
    call :log "User chose to continue despite failures."
) else (
    echo  All checks passed! You're ready to start.
    echo.
)

echo ============================================================
echo   Log saved to %LOG_FILE%
echo ============================================================
echo.

pause
exit /b 0

REM ============================================================================
REM Helper: Log a message to console and log file
REM ============================================================================
:log
    echo [%date% %time%] %* >> "%LOG_FILE%"
    echo [*] %*
    exit /b 0
