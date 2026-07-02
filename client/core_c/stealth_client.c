/**
 * stealth_client.c — Programma per il PC del complice.
 * 
 * Si connette al PC esame (direttamente o via tunnel SSH)
 * e apre mstsc.exe con la configurazione corretta.
 * 
 * Compilazione (Windows):
 *   cl /Fe:stealth_client.exe stealth_client.c /link user32.lib
 *   gcc -o stealth_client.exe stealth_client.c -luser32
 * 
 * Uso:
 *   stealth_client.exe <IP> [porta]
 *   stealth_client.exe /v:127.0.0.1:3390   -> connessione via tunnel/loopback
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void info(const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    printf("[*] %s\n", buf);
}

static void ok(const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    printf("[+] %s\n", buf);
}

static void fail(const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    printf("[ERR] %s\n", buf);
}

/**
 * Avvia mstsc.exe connesso a IP:porta.
 * Se la connessione fallisce (porta chiusa), lo dice.
 */
static int launch_mstsc(const char *ip, int port) {
    wchar_t cmd[MAX_PATH];
    char addr[64];
    
    if (port == 3389) {
        snprintf(addr, sizeof(addr), "%s", ip);
    } else {
        snprintf(addr, sizeof(addr), "%s:%d", ip, port);
    }
    
    info("Connessione a: %s", addr);
    
    // Converti in wide char per ShellExecute
    wchar_t waddr[64];
    mbstowcs(waddr, addr, 64);
    
    // Lancia mstsc.exe
    SHELLEXECUTEINFOW sei = {0};
    sei.cbSize = sizeof(sei);
    sei.lpVerb = L"open";
    sei.lpFile = L"mstsc.exe";
    sei.lpParameters = waddr;
    sei.nShow = SW_SHOWNORMAL;
    
    if (ShellExecuteExW(&sei)) {
        ok("mstsc.exe avviato correttamente");
        return 0;
    } else {
        DWORD err = GetLastError();
        fail("Impossibile avviare mstsc.exe (errore: %lu)", err);
        fail("Assicurati che RDP sia installato (Windows Pro).");
        return -1;
    }
}

/**
 * Testa se la porta è raggiungibile (connessione TCP veloce).
 */
static int test_port(const char *ip, int port) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        return -1;
    }
    
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) {
        WSACleanup();
        return -1;
    }
    
    // Timeout 3 secondi
    u_long mode = 1;  // non-blocking
    ioctlsocket(s, FIONBIO, &mode);
    
    struct sockaddr_in sa;
    sa.sin_family = AF_INET;
    sa.sin_port = htons(port);
    sa.sin_addr.s_addr = inet_addr(ip);
    
    connect(s, (struct sockaddr*)&sa, sizeof(sa));
    
    fd_set fd;
    FD_ZERO(&fd);
    FD_SET(s, &fd);
    struct timeval tv = {3, 0};  // 3 secondi timeout
    
    int ret = select(0, NULL, &fd, NULL, &tv);
    
    closesocket(s);
    WSACleanup();
    
    return (ret > 0) ? 0 : -1;
}

int main(int argc, char *argv[]) {
    printf("\n");
    printf("╔══════════════════════════════════════════╗\n");
    printf("║      STEALTH REMOTE — CLIENT             ║\n");
    printf("╚══════════════════════════════════════════╝\n");
    printf("\n");
    
    char ip[64] = "127.0.0.1";
    int port = 3390;
    
    // Parsing argomenti
    if (argc > 1) {
        // Supporta /v:IP:PORTA (stile mstsc) e IP PORT
        if (strncmp(argv[1], "/v:", 3) == 0) {
            // Formato: /v:192.168.1.5:3390
            char *addr = argv[1] + 3;
            char *colon = strrchr(addr, ':');
            if (colon) {
                *colon = '\0';
                strncpy(ip, addr, sizeof(ip) - 1);
                port = atoi(colon + 1);
            } else {
                strncpy(ip, addr, sizeof(ip) - 1);
            }
        } else {
            strncpy(ip, argv[1], sizeof(ip) - 1);
            if (argc > 2) {
                port = atoi(argv[2]);
            }
        }
    }
    
    // Test connessione
    info("Test connessione a %s:%d...", ip, port);
    
    if (test_port(ip, port) == 0) {
        ok("Porta %d raggiungibile su %s", port, ip);
    } else {
        fail("Impossibile raggiungere %s:%d", ip, port);
        fail("Possibili cause:");
        fail("  1. Il PC esame non è ancora pronto");
        fail("  2. Il tunnel SSH non è attivo");
        fail("  3. Firewall blocca la connessione");
        fail("  4. IP/porta sbagliati");
        printf("\n  Tentativo di connessione...\n");
    }
    
    // Avvia mstsc
    launch_mstsc(ip, port);
    
    printf("\n  Premi INVIO per uscire...\n");
    getchar();
    
    return 0;
}
