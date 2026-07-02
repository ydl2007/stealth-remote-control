@echo off
REM ============================================================================
REM Script:  harden.bat
REM Purpose: Apply stealth hardening measures to reduce detection surface for
REM          the stealth remote control system.
REM
REM WARNING: This script modifies system settings. All changes are reversible
REM          by running unharden.bat. A state file is saved to:
REM            .omo\backup\harden_state_<timestamp>.reg
REM
REM Changes (all optional with prompts):
REM   1. Save original state (registry backup + state file)
REM   2. Stop telemetry/logging services (optional)
REM   3. Clear Windows Event Logs (optional, with strong warning)
REM   4. Set process priority to Low for our SSH/RDP components
REM   5. Set network profile to "Public" to disable network discovery
REM   6. Disable telemetry via registry (optional)
REM   7. Add Windows Firewall rule for port 3390 with non-suspicious name
REM
REM Reversal: Run unharden.bat to undo all changes.
REM
REM Requirements:
REM   - Must be run as Administrator
REM   - Windows 10 / Windows 11 (Pro or Enterprise)
REM   - preflight_save_state.bat should be run first for full backup
REM
REM Usage:
REM   harden.bat                (interactive — prompts for each step)
REM   harden.bat --yes          (non-interactive — applies all changes)
REM   harden.bat --dry-run      (show what would be done without doing it)
REM
REM (c) Stealth Remote Control Project
REM ============================================================================

setlocal enabledelayedexpansion

REM ---- Parse arguments ----
set "INTERACTIVE=1"
set "DRY_RUN=0"
if /i "%1"=="--yes" set "INTERACTIVE=0"
if /i "%1"=="-y" set "INTERACTIVE=0"
if /i "%1"=="--dry-run" set "DRY_RUN=1"
if /i "%1"=="--yes" set "ARG_CHECKED=1"
if /i "%1"=="-y" set "ARG_CHECKED=1"
if /i "%1"=="--dry-run" set "ARG_CHECKED=1"

REM ---- Admin Check (skip for dry-run) ----
if %DRY_RUN% equ 0 (
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
)

REM ---- Determine script directory ----
set "SCRIPT_DIR=%~dp0"
set "PROJECT_DIR=%SCRIPT_DIR%.."
set "BACKUP_DIR=%PROJECT_DIR%\.omo\backup"

REM ---- Generate timestamp ----
for /f "tokens=1-6 delims=/:., " %%a in ('wmic os get localdatetime ^| find "."') do (
    set "dt=%%a"
)
set "TIMESTAMP=%dt:~0,4%-%dt:~4,2%-%dt:~6,2%_%dt:~8,2%-%dt:~10,2%-%dt:~12,2%"

set "STATE_FILE=%BACKUP_DIR%\harden_state_%TIMESTAMP%.txt"

if %DRY_RUN% equ 1 (
    echo ============================================================
    echo  HARDEN — DRY RUN MODE
    echo  Showing what would be done without making changes.
    echo ============================================================
    echo.
    goto :dry_run_plan
)

echo ============================================================
echo  Stealth Hardening
echo  Date: %date%  Time: %time%
echo ============================================================
echo.
echo  WARNING: This script modifies system settings to improve
echo  stealth. All changes are reversible via unharden.bat.
echo.
if %INTERACTIVE% equ 1 (
    echo  You will be prompted before each change. Press Ctrl+C to abort.
    echo.
    pause
)
echo.

REM ---- Ensure backup directory exists ----
if not exist "%BACKUP_DIR%" (
    mkdir "%BACKUP_DIR%" >nul 2>&1
    if %errorlevel% neq 0 (
        echo ERROR: Could not create backup directory: %BACKUP_DIR%
        pause
        exit /b 1
    )
)
echo [INFO] Backup directory: %BACKUP_DIR%
echo.

REM ============================================================================
REM Step 1: Save original state
REM ============================================================================
echo ========================================================================
echo  Step 1/7: Saving original system state
echo ========================================================================
echo.

REM Save state file with initial values
echo # Stealth Harden State File > "%STATE_FILE%"
echo # Created: %date% %time% >> "%STATE_FILE%"
echo # Revert with: unharden.bat >> "%STATE_FILE%"
echo. >> "%STATE_FILE%"

REM Record Telemetry service state
sc query DiagTrack >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=2 delims=: " %%s in ('sc query DiagTrack ^| findstr "STATE"') do (
        echo DiagTrack=%%s >> "%STATE_FILE%"
    )
) else (
    echo DiagTrack=NOT_FOUND >> "%STATE_FILE%"
)

