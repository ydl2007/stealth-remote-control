@echo off
title Stealth Remote — Compile
chcp 437 >nul
setlocal enabledelayedexpansion

echo.
echo ======================================
echo   STEALTH REMOTE CONTROL - COMPILE
echo ======================================
echo.

set "SCRIPT_DIR=%~dp0"

:: Find MinGW gcc
set "GCC="

where gcc.exe >nul 2>&1
if !errorlevel! equ 0 (
    for /f "tokens=*" %%a in ('where gcc.exe') do set "GCC=%%a"
    goto :compile
)

for %%p in (
    "C:\mingw64\bin\gcc.exe"
    "C:\MinGW\bin\gcc.exe"
    "C:\msys64\ucrt64\bin\gcc.exe"
    "C:\tools\mingw64\bin\gcc.exe"
) do (
    if exist %%p set "GCC=%%~p"
)
if defined GCC goto :compile

echo [!] MinGW (gcc) not found.
echo.
echo Install MinGW:
echo   1. Download from: https://www.msys2.org/
echo   2. Run the installer (msys2-x86_64-*.exe)
echo   3. Open MSYS2 terminal and run:
echo      pacman -S mingw-w64-ucrt-x86_64-gcc
echo   4. Add to PATH:
echo      set PATH=C:\msys64\ucrt64\bin;%%PATH%%
echo.
echo Or compile manually:
echo   gcc -o stealth_host.exe host/core_c/stealth_host.c -ladvapi32 -liphlpapi -lws2_32 -luser32 -lshlwapi -O2 -s
echo   gcc -o stealth_client.exe client/core_c/stealth_client.c -luser32 -lws2_32 -O2 -s
echo.
pause
exit /b 1

:compile
echo [*] Compiler: %GCC%
echo.

set "GCC_DIR=%GCC%\.."
set "PATH=%GCC_DIR%;%PATH%"

echo [1/2] Compiling stealth_host.exe...
gcc -o "%SCRIPT_DIR%stealth_host.exe" "%SCRIPT_DIR%host\core_c\stealth_host.c" -ladvapi32 -liphlpapi -lws2_32 -luser32 -lshlwapi -O2 -s
if !errorlevel! neq 0 (
    echo [!] Failed to compile stealth_host.exe
    pause
    exit /b 1
)
echo [+] stealth_host.exe created

echo [2/2] Compiling stealth_client.exe...
gcc -o "%SCRIPT_DIR%stealth_client.exe" "%SCRIPT_DIR%client\core_c\stealth_client.c" -luser32 -lws2_32 -O2 -s
if !errorlevel! neq 0 (
    echo [!] Failed to compile stealth_client.exe
    pause
    exit /b 1
)
echo [+] stealth_client.exe created

echo.
echo ======================================
echo  COMPLETE! Files created:
echo    %SCRIPT_DIR%stealth_host.exe
echo    %SCRIPT_DIR%stealth_client.exe
echo ======================================
echo.
pause
