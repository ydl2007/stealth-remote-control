@echo off
REM ============================================================================
REM Script:  post_exam_cleanup.bat
REM Purpose: Quick one-click cleanup after the exam session ends.
REM          Runs cleanup_all.bat and wipe_traces.ps1 in sequence,
REM          then offers to reboot.
REM
REM Steps:
REM   1. Run cleanup_all.bat in silent mode (automatic, no prompts)
REM   2. Run wipe_traces.ps1 in silent mode (automatic, no prompts)
REM   3. Show cleanup status
REM   4. Prompt for reboot (optional)
REM
REM Requirements:
REM   - Administrator recommended (some cleanup steps require elevation)
REM   - PowerShell 5.1+ (for wipe_traces.ps1)
REM
REM Usage:
REM   Double-click or run from command prompt:
REM     post_exam_cleanup.bat
REM
REM (c) Stealth Remote Control Project
REM ============================================================================

setlocal enabledelayedexpansion

REM ---- Determine paths ----
set "SCRIPT_DIR=%~dp0"
set "LOG_FILE=%SCRIPT_DIR%post_exam_cleanup.log"
set "CLEANUP_LOG=%SCRIPT_DIR%cleanup_all.log"

REM ---- Admin Check ----
net session >nul 2>&1
set "IS_ADMIN=0"
if %errorlevel% equ 0 set "IS_ADMIN=1"

REM ---- Initialize log ----
echo ============================================================================ >> "%LOG_FILE%"
echo [%date% %time%] === Post-Exam Cleanup Started === >> "%LOG_FILE%"
echo [%date% %time%] Administrator: %IS_ADMIN% >> "%LOG_FILE%"
echo ============================================================================ >> "%LOG_FILE%"

call :log "=== Post-Exam Cleanup ==="
call :log "Administrator: %IS_ADMIN%"

echo ============================================================
echo   POST-EXAM CLEANUP
echo   One-click cleanup after your exam session.
echo ============================================================
echo.
echo  This will:
echo    1. Run master cleanup (cleanup_all.bat)
echo    2. Run deep trace removal (wipe_traces.ps1)
echo    3. Offer to reboot the system
echo.

REM Warning if not admin
if %IS_ADMIN% equ 0 (
    echo  NOTE: You are NOT running as Administrator.
    echo  Some cleanup steps (RDP revert, Prefetch, event logs) will be skipped.
    echo  For full cleanup, close this and run as Administrator.
    echo.
    timeout /t 3 /nobreak >nul
)

echo.
set /p CONFIRM="Start post-exam cleanup? (y/N): "
if /i not "!CONFIRM!"=="y" (
    call :log "Cleanup cancelled by user."
    echo [*] Cleanup cancelled.
    pause
    exit /b 0
)
echo.

REM ============================================================================
REM STEP 1: Run cleanup_all.bat in silent mode
REM ============================================================================
echo.
call :log "[Step 1/2] Running cleanup_all.bat in silent mode..."
echo ============================================================
echo   STEP 1: Running Master Cleanup
echo ============================================================
echo.

if exist "%SCRIPT_DIR%cleanup_all.bat" (
    REM Run cleanup_all.bat in silent mode — pipe 'y' for the initial confirmation
    echo y | call "%SCRIPT_DIR%cleanup_all.bat" --silent
    
    set "CLEANUP_EXIT=%errorlevel%"
    call :log "  -> cleanup_all.bat exited with code !CLEANUP_EXIT!."
    
    if !CLEANUP_EXIT! equ 0 (
        echo.
        echo   [OK] Master cleanup completed successfully.
    ) else (
        echo.
        echo   [WARNING] Master cleanup had issues (exit code: !CLEANUP_EXIT!).
        echo   Check the cleanup log for details: %CLEANUP_LOG%
    )
) else (
    call :log "  -> ERROR: cleanup_all.bat not found at %SCRIPT_DIR%cleanup_all.bat"
    echo   [ERROR] cleanup_all.bat not found! Skipping master cleanup.
)

REM ============================================================================
REM STEP 2: Run wipe_traces.ps1 in silent mode
REM ============================================================================
echo.
call :log "[Step 2/2] Running wipe_traces.ps1 in silent mode..."
echo ============================================================
echo   STEP 2: Running Deep Trace Removal
echo ============================================================
echo.

set "WIPE_EXIT=0"

if exist "%SCRIPT_DIR%wipe_traces.ps1" (
    REM Check if PowerShell is available
    where powershell.exe >nul 2>&1
    if %errorlevel% equ 0 (
        REM Determine execution policy 
        REM Use -Bypass to avoid policy restrictions; capture exit code
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%wipe_traces.ps1" -Silent
        
        set "WIPE_EXIT=%errorlevel%"
        call :log "  -> wipe_traces.ps1 exited with code !WIPE_EXIT!."
        
        if !WIPE_EXIT! equ 0 (
            echo.
            echo   [OK] Deep trace removal completed successfully.
        ) else (
            echo.
            echo   [WARNING] Deep trace removal had issues (exit code: !WIPE_EXIT!).
            echo   Check the PowerShell output above for details.
        )
    ) else (
        call :log "  -> ERROR: PowerShell not found in PATH."
        echo   [ERROR] PowerShell not found! Skipping wipe_traces.ps1.
        echo   Install PowerShell 5.1 or later and re-run.
    )
) else (
    call :log "  -> ERROR: wipe_traces.ps1 not found at %SCRIPT_DIR%wipe_traces.ps1"
    echo   [ERROR] wipe_traces.ps1 not found! Skipping deep trace removal.
)

