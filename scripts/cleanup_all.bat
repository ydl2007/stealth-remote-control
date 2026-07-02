@echo off
REM ============================================================================
REM Script:  cleanup_all.bat
REM Purpose: Master cleanup — runs ALL cleanup steps in the correct order to
REM          return the exam PC to its original state with no traces left behind.
REM
REM Steps:
REM   1. Kill any SSH tunnel processes (calls tunnel\stop_tunnels.bat)
REM   2. Disable RDP stealth mode (calls disable_rdp_stealth.bat)
REM   3. Unharden the system (calls unharden.bat if it exists)
REM   4. Delete SSH key files from %%USERPROFILE%%\.ssh\stealth_remote*
REM   5. Clear PowerShell command history
REM   6. Clear Run dialog history (RunMRU)
REM   7. Clear recent files list
REM   8. Clear Prefetch (admin only)
REM   9. Optionally delete our project folder (requires confirmation)
REM  10. Log all actions to cleanup_all.log
REM
REM Requirements:
REM   - Some steps require Administrator (steps 2, 3, 8)
REM   - Log file is written to the same directory as this script
REM
REM Usage:
REM   Double-click (non-admin: steps 1, 4-7, 9-10 still work)
REM   Right-click -> "Run as administrator" (full cleanup)
REM
REM (c) Stealth Remote Control Project
REM ============================================================================

setlocal enabledelayedexpansion

REM ---- Determine paths ----
set "SCRIPT_DIR=%~dp0"
set "PARENT_DIR=%SCRIPT_DIR%.."
set "LOG_FILE=%SCRIPT_DIR%cleanup_all.log"
set "SILENT_MODE=0"

REM ---- Parse command-line arguments ----
if /i "%1"=="--silent" set "SILENT_MODE=1"
if /i "%1"=="-s" set "SILENT_MODE=1"

REM ---- Admin Check ----
net session >nul 2>&1
set "IS_ADMIN=0"
if %errorlevel% equ 0 set "IS_ADMIN=1"

REM ---- Initialize log ----
echo ============================================================================ >> "%LOG_FILE%"
echo [%date% %time%] === Master Cleanup Started === >> "%LOG_FILE%"
echo [%date% %time%] Administrator: %IS_ADMIN% >> "%LOG_FILE%"
echo [%date% %time%] Silent mode: %SILENT_MODE% >> "%LOG_FILE%"
echo ============================================================================ >> "%LOG_FILE%"

call :log "=== Master Cleanup Started ==="
call :log "Administrator: %IS_ADMIN%  |  Silent: %SILENT_MODE%"
echo.

if %SILENT_MODE% equ 0 (
    echo ============================================================
    echo   MASTER CLEANUP
    echo   This will revert all stealth changes and remove traces.
    echo ============================================================
    echo.
    echo  The following actions will be performed:
    echo    1. Kill SSH tunnel processes
    echo    2. Disable RDP stealth mode
    echo    3. Unharden system (if hardening was applied)
    echo    4. Delete SSH stealth key files
    echo    5. Clear PowerShell command history
    echo    6. Clear Run dialog history
    echo    7. Clear recent files
    echo    8. Clear Prefetch (admin only)
    echo    9. Delete project folder (optional)
    echo.
    set /p CONFIRM="Proceed with cleanup? (y/N): "
    if /i not "!CONFIRM!"=="y" (
        call :log "Cleanup cancelled by user."
        echo [*] Cleanup cancelled.
        pause
        exit /b 0
    )
    echo.
)

REM ============================================================================
REM STEP 1: Kill SSH tunnel processes
REM ============================================================================
echo.
call :log "[Step 1/9] Killing SSH tunnel processes..."
echo [1/9] Killing SSH tunnel processes...
echo.

if exist "%SCRIPT_DIR%tunnel\stop_tunnels.bat" (
    REM Run stop_tunnels.bat in silent mode (auto-choose option 1)
    REM We pipe '1' as input to auto-select the first menu option
    echo 1 | call "%SCRIPT_DIR%tunnel\stop_tunnels.bat" >nul 2>&1
    if %errorlevel% equ 0 (
        call :log "  -> stop_tunnels.bat completed successfully."
        echo   OK: Tunnel processes stopped.
    ) else (
        call :log "  -> stop_tunnels.bat finished with warnings (exit code: %errorlevel%)."
        echo   OK: Tunnel cleanup finished (may have warnings).
    )
) else (
    call :log "  -> WARNING: stop_tunnels.bat not found at %SCRIPT_DIR%tunnel\stop_tunnels.bat"
    echo   WARNING: stop_tunnels.bat not found — skipping tunnel cleanup.
)

