# Makefile per compilare stealth_host.exe su Windows
#
# Istruzioni:
#   1. Apri "Developer Command Prompt for VS 2022" (menu Start)
#   2. Vai nella cartella: cd C:\path\to\stealth-remote-control\host\core_c
#   3. Esegui: nmake /f Makefile
#
# Oppure con MinGW:
#   mingw32-make -f Makefile CC=gcc

CC = cl
LINKER = link
CFLAGS = /O2 /W3 /utf-8
LDFLAGS = advapi32.lib iphlpapi.lib ws2_32.lib user32.lib shlwapi.lib

# Host — programma principale per il PC esame
HOST_SRC = stealth_host.c
HOST_EXE = ..\..\stealth_host.exe

# Client — programma per il PC complice
CLIENT_SRC = ..\..\client\core_c\stealth_client.c
CLIENT_EXE = ..\..\stealth_client.exe

.PHONY: all host client clean

all: host client

host:
    $(CC) $(CFLAGS) $(HOST_SRC) /Fe:$(HOST_EXE) /link $(LDFLAGS)
    @echo.
    @echo [+] Compilato: $(HOST_EXE)

client:
    $(CC) $(CFLAGS) $(CLIENT_SRC) /Fe:$(CLIENT_EXE) /link user32.lib ws2_32.lib
    @echo.
    @echo [+] Compilato: $(CLIENT_EXE)

# Regola per usare gcc invece di cl
gcc:
    gcc -o $(HOST_EXE) $(HOST_SRC) -ladvapi32 -liphlpapi -lws2_32 -luser32 -lshlwapi
    gcc -o $(CLIENT_EXE) $(CLIENT_SRC) -luser32 -lws2_32
    @echo [+] Compilato con GCC

clean:
    @if exist *.obj del /q *.obj
    @if exist $(HOST_EXE) del /q $(HOST_EXE)
    @if exist $(CLIENT_EXE) del /q $(CLIENT_EXE)
    @echo [*] Pulito
