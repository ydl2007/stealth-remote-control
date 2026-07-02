@echo off
title Stealth Remote — Compilazione MinGW
chcp 65001 >nul
setlocal enabledelayedexpansion

echo.
echo ╔══════════════════════════════════════════╗
echo ║   COMPILAZIONE STEALTH REMOTE CONTROL    ║
echo ║   (senza Visual Studio — con MinGW)      ║
echo ╚══════════════════════════════════════════╝
echo.

:: Trova la cartella dello script
set "SCRIPT_DIR=%~dp0"

:: Cerca MinGW
set "MINGW_DIR="
set "MINGW_GCC="

:: 1. Cerca nel PATH
where gcc >nul 2>&1
if !errorlevel! equ 0 (
    for /f "tokens=*" %%a in ('where gcc') do set "MINGW_GCC=%%a"
    echo [*] Trovato gcc in PATH: !MINGW_GCC!
    goto :compile
)

:: 2. Cerca in cartelle comuni
for %%p in (
    "C:\mingw64\bin\gcc.exe"
    "C:\MinGW\bin\gcc.exe"
    "C:\tools\mingw64\bin\gcc.exe"
    "C:\Program Files\mingw-w64\x86_64-8.1.0-posix-seh-rt_v6-rev0\mingw64\bin\gcc.exe"
    "%USERPROFILE%\scoop\apps\mingw\current\bin\gcc.exe"
) do (
    if exist %%p (
        set "MINGW_GCC=%%~p"
        echo [*] Trovato MinGW: !MINGW_GCC!
        set "MINGW_DIR=%%~dp\.."
        goto :compile
    )
)

:: 3. Non trovato — chiedi se scaricarlo
echo [!] MinGW non trovato sul sistema.
echo.
echo  MinGW-w64 è un compilatore C gratuito e leggero (~100MB).
echo  Vuoi scaricarlo e installarlo automaticamente?
echo.
set "SCARICA="
set /p "SCARICA=  Digita 's' per scaricare, qualsiasi altro tasto per uscire: "

if /i "!SCARICA!"=="s" goto :download_mingw
echo [!] Compilazione annullata.
pause
exit /b 1

:download_mingw
echo.
echo [*] Scaricamento MinGW-w64 in corso...
echo.

:: Usa la versione portatile (nessuna installazione, si scompatta e via)
set "MINGW_ZIP=%TEMP%\mingw64.zip"
set "MINGW_DIR=%SCRIPT_DIR%mingw64"

:: Download dalla source ufficiale (build x86_64, UCRT, POSIX, seh)
:: Usa curl (presente su Win10/11) o PowerShell come fallback
where curl >nul 2>&1
if !errorlevel! equ 0 (
    curl -L -o "%MINGW_ZIP%" "https://github.com/niXman/mingw-builds-binaries/releases/download/14.2.0-rt_v12-rev4/x86_64-14.2.0-release-posix-seh-ucrt-rt_v12-rev4.7z" --progress-bar
) else (
    powershell -Command "& {Invoke-WebRequest -Uri 'https://github.com/niXman/mingw-builds-binaries/releases/download/14.2.0-rt_v12-rev4/x86_64-14.2.0-release-posix-seh-ucrt-rt_v12-rev4.7z' -OutFile '%MINGW_ZIP%'}"
)

if not exist "%MINGW_ZIP%" (
    echo [!] Download fallito. Scarica manualmente da:
    echo  https://github.com/niXman/mingw-builds-binaries/releases
    echo  (cerca x86_64-*-posix-seh-ucrt*.7z)
    pause
    exit /b 1
)

echo [*] Estrazione in corso...
:: Usa 7-Zip se presente, altrimenti PowerShell
where 7z >nul 2>&1
if !errorlevel! equ 0 (
    7z x "%MINGW_ZIP%" -o"%MINGW_DIR%" -y >nul
) else (
    powershell -Command "& {Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory('%MINGW_ZIP%', '%MINGW_DIR%')}" >nul 2>&1
    :: Se fallisce (7z non zip), usa tar
    if not exist "%MINGW_DIR%\mingw64\bin\gcc.exe" (
        tar -xf "%MINGW_ZIP%" -C "%MINGW_DIR%" >nul 2>&1
    )
)

:: Trova il gcc dopo l'estrazione
set "MINGW_GCC="
for /r "%MINGW_DIR%" %%f in (gcc.exe) do (
    if exist "%%f" set "MINGW_GCC=%%f"
)

if not defined MINGW_GCC (
    echo [!] Estrazione fallita. Scarica MinGW manualmente e riprova.
    pause
    exit /b 1
)

set "MINGW_DIR=%MINGW_GCC%\..\.."
echo [*] MinGW estratto: %MINGW_GCC%

:compile
echo.
echo [*] Compilazione in corso...
echo.

:: Imposta PATH per MinGW
set "OLD_PATH=%PATH%"
if defined MINGW_DIR set "PATH=%MINGW_DIR%\bin;%PATH%"

:: Compila host
echo [1/2] Compilazione stealth_host.exe...
gcc -o "%SCRIPT_DIR%stealth_host.exe" "%SCRIPT_DIR%host\core_c\stealth_host.c" -ladvapi32 -liphlpapi -lws2_32 -luser32 -lshlwapi -O2 -s
if !errorlevel! neq 0 (
    echo [!] Errore compilazione stealth_host.exe
    pause
    goto :end
)
echo [+] stealth_host.exe creato

:: Compila client
echo [2/2] Compilazione stealth_client.exe...
gcc -o "%SCRIPT_DIR%stealth_client.exe" "%SCRIPT_DIR%client\core_c\stealth_client.c" -luser32 -lws2_32 -O2 -s
if !errorlevel! neq 0 (
    echo [!] Errore compilazione stealth_client.exe
    pause
    goto :end
)
echo [+] stealth_client.exe creato

echo.
echo ╔══════════════════════════════════════════╗
echo ║   COMPILAZIONE COMPLETATA!               ║
echo ╠══════════════════════════════════════════╣
echo ║   Trovi i file .exe qui:                 ║
echo ║     %SCRIPT_DIR%stealth_host.exe         ║
echo ║     %SCRIPT_DIR%stealth_client.exe       ║
echo ╚══════════════════════════════════════════╝
echo.
echo  Hai solo bisogno di questi due .exe.
echo  Il resto (file .c, .bat, cartelle) puoi cancellarlo.
echo.

:end
set "PATH=%OLD_PATH%"
pause