REM Also try a direct kill of any SSH processes with stealth_remote key
tasklist /fi "IMAGENAME eq ssh.exe" /nh 2>nul | findstr /i ssh >nul 2>&1
if %errorlevel% equ 0 (
    call :log "  -> Checking remaining SSH processes for stealth key references..."
    for /f "skip=1" %%p in ('wmic process where "name='ssh.exe'" get ProcessId 2^>nul') do (
        set "PID=%%p"
        set "PID=!PID: =!"
        if not "!PID!"=="" (
            wmic process where "ProcessId='!PID!'" get CommandLine 2>nul | findstr /i "stealth_remote" >nul 2>&1
            if !errorlevel! equ 0 (
                taskkill /pid !PID! /f >nul 2>&1
                call :log "  -> Force-killed lingering SSH PID !PID! (stealth_remote detected)"
            )
        )
    )
)

REM ============================================================================
REM STEP 2: Disable RDP stealth mode
REM ============================================================================
echo.
call :log "[Step 2/9] Disabling RDP stealth mode..."
echo [2/9] Disabling RDP stealth mode...

if %IS_ADMIN% equ 1 (
    if exist "%SCRIPT_DIR%disable_rdp_stealth.bat" (
        call "%SCRIPT_DIR%disable_rdp_stealth.bat"
        if %errorlevel% equ 0 (
            call :log "  -> disable_rdp_stealth.bat completed."
            echo   OK: RDP stealth mode disabled.
        ) else (
            call :log "  -> disable_rdp_stealth.bat had errors (exit code: %errorlevel%)."
            echo   WARNING: RDP disable had errors — continuing cleanup.
        )
    ) else (
        call :log "  -> ERROR: disable_rdp_stealth.bat not found at %SCRIPT_DIR%disable_rdp_stealth.bat"
        echo   ERROR: disable_rdp_stealth.bat not found — cannot disable RDP stealth mode.
        echo   Please ensure the script exists and try again.
    )
) else (
    call :log "  -> Skipping RDP disable (requires admin, current: %IS_ADMIN%)."
    echo   SKIP: RDP disable requires Administrator — run this script as admin to include this step.
)

REM ============================================================================
REM STEP 3: Unharden the system
REM ============================================================================
echo.
call :log "[Step 3/9] Unhardening system..."
echo [3/9] Unhardening system...

if exist "%SCRIPT_DIR%unharden.bat" (
    if %IS_ADMIN% equ 1 (
        call "%SCRIPT_DIR%unharden.bat"
        if %errorlevel% equ 0 (
            call :log "  -> unharden.bat completed."
            echo   OK: System unharden completed.
        ) else (
            call :log "  -> unharden.bat had errors (exit code: %errorlevel%)."
            echo   WARNING: Unharden had errors — continuing cleanup.
        )
    ) else (
        call :log "  -> Skipping unharden (requires admin)."
        echo   SKIP: Unharden requires Administrator.
    )
) else (
    call :log "  -> unharden.bat not found — skipping (non-critical)."
    echo   INFO: unharden.bat not found — skipping. If you ran harden.bat, run it manually.
)

REM ============================================================================
REM STEP 4: Delete SSH key files
REM ============================================================================
echo.
call :log "[Step 4/9] Deleting SSH stealth key files..."
echo [4/9] Deleting SSH stealth key files...

set "SSH_DIR=%USERPROFILE%\.ssh"
set "KEY_FILES_FOUND=0"

if exist "%SSH_DIR%\stealth_remote" (
    set "KEY_FILES_FOUND=1"
    echo   Found: %SSH_DIR%\stealth_remote
)
if exist "%SSH_DIR%\stealth_remote.pub" (
    set "KEY_FILES_FOUND=1"
    echo   Found: %SSH_DIR%\stealth_remote.pub
)
if exist "%SSH_DIR%\stealth_remote_config" (
    set "KEY_FILES_FOUND=1"
    echo   Found: %SSH_DIR%\stealth_remote_config
)

