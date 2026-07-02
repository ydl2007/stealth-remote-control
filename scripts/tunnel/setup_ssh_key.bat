@echo off
REM ============================================================================
REM setup_ssh_key.bat — Generate SSH key pair for stealth RDP tunneling
REM
REM Checks for OpenSSH client, installs if missing, generates an Ed25519 key
REM pair, and prints the public key for copying to the VPS.
REM ============================================================================
setlocal enabledelayedexpansion

set KEY_DIR=%USERPROFILE%\.ssh
set KEY_FILE=%KEY_DIR%\stealth_remote
set LOG_FILE=%~dpn0.log

call :log "=== SSH Key Setup Started ==="

REM --------------------------------------------------------------------------
REM Step 1: Check / install OpenSSH Client
REM --------------------------------------------------------------------------
call :log "Checking for OpenSSH client..."
where ssh.exe >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    call :log "OpenSSH client is already installed."
) else (
    call :log "OpenSSH client NOT found. Installing via DISM..."
    echo.
    echo [*] OpenSSH client not detected. Installing...
    dism /online /Add-Capability /CapabilityName:OpenSSH.Client~~~~0.0.1.0
    if !ERRORLEVEL! NEQ 0 (
        call :log "ERROR: Failed to install OpenSSH client via DISM."
        echo [!] ERROR: Failed to install OpenSSH client.
        echo      Try installing manually from:
        echo      Settings ^> Apps ^> Optional Features ^> Add OpenSSH Client
        pause
        exit /b 1
    )
    call :log "OpenSSH client installed successfully."
    echo [*] OpenSSH client installed. You may need to restart your terminal.
)

REM --------------------------------------------------------------------------
REM Step 2: Ensure .ssh directory exists
REM --------------------------------------------------------------------------
if not exist "%KEY_DIR%" (
    mkdir "%KEY_DIR%"
    call :log "Created directory: %KEY_DIR%"
)

REM --------------------------------------------------------------------------
REM Step 3: Generate SSH key pair (Ed25519)
REM --------------------------------------------------------------------------
if exist "%KEY_FILE%" (
    call :log "Key file already exists: %KEY_FILE%"
    echo [*] SSH key already exists at:
    echo      %KEY_FILE%
    echo.
    echo      To overwrite, delete the file and re-run this script.
    echo      WARNING: Overwriting will break any existing tunnel connections!
) else (
    call :log "Generating Ed25519 key pair..."
    echo [*] Generating Ed25519 key pair (no passphrase)...
    REM 2>nul suppresses the "Generating public/private ed25519 key pair" prompt
    ssh-keygen -t ed25519 -f "%KEY_FILE%" -N "" 2>nul
    if !ERRORLEVEL! NEQ 0 (
        call :log "ERROR: ssh-keygen failed."
        echo [!] ERROR: Failed to generate SSH key.
        pause
        exit /b 1
    )
    call :log "Key pair generated successfully."
    echo [*] Key pair generated successfully!
)

echo.

REM --------------------------------------------------------------------------
REM Step 4: Display public key
REM --------------------------------------------------------------------------
if exist "%KEY_FILE%.pub" (
    echo ============================================================
    echo   PUBLIC KEY — Add this to your VPS' authorized_keys:
    echo ============================================================
    echo.
    type "%KEY_FILE%.pub"
    echo.
    echo ============================================================
    echo.
    call :log "Public key displayed."

    REM -----------------------------------------------------------------------
    REM Step 5: Copy public key to clipboard if possible
    REM -----------------------------------------------------------------------
    REM Try PowerShell clip.exe first, then fall back to clip
    type "%KEY_FILE%.pub" | clip 2>nul
    if !ERRORLEVEL! EQU 0 (
        echo [*] Public key copied to clipboard!
        echo      You can now paste it into your VPS' ~/.ssh/authorized_keys
        call :log "Public key copied to clipboard."
    ) else (
        echo [!] Could not automatically copy to clipboard.
        echo      Please manually select and copy the key above.
        call :log "Clipboard copy failed (non-fatal)."
    )
) else (
    call :log "ERROR: Public key file not found at %KEY_FILE%.pub"
    echo [!] ERROR: Public key file not found at:
    echo      %KEY_FILE%.pub
    echo      Something went wrong during generation.
)

echo.
echo ============================================================
echo   QUICK START for VPS setup:
echo ============================================================
echo.
echo   ssh tunneladmin@VPS_IP "mkdir -p ~/.ssh ^&^& chmod 700 ~/.ssh"
echo   ssh tunneladmin@VPS_IP "echo ^"^" ^>^> ~/.ssh/authorized_keys"
echo   ^(paste the key into the quotes and run again^)
echo.
echo   Or use PowerShell:
echo   type "%KEY_FILE%.pub" ^| ssh tunneladmin@VPS_IP "cat ^>^> ~/.ssh/authorized_keys"
echo.
echo   Then test:
echo   ssh -i "%KEY_FILE%" tunneladmin@VPS_IP -p 443
echo.
echo   Press any key to test the connection now, or close this window.
echo ============================================================
pause >nul 2>&1

REM Optional: prompt to test connection
set /p TEST_CONN=Test connection now? (y/N):
if /i "!TEST_CONN!"=="y" (
    set /p VPS_IP_ENTER=Enter VPS IP: 
    set /p SSH_USER_ENTER=Enter SSH username (default: tunneladmin): 
    if "!SSH_USER_ENTER!"=="" set SSH_USER_ENTER=tunneladmin
    ssh -i "%KEY_FILE%" !SSH_USER_ENTER!@!VPS_IP_ENTER! -p 443
)

call :log "=== SSH Key Setup Completed ==="
exit /b 0

REM --------------------------------------------------------------------------
REM Helper: Log a message to console and log file
REM --------------------------------------------------------------------------
:log
    echo [%date% %time%] %* >> "%LOG_FILE%"
    echo [*] %*
    exit /b 0
