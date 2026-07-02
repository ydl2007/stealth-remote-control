@echo off
title Test RDP Config — Stealth Remote
chcp 65001 >nul
setlocal enabledelayedexpansion

set "PASS=0"
set "FAIL=0"

echo.
echo ╔══════════════════════════════════════════╗
echo ║     TEST RDP CONFIG — STEALTH REMOTE     ║
echo ╚══════════════════════════════════════════╝
echo.

:: Check admin
net session >nul 2>&1
if !errorlevel! neq 0 (
    echo [!] DEVI ESEGUIRE COME AMMINISTRATORE
    echo     Tasto destro sul file ^> "Esegui come amministratore"
    pause
    exit /b 1
)

set "SCRIPT_DIR=%~dp0..\scripts"

:: ===================== TEST 1 =====================
echo ── test 1: Backup stato ──
echo.

call "%SCRIPT_DIR%\preflight_save_state.bat"
if exist "%TEMP%\src_backup\rdp_backup.reg" (
    set /a "PASS+=1"
    echo   ✓ Backup registro presente
) else (
    set /a "FAIL+=1"
    echo   ✗ Backup registro non trovato
)

:: ===================== TEST 2 =====================
echo.
echo ── test 2: Abilita RDP ──
echo.

call "%SCRIPT_DIR%\enable_rdp_stealth.bat"

:: Verifica registro
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections 2>nul | findstr "0x0" >nul
if !errorlevel! equ 0 (
    set /a "PASS+=1"
    echo   ✓ RDP abilitato nel registro
) else (
    set /a "FAIL+=1"
    echo   ✗ RDP non abilitato nel registro
)

:: Verifica porta
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber 2>nul | findstr "0xd3e" >nul
if !errorlevel! equ 0 (
    set /a "PASS+=1"
    echo   ✓ Porta RDP = 3390
) else (
    set /a "FAIL+=1"
    echo   ✗ Porta RDP non è 3390
)

:: Verifica firewall
netsh advfirewall firewall show rule name="Windows Remote Desktop Services" >nul 2>&1
if !errorlevel! equ 0 (
    set /a "PASS+=1"
    echo   ✓ Regola firewall presente
) else (
    set /a "FAIL+=1"
    echo   ✗ Regola firewall assente
)

:: Verifica servizio
sc query TermService | findstr "RUNNING" >nul
if !errorlevel! equ 0 (
    set /a "PASS+=1"
    echo   ✓ Terminal Services in esecuzione
) else (
    set /a "FAIL+=1"
    echo   ✗ Terminal Services non in esecuzione
)

:: ===================== TEST 3 =====================
echo.
echo ── test 3: Verifica port forwarding ──
echo.

netstat -ano | findstr ":3390 " >nul 2>&1
if !errorlevel! equ 0 (
    set /a "PASS+=1"
    echo   ✓ Porta 3390 in ascolto
) else (
    set /a "FAIL+=1"
    echo   ✗ Porta 3390 non in ascolto
)

:: ===================== TEST 4 =====================
echo.
echo ── test 4: Disabilita e ripristina ──
echo.

call "%SCRIPT_DIR%\disable_rdp_stealth.bat"

:: Verifica RDP disabilitato
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections 2>nul | findstr "0x1" >nul
if !errorlevel! equ 0 (
    set /a "PASS+=1"
    echo   ✓ RDP disabilitato dopo cleanup
) else (
    set /a "FAIL+=1"
    echo   ✗ RDP ancora abilitato dopo cleanup
)

:: Verifica porta tornata a 3389
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber 2>nul | findstr "0xd3d" >nul
if !errorlevel! equ 0 (
    set /a "PASS+=1"
    echo   ✓ Porta tornata a 3389
) else (
    set /a "FAIL+=1"
    echo   ✗ Porta non tornata a 3389
)

:: Verifica firewall rimosso
netsh advfirewall firewall show rule name="Windows Remote Desktop Services" >nul 2>&1
if !errorlevel! neq 0 (
    set /a "PASS+=1"
    echo   ✓ Regola firewall rimossa
) else (
    set /a "FAIL+=1"
    echo   ✗ Regola firewall ancora presente
)

:: ===================== REPORT =====================
echo.
echo ────────────────────────────────────────
echo   ✅ Passati: %PASS%    ❌ Falliti: %FAIL%
echo   Totale: %PASS% + %FAIL%
echo ────────────────────────────────────────
echo.

if %FAIL% gtr 0 (
    echo [!] Alcuni test sono falliti. Verifica i dettagli sopra.
) else (
    echo [+] Tutti i test superati!
)

echo.
echo  Premi un tasto per uscire...
pause >nul
exit /b