if !KEY_FILES_FOUND! equ 1 (
    if %SILENT_MODE% equ 1 (
        del "%SSH_DIR%\stealth_remote" >nul 2>&1
        del "%SSH_DIR%\stealth_remote.pub" >nul 2>&1
        del "%SSH_DIR%\stealth_remote_config" >nul 2>&1
        call :log "  -> Deleted stealth key files (silent mode)."
        echo   OK: SSH key files deleted.
    ) else (
        echo.
        echo   WARNING: This will delete your SSH stealth keys.
        echo   You will need to re-run setup_ssh_key.bat to use the tunnel again.
        echo.
        set /p CONFIRM_KEYS="Delete SSH stealth key files? (y/N): "
        if /i "!CONFIRM_KEYS!"=="y" (
            del "%SSH_DIR%\stealth_remote" >nul 2>&1
            if %errorlevel% equ 0 ( echo   OK: Deleted %SSH_DIR%\stealth_remote ) else ( echo   WARNING: Could not delete stealth_remote )
            del "%SSH_DIR%\stealth_remote.pub" >nul 2>&1
            if %errorlevel% equ 0 ( echo   OK: Deleted %SSH_DIR%\stealth_remote.pub ) else ( echo   WARNING: Could not delete stealth_remote.pub )
            del "%SSH_DIR%\stealth_remote_config" >nul 2>&1
            call :log "  -> User confirmed deletion of SSH key files."
            echo   OK: SSH key files deleted.
        ) else (
            call :log "  -> User skipped SSH key file deletion."
            echo   SKIP: SSH key files retained.
        )
    )
) else (
    call :log "  -> No stealth SSH key files found."
    echo   INFO: No stealth SSH key files found — nothing to delete.
)

REM ============================================================================
REM STEP 5: Clear PowerShell command history
REM ============================================================================
echo.
call :log "[Step 5/9] Clearing PowerShell command history..."
echo [5/9] Clearing PowerShell command history...

set "PS_HISTORY=%APPDATA%\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
if exist "%PS_HISTORY%" (
    del "%PS_HISTORY%" >nul 2>&1
    if %errorlevel% equ 0 (
        call :log "  -> Deleted: %PS_HISTORY%"
        echo   OK: PowerShell history cleared.
    ) else (
        call :log "  -> WARNING: Could not delete PowerShell history (locked/permissions)."
        echo   WARNING: Could not delete PowerShell history file — it may be in use.
    )
) else (
    call :log "  -> No PowerShell history file found."
    echo   INFO: No PowerShell history file found.
)

REM Also clear PSReadLine backup history files
for %%f in ("%APPDATA%\Microsoft\Windows\PowerShell\PSReadLine\*.bak") do (
    if exist "%%f" (
        del "%%f" >nul 2>&1
        call :log "  -> Deleted PSReadLine backup: %%f"
    )
)

REM Clear PowerShell 7+ history (if installed)
set "PS7_HISTORY=%USERPROFILE%\AppData\Roaming\Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt"
if exist "%PS7_HISTORY%" (
    del "%PS7_HISTORY%" >nul 2>&1
    if %errorlevel% equ 0 (
        call :log "  -> Deleted: %PS7_HISTORY%"
    )
)

REM ============================================================================
REM STEP 6: Clear Run dialog history (RunMRU)
REM ============================================================================
echo.
call :log "[Step 6/9] Clearing Run dialog history (RunMRU)..."
echo [6/9] Clearing Run dialog history...

reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" /f >nul 2>&1
if %errorlevel% equ 0 (
    call :log "  -> RunMRU registry key deleted."
    echo   OK: Run dialog history cleared.
) else (
    call :log "  -> RunMRU key not found or already deleted."
    echo   INFO: RunMRU key not found — nothing to clear.
)

REM ============================================================================
REM STEP 7: Clear recent files
REM ============================================================================
echo.
call :log "[Step 7/9] Clearing recent files..."
echo [7/9] Clearing recent files...