sc query dmwappushservice >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=2 delims=: " %%s in ('sc query dmwappushservice ^| findstr "STATE"') do (
        echo dmwappushservice=%%s >> "%STATE_FILE%"
    )
) else (
    echo dmwappushservice=NOT_FOUND >> "%STATE_FILE%"
)

sc query WSearch >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=2 delims=: " %%s in ('sc query WSearch ^| findstr "STATE"') do (
        echo WSearch=%%s >> "%STATE_FILE%"
    )
) else (
    echo WSearch=NOT_FOUND >> "%STATE_FILE%"
)

REM Record telemetry registry setting
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=3" %%v in ('reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry 2^>nul ^| findstr "REG_DWORD"') do (
        echo TelemetryAllow=%%v >> "%STATE_FILE%"
    )
) else (
    echo TelemetryAllow=NOT_SET >> "%STATE_FILE%"
)

REM Record network profile
set "NET_PROFILE="
for /f "tokens=2 delims={}" %%g in ('powershell -NoProfile -Command "& {Get-NetConnectionProfile | Select-Object -First 1 | ForEach-Object { $_.NetworkCategory }}" 2^>nul') do (
    set "NET_PROFILE=%%g"
)
if not defined NET_PROFILE (
    for /f "tokens=*" %%g in ('powershell -NoProfile -Command "& { (Get-NetConnectionProfile | Select-Object -First 1).NetworkCategory }" 2^>nul') do (
        set "NET_PROFILE=%%g"
    )
)
echo NetworkProfile=%NET_PROFILE% >> "%STATE_FILE%"

REM Record firewall rule presence
netsh advfirewall firewall show rule name="Windows Remote Desktop (SSH)" >nul 2>&1
if %errorlevel% equ 0 (
    echo FirewallRuleSSH=PRESENT >> "%STATE_FILE%"
) else (
    echo FirewallRuleSSH=ABSENT >> "%STATE_FILE%"
)

REM Record current event log sizes
echo. >> "%STATE_FILE%"
echo # Event log max sizes (KB) >> "%STATE_FILE%"
for %%l in (Application System Security) do (
    wevtutil gl "%%l" 2>nul | findstr /i "maxSize" >nul
    if !errorlevel! equ 0 (
        for /f "tokens=2" %%s in ('wevtutil gl "%%l" ^| findstr /i "maxSize"') do (
            echo EventLog_%%l_maxSize=%%s >> "%STATE_FILE%"
        )
    )
)

echo [OK] State saved to: %STATE_FILE%
echo.

REM Optional: Also save registry backup
set "REG_BACKUP=%BACKUP_DIR%\harden_reg_backup_%TIMESTAMP%.reg"
reg export "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" "%REG_BACKUP%" /y >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Registry backup: %REG_BACKUP%
) else (
    echo [INFO] Registry backup skipped (not critical for harden/unharden).
)
echo.

REM ============================================================================
REM Step 2: Stop telemetry/logging services (optional)
REM ============================================================================
:step2
echo ========================================================================
echo  Step 2/7: Stop telemetry/logging services
echo ========================================================================
echo.
echo  Services that may log connection activity:
echo    - DiagTrack  (Connected User Experiences and Telemetry)
echo    - dmwappushservice (WAP Push Message Routing)
echo    - WSearch    (Windows Search — indexes files)
echo.
echo  NOTE: Stopping DiagTrack/dmwappushservice affects telemetry data.
echo  Windows Update may be affected. These are OPTIONAL steps.
echo.

if %INTERACTIVE% equ 1 (
    set /p STOP_TELEMETRY="Stop telemetry services? (y/N): "
) else (
    set "STOP_TELEMETRY=y"
)

if /i "!STOP_TELEMETRY!"=="y" (
    call :stop_service "DiagTrack" "Connected User Experiences and Telemetry"
    call :stop_service "dmwappushservice" "WAP Push Message Routing"

    REM Optionally stop Windows Search
    if %INTERACTIVE% equ 1 (
        set /p STOP_SEARCH="Stop Windows Search service? (y/N): "
    ) else (
        set "STOP_SEARCH=n"
    )

    if /i "!STOP_SEARCH!"=="y" (
        call :stop_service "WSearch" "Windows Search"
    ) else (
        echo [SKIP] WSearch left running.
    )
) else (
    echo [SKIP] Telemetry services left unchanged.
)
echo.

REM ============================================================================
REM Step 3: Clear Event Logs (optional, with strong warning)
REM ============================================================================
:step3
echo ========================================================================
echo  Step 3/7: Clear Event Logs
echo ========================================================================
echo.
echo  WARNING: Clearing event logs is DETECTABLE. If a proctor checks
echo  event log continuity, gaps will indicate tampering.
echo.
echo  Only do this if you are sure the proctoring software does not
echo  audit event log continuity.
echo.