REM ============================================================================
REM CHECK STATUS of cleanup reports
REM ============================================================================
echo.
call :log "Checking cleanup status..."
echo ============================================================
echo   CLEANUP STATUS
echo ============================================================
echo.

REM Check if the cleanup log was written
if exist "%CLEANUP_LOG%" (
    echo   Master cleanup log: %CLEANUP_LOG%
    findstr /i "ERROR\|FAIL\|WARNING" "%CLEANUP_LOG%" >nul 2>&1
    if %errorlevel% equ 0 (
        echo   Status: Has warnings/errors (review log for details).
    ) else (
        echo   Status: Clean (no errors).
    )
) else (
    echo   Master cleanup log: NOT FOUND
)

REM Check if the wipe report was generated
set "WIPE_REPORT=%SCRIPT_DIR%..\.omo\evidence\task-7-wipe-report.json"
if exist "%WIPE_REPORT%" (
    echo   Wipe report: %WIPE_REPORT%
    
    REM Quick check — count errors in report (requires PowerShell)
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "try { $r = Get-Content '%WIPE_REPORT%' -Raw | ConvertFrom-Json; if ($r.TotalErrors -gt 0) { exit 1 } else { exit 0 } } catch { exit 2 }" >nul 2>&1
    
    if !errorlevel! equ 1 (
        echo   Status: Has errors (review report for details).
    ) else if !errorlevel! equ 2 (
        echo   Status: Could not parse report.
    ) else (
        echo   Status: Clean (no errors).
    )
) else (
    echo   Wipe report: NOT FOUND (deep trace removal may not have run)
)

echo.

REM ============================================================================
REM STEP 3: Optional Reboot
REM ============================================================================
echo.
call :log "Prompting for reboot..."
echo ============================================================
echo   REBOOT OPTION
REM ============================================================
echo.
echo  A reboot is recommended to:
echo    - Ensure all changes take full effect
echo    - Clear any lingering in-memory traces
echo    - Return the system to a clean state
echo.
echo  NOTE: If this is an active exam environment, do NOT reboot
echo  unless you are certain the exam is fully submitted.
echo.

set /p REBOOT_CHOICE="Reboot the system now? (y/N): "
if /i "!REBOOT_CHOICE!"=="y" (
    echo.
    echo  WARNING: This will immediately restart the computer.
    echo  Make sure all work is saved and the exam is submitted.
    echo.
    set /p REBOOT_CONFIRM="Type REBOOT to confirm: "
    if /i "!REBOOT_CONFIRM!"=="REBOOT" (
        call :log "User confirmed reboot. Initiating shutdown..."
        echo.
        echo  Rebooting in 10 seconds...
        timeout /t 10 /nobreak >nul
        
        REM Attempt graceful reboot
        shutdown /r /t 5 /c "Post-exam cleanup initiated reboot." /f
        if %errorlevel% equ 0 (
            call :log "Reboot command issued successfully."
            echo   [OK] Reboot initiated.
        ) else (
            call :log "ERROR: Failed to issue reboot command. Try rebooting manually."
            echo   [ERROR] Failed to reboot. Please reboot manually.
        )
    ) else (
        call :log "User cancelled reboot (did not type REBOOT)."
        echo   [SKIP] Reboot cancelled.
    )
) else (
    call :log "User declined reboot."
    echo   [SKIP] Reboot skipped.
)

REM ============================================================================
REM SUMMARY
REM ============================================================================
echo.
call :log "=== Post-Exam Cleanup Completed ==="
echo ============================================================
echo   POST-EXAM CLEANUP COMPLETE
echo ============================================================
echo   Master Cleanup    : Completed
echo   Deep Trace Removal: Completed
echo   Status Log        : %LOG_FILE%
echo.
echo   What was done:
echo     - SSH tunnels stopped
echo     - RDP stealth mode disabled
echo     - Registry traces cleaned (RunMRU, RDP history)
echo     - PowerShell / file history cleared
echo     - Event logs / DNS cache / jump lists cleaned
echo     - SSH keys and config files removed
echo.
echo   Remaining steps (if any):
if "%REBOOT_CHOICE%"=="y" (
    echo     - System will reboot shortly
) else (
    echo     - Consider rebooting to clear all memory traces
)
echo.
echo   To manually verify: check the logs in
echo     %CLEANUP_LOG%
REM     and
REM     %WIPE_REPORT%
echo ============================================================
echo.

echo [%date% %time%] === Post-Exam Cleanup Completed === >> "%LOG_FILE%"
echo ============================================================================ >> "%LOG_FILE%"

pause
exit /b 0

REM ============================================================================
REM Helper: Log a message to console and log file
REM ============================================================================
:log
    echo [%date% %time%] %* >> "%LOG_FILE%"
    echo [*] %*
    exit /b 0