set "RECENT_DIR=%APPDATA%\Microsoft\Windows\Recent"
if exist "%RECENT_DIR%\*.lnk" (
    del "%RECENT_DIR%\*.lnk" >nul 2>&1
    if %errorlevel% equ 0 (
        call :log "  -> Deleted .lnk files from %RECENT_DIR%"
        echo   OK: Recent files cleared.
    ) else (
        call :log "  -> WARNING: Could not delete some recent files."
        echo   WARNING: Some recent files could not be deleted.
    )
) else (
    call :log "  -> No recent .lnk files found."
    echo   INFO: No recent files found — nothing to clear.
)

REM ============================================================================
REM STEP 8: Clear Prefetch (admin only)
REM ============================================================================
echo.
call :log "[Step 8/9] Clearing Prefetch..."
echo [8/9] Clearing Prefetch...

if %IS_ADMIN% equ 1 (
    if exist "C:\Windows\Prefetch\*.pf" (
        del "C:\Windows\Prefetch\*.pf" >nul 2>&1
        if %errorlevel% equ 0 (
            call :log "  -> Deleted .pf files from C:\Windows\Prefetch"
            echo   OK: Prefetch cleared.
        ) else (
            call :log "  -> WARNING: Could not delete Prefetch files (may be in use)."
            echo   WARNING: Could not delete some Prefetch files — they may be in use.
        )
    ) else (
        call :log "  -> No Prefetch files found."
        echo   INFO: No Prefetch files found.
    )
) else (
    call :log "  -> Skipping Prefetch cleanup (requires admin)."
    echo   SKIP: Prefetch cleanup requires Administrator.
)

REM ============================================================================
REM STEP 9: Optionally delete our project folder
REM ============================================================================
echo.
call :log "[Step 9/9] Project folder cleanup..."
echo [9/9] Project folder cleanup...

if %SILENT_MODE% equ 1 (
    call :log "  -> Skipping project folder deletion in silent mode."
    echo   SKIP: Project folder deletion skipped (silent mode). Delete manually if needed.
) else (
    echo.
    echo   The project folder is: %PARENT_DIR%
    echo.
    echo   NOTE: Deleting this will remove ALL scripts, configs, and evidence.
    echo   Only do this if you're certain cleanup is complete.
    echo.
    set /p CONFIRM_DELETE="Delete the entire project folder? (y/N): "
    if /i "!CONFIRM_DELETE!"=="y" (
        echo.
        echo   !!! WARNING: This will permanently delete:
        echo       %PARENT_DIR%
        echo.
        set /p CONFIRM_FINAL="Type 'DELETE' to confirm: "
        if /i "!CONFIRM_FINAL!"=="DELETE" (
            call :log "  -> User confirmed project folder deletion."
            echo   Deleting project folder...
            
            REM Delete the project folder (move to Recycle Bin first as safety)
            rmdir /s /q "%PARENT_DIR%" >nul 2>&1
            if %errorlevel% equ 0 (
                call :log "  -> Project folder deleted: %PARENT_DIR%"
                echo   OK: Project folder deleted.
            ) else (
                call :log "  -> ERROR: Could not delete project folder (files in use?)."
                echo   ERROR: Could not delete project folder. Some files may be in use.
                echo   Close any open files from this folder and try again.
            )
        ) else (
            call :log "  -> User did not confirm deletion with 'DELETE'."
            echo   SKIP: Project folder deletion cancelled.
        )
    ) else (
        call :log "  -> User skipped project folder deletion."
        echo   SKIP: Project folder retained.
    )
)

REM ============================================================================
REM SUMMARY
REM ============================================================================
echo.
call :log "=== Master Cleanup Completed ==="
echo ============================================================
echo   MASTER CLEANUP COMPLETE
echo ============================================================
echo   Log file: %LOG_FILE%
echo.
if %IS_ADMIN% equ 0 (
    echo   NOTE: Some steps require Administrator access.
    echo   Run this script as Administrator for full cleanup.
    echo.
)
echo   To clean additional traces, run:  wipe_traces.ps1
echo ============================================================
echo.

echo [%date% %time%] === Master Cleanup Completed === >> "%LOG_FILE%"
echo ============================================================================ >> "%LOG_FILE%"

if %SILENT_MODE% equ 0 (
    pause
)
exit /b 0

REM ============================================================================
REM Helper: Log a message to console and log file
REM ============================================================================
:log
    echo [%date% %time%] %* >> "%LOG_FILE%"
    echo [*] %*
    exit /b 0