if %INTERACTIVE% equ 1 (
    set /p CLEAR_LOGS="Clear event logs anyway? (y/N): "
) else (
    set "CLEAR_LOGS=n"
)

if /i "!CLEAR_LOGS!"=="y" (
    echo [*] Clearing event logs...
    for %%l in (Application System Security) do (
        call :clear_log "%%l"
    )
    echo [OK] Event logs cleared.
) else (
    echo [SKIP] Event logs left intact.
)
echo.

REM ============================================================================
REM Step 4: Set process priority for our components
REM ============================================================================
:step4
echo ========================================================================
echo  Step 4/7: Set process priority for stealth components
echo ========================================================================
echo.
echo  Setting SSH and RDP components to BelowNormal priority to:
echo    - Avoid appearing in top CPU consumers
echo    - Reduce resource contention during exam
echo    - Blend in with background system processes
echo.

if %INTERACTIVE% equ 1 (
    set /p SET_PRIORITY="Set process priorities? (Y/n): "
) else (
    set "SET_PRIORITY=y"
)

if /i not "!SET_PRIORITY!"=="n" (
    echo [*] Setting ssh.exe priority to BelowNormal...
    powershell -NoProfile -Command "Get-Process -Name 'ssh' -ErrorAction SilentlyContinue | ForEach-Object { $_.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal }" >nul 2>&1
    if %errorlevel% equ 0 ( echo [OK] ssh.exe priority set ) else ( echo [INFO] ssh.exe not running — will be applied on next launch )

    echo [*] Setting mstsc.exe priority to BelowNormal...
    powershell -NoProfile -Command "Get-Process -Name 'mstsc' -ErrorAction SilentlyContinue | ForEach-Object { $_.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal }" >nul 2>&1
    if %errorlevel% equ 0 ( echo [OK] mstsc.exe priority set ) else ( echo [INFO] mstsc.exe not running — will be applied on next launch )

    REM Save priority setting to state file so unharden can revert
    echo ProcessPriority=BelowNormal >> "%STATE_FILE%"
    echo [OK] Priority changes recorded.
) else (
    echo [SKIP] Process priorities left unchanged.
)
echo.

REM ============================================================================
REM Step 5: Set network profile to "Public"
REM ============================================================================
:step5
echo ========================================================================
echo  Step 5/7: Set network profile to "Public"
echo ========================================================================
echo.
echo  Setting network profile to "Public" disables:
echo    - Network discovery
echo    - File and printer sharing
echo    - Automatic connection to suggested open hotspots
echo.
echo  This reduces broadcast visibility of our machine on the network.
echo  Does NOT affect SSH or RDP connectivity.
echo.

if %INTERACTIVE% equ 1 (
    set /p SET_PUBLIC="Set network profile to Public? (Y/n): "
) else (
    set "SET_PUBLIC=y"
)

if /i not "!SET_PUBLIC!"=="n" (
    echo [*] Setting network profile to Public...
    powershell -NoProfile -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Public" >nul 2>&1
    if %errorlevel% equ 0 (
        echo [OK] Network profile set to Public.
    ) else (
        echo [WARNING] Failed to set network profile. May already be Public.
    )
) else (
    echo [SKIP] Network profile left unchanged.
)
echo.

REM ============================================================================
REM Step 6: Disable telemetry (optional)
REM ============================================================================
:step6
echo ========================================================================
echo  Step 6/7: Disable telemetry via registry
echo ========================================================================
echo.
echo  Disabling telemetry reduces outbound connections to Microsoft servers
echo  that could be logged or inspected alongside our SSH tunnel traffic.
echo.
echo  NOTE: This is an OPTIONAL hardening step. Setting AllowTelemetry to 0
echo  may affect Windows Update and some Microsoft services.
echo.

if %INTERACTIVE% equ 1 (
    set /p DISABLE_TELEMETRY="Disable telemetry? (y/N): "
) else (
    set "DISABLE_TELEMETRY=n"
)

if /i "!DISABLE_TELEMETRY!"=="y" (
    echo [*] Setting AllowTelemetry to 0 (Security)...
    reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f >nul 2>&1
    if %errorlevel% equ 0 (
        echo [OK] Telemetry disabled (AllowTelemetry = 0).
        echo TelemetryDisabled=YES >> "%STATE_FILE%"
    ) else (
        echo [WARNING] Failed to set telemetry registry key.
    )
) else (
    echo [SKIP] Telemetry left unchanged.
)
echo.

REM ============================================================================
REM Step 7: Add firewall rule with non-suspicious name
REM ============================================================================
:step7
echo ========================================================================
echo  Step 7/7: Add Windows Firewall rule for port 3390
echo ========================================================================
echo.
echo  Adding firewall rule "Windows Remote Desktop (SSH)" for TCP port 3390.
echo  This name looks like a legitimate Windows rule to blend in.
echo  The existing "RDP-Stealth" rule from enable_rdp_stealth.bat is separate.
echo.

if %INTERACTIVE% equ 1 (
    set /p ADD_FW_RULE="Add firewall rule? (Y/n): "
) else (
    set "ADD_FW_RULE=y"
)

if /i not "!ADD_FW_RULE!"=="n" (
    REM Check if rule already exists
    netsh advfirewall firewall show rule name="Windows Remote Desktop (SSH)" >nul 2>&1
    if %errorlevel% equ 0 (
        echo [INFO] Rule already exists — skipping.
    ) else (
        netsh advfirewall firewall add rule name="Windows Remote Desktop (SSH)" dir=in action=allow protocol=TCP localport=3390 >nul 2>&1
        if %errorlevel% equ 0 (
            echo [OK] Firewall rule "Windows Remote Desktop (SSH)" added for TCP/3390.
        ) else (
            echo [WARNING] Failed to add firewall rule. May already exist.
        )
    )
) else (
    echo [SKIP] Firewall rule left unchanged.
)
echo.

REM ============================================================================
REM Summary
REM ============================================================================
:done
echo ============================================================
echo  Hardening Complete
echo ============================================================
echo  State file: %STATE_FILE%
echo.
if %DRY_RUN% equ 1 (
    echo  DRY RUN — no changes were made.
    echo  Run without --dry-run to apply changes.
) else (
    echo  All selected hardening measures applied.
    echo  To revert all changes, run: unharden.bat
)
echo ============================================================
echo.

if %INTERACTIVE% equ 1 (
    pause
)
exit /b 0

REM ============================================================================
REM Dry-run mode — show planned changes
REM ============================================================================
:dry_run_plan
echo.
echo  Planned changes:
echo.
echo  Step 1: Save original system state to .omo\backup\
echo  Step 2: [Optional] Stop telemetry services (DiagTrack, dmwappushservice)
echo  Step 3: [Optional] Clear event logs (Application, System, Security)
echo  Step 4: Set ssh.exe and mstsc.exe priority to BelowNormal
echo  Step 5: Set network profile to Public
echo  Step 6: [Optional] Disable telemetry via registry (AllowTelemetry = 0)
echo  Step 7: Add firewall rule "Windows Remote Desktop (SSH)" for TCP/3390
echo.
echo  All changes are reversible via unharden.bat
echo.
echo  Usage:
echo    harden.bat           Interactive mode (prompts for each step)
echo    harden.bat --yes     Non-interactive mode (applies all defaults)
echo    harden.bat --dry-run Show plan without making changes
echo.
pause
exit /b 0

REM ============================================================================
REM Helper: Stop a service
REM ============================================================================
:stop_service
    set "SVC_NAME=%~1"
    set "SVC_DISPLAY=%~2"

    REM Check if service exists
    sc query "%SVC_NAME%" >nul 2>&1
    if %errorlevel% neq 0 (
        echo [INFO] Service '%SVC_DISPLAY%' (%SVC_NAME%) not found — skipping.
        exit /b 0
    )

    REM Check if already stopped
    for /f "tokens=2 delims=: " %%s in ('sc query "%SVC_NAME%" ^| findstr "STATE"') do (
        set "SVC_STATE=%%s"
    )
    if "!SVC_STATE!"=="STOPPED" (
        echo [INFO] %SVC_DISPLAY% already stopped.
        exit /b 0
    )

    REM Stop the service
    if %DRY_RUN% equ 1 (
        echo [DRY-RUN] Would stop: %SVC_DISPLAY% (%SVC_NAME%)
        exit /b 0
    )

    echo [*] Stopping %SVC_DISPLAY% (%SVC_NAME%)...
    net stop "%SVC_NAME%" >nul 2>&1
    if %errorlevel% equ 0 (
        echo [OK] %SVC_DISPLAY% stopped.
    ) else (
        echo [WARNING] Failed to stop %SVC_DISPLAY%.
    )
    exit /b 0

REM ============================================================================
REM Helper: Clear an event log
REM ============================================================================
:clear_log
    set "LOG_NAME=%~1"
    if %DRY_RUN% equ 1 (
        echo [DRY-RUN] Would clear: %LOG_NAME% log
        exit /b 0
    )
    echo [*] Clearing %LOG_NAME% log...
    wevtutil cl "%LOG_NAME%" >nul 2>&1
    if %errorlevel% equ 0 (
        echo [OK] %LOG_NAME% log cleared.
    ) else (
        echo [WARNING] Failed to clear %LOG_NAME% log.
    )
    exit /b 0
