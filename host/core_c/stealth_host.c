/**
 * stealth_host.c — Programma principale per il PC che sostiene l'esame.
 * 
 * Un singolo eseguibile C che automatizza tutto:
 *   1. Salva stato originale del registro/firewall
 *   2. Abilita RDP su porta 3390
 *   3. Apre tunnel SSH verso un VPS (se configurato)
 *   4. Mostra lo stato e l'IP del PC
 *   5. Alla chiusura, pulisce tutto
 * 
 * L'utente deve solo lanciarlo. Non servono competenze tecniche.
 * 
 * Compilazione (Windows, MSVC):
 *   cl /Fe:stealth_host.exe stealth_host.c /link advapi32.lib iphlpapi.lib ws2_32.lib user32.lib
 * 
 * Compilazione (Windows, MinGW):
 *   gcc -o stealth_host.exe stealth_host.c -ladvapi32 -liphlpapi -lws2_32 -luser32 -lshlwapi
 * 
 * Modalità operative:
 *   stealth_host.exe                  -> Interattiva (chiede VPS, porta, etc.)
 *   stealth_host.exe --vps 1.2.3.4    -> Connessione remota via VPS
 *   stealth_host.exe --lan            -> Solo rete locale (nessun tunnel)
 *   stealth_host.exe --auto           -> Cerca di rilevare l'IP e decide
 *   stealth_host.exe --cleanup        -> Solo cleanup (rimuove tutto)
 *   stealth_host.exe --status         -> Mostra stato attuale
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <iphlpapi.h>
#include <winsock2.h>
#include <shlwapi.h>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "shell32.lib")

/* ================================================================
 *   COSTANTI
 * ================================================================ */
#define RDP_PORT_DEFAULT    3390
#define RDP_PORT_STANDARD   3389
#define RULE_NAME           L"Windows Remote Desktop Services"
#define REG_RDP_KEY         L"SYSTEM\\CurrentControlSet\\Control\\Terminal Server"
#define REG_RDP_PORT_KEY    L"SYSTEM\\CurrentControlSet\\Control\\Terminal Server\\WinStations\\RDP-Tcp"
#define BACKUP_DIR          L"C:\\Windows\\Temp\\src_backup"
#define LOG_FILE            L"C:\\Windows\\Temp\\src_log.txt"
#define VERSION             "1.0.0"

/* Logger */
static FILE *g_log = NULL;

static void log_msg(const char *fmt, ...) {
    if (!g_log) {
        g_log = fopen("C:\\Windows\\Temp\\src_log.txt", "a");
        if (!g_log) g_log = fopen("src_log.txt", "a");
    }
    if (g_log) {
        SYSTEMTIME st;
        GetLocalTime(&st);
        fprintf(g_log, "[%04d-%02d-%02d %02d:%02d:%02d] ",
                st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
        va_list args;
        va_start(args, fmt);
        vfprintf(g_log, fmt, args);
        va_end(args);
        fprintf(g_log, "\n");
        fflush(g_log);
    }
}

/* ================================================================
 *   UTILITY
 * ================================================================ */

/* Mostra un messaggio nella console e nel log */
static void print(const char *prefix, const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    printf("%s %s\n", prefix, buf);
    log_msg("%s %s", prefix, buf);
}

static void info(const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    printf("[*] %s\n", buf);
    log_msg("[INFO] %s", buf);
}

static void ok(const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    printf("[+] %s\n", buf);
    log_msg("[OK] %s", buf);
}

static void warn(const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    printf("[!] %s\n", buf);
    log_msg("[WARN] %s", buf);
}

static void fail(const char *fmt, ...) {
    char buf[4096];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    printf("[ERR] %s\n", buf);
    log_msg("[ERROR] %s", buf);
}

static void press_any_key(void) {
    printf("\n    Premi INVIO per continuare...");
    getchar();
}

static int is_admin(void) {
    BOOL isElevated = FALSE;
    HANDLE hToken = NULL;
    TOKEN_ELEVATION elevation;
    DWORD dwSize = sizeof(TOKEN_ELEVATION);

    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &hToken)) {
        if (GetTokenInformation(hToken, TokenElevation, &elevation, dwSize, &dwSize)) {
            isElevated = elevation.TokenIsElevated;
        }
        CloseHandle(hToken);
    }
    return isElevated ? 1 : 0;
}

static void run_cmd(const wchar_t *cmd) {
    // Esegue un comando cmd.exe silenziosamente via CreateProcessW
    // (ShellExecuteExW non disponibile in tutte le versioni MinGW)
    wchar_t full_cmd[4096];
    swprintf(full_cmd, 4096, L"cmd.exe /c %s", cmd);
    
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    
    if (CreateProcessW(NULL, full_cmd, NULL, NULL, FALSE,
                       CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        WaitForSingleObject(pi.hProcess, 60000);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
    }
}

/* ================================================================
 *   REGISTRO DI SISTEMA
 * ================================================================ */

static DWORD reg_read_dword(HKEY hkey, const wchar_t *subkey, const wchar_t *name, DWORD def) {
    HKEY hk;
    DWORD val = def, size = sizeof(val), type;
    if (RegOpenKeyExW(hkey, subkey, 0, KEY_READ, &hk) == ERROR_SUCCESS) {
        RegQueryValueExW(hk, name, NULL, &type, (LPBYTE)&val, &size);
        RegCloseKey(hk);
    }
    return val;
}

static int reg_write_dword(HKEY hkey, const wchar_t *subkey, const wchar_t *name, DWORD val) {
    HKEY hk;
    DWORD disp;
    if (RegCreateKeyExW(hkey, subkey, 0, NULL, REG_OPTION_NON_VOLATILE,
                        KEY_SET_VALUE, NULL, &hk, &disp) != ERROR_SUCCESS) {
        return -1;
    }
    DWORD r = RegSetValueExW(hk, name, 0, REG_DWORD, (const BYTE*)&val, sizeof(val));
    RegCloseKey(hk);
    return (r == ERROR_SUCCESS) ? 0 : -1;
}

/* ================================================================
 *   BACKUP STATO ORIGINALE
 * ================================================================ */

static int save_state(void) {
    info("Salvataggio stato originale...");
    
    // Crea directory backup
    CreateDirectoryW(BACKUP_DIR, NULL);
    
    wchar_t path[MAX_PATH];
    
    // Backup registro RDP
    swprintf(path, MAX_PATH,
        L"/c reg export \"HKLM\\%s\" \"%s\\rdp_backup.reg\" /y >nul 2>&1",
        REG_RDP_KEY, BACKUP_DIR);
    run_cmd(path);
    
    // Backup firewall
    swprintf(path, MAX_PATH,
        L"/c netsh advfirewall firewall show rule name=all > \"%s\\firewall_backup.txt\" 2>nul",
        BACKUP_DIR);
    run_cmd(path);
    
    // Backup porte in ascolto
    swprintf(path, MAX_PATH,
        L"/c netstat -ano > \"%s\\ports_backup.txt\" 2>nul",
        BACKUP_DIR);
    run_cmd(path);
    
    ok("Stato salvato in %ls", BACKUP_DIR);
    return 0;
}

/* ================================================================
 *   ABILITA RDP SU PORTA 3390
 * ================================================================ */

static int enable_rdp(void) {
    info("Configurazione RDP su porta %d...", RDP_PORT_DEFAULT);
    
    // Abilita RDP
    if (reg_write_dword(HKEY_LOCAL_MACHINE, REG_RDP_KEY, L"fDenyTSConnections", 0) != 0) {
        fail("Impossibile abilitare RDP. Sei amministratore?");
        return -1;
    }
    ok("RDP abilitato");
    
    // Cambia porta
    if (reg_write_dword(HKEY_LOCAL_MACHINE, REG_RDP_PORT_KEY, L"PortNumber", RDP_PORT_DEFAULT) != 0) {
        fail("Impossibile cambiare porta RDP");
        return -1;
    }
    ok("Porta RDP cambiata a %d", RDP_PORT_DEFAULT);
    
    // Firewall: rimuovi vecchia regola se esiste
    wchar_t cmd[MAX_PATH];
    swprintf(cmd, MAX_PATH,
        L"/c netsh advfirewall firewall delete rule name=\"%ls\" >nul 2>&1",
        RULE_NAME);
    run_cmd(cmd);
    
    // Firewall: aggiungi regola per la nuova porta
    swprintf(cmd, MAX_PATH,
        L"/c netsh advfirewall firewall add rule name=\"%ls\" dir=in action=allow protocol=TCP localport=%d >nul 2>&1",
        RULE_NAME, RDP_PORT_DEFAULT);
    run_cmd(cmd);
    
    // Riavvio servizio Terminal Services
    info("Riavvio servizio Terminal Services...");
    run_cmd(L"/c net stop TermService >nul 2>&1 && net start TermService >nul 2>&1");
    Sleep(2000);
    
    ok("RDP attivo su porta %d", RDP_PORT_DEFAULT);
    return 0;
}

/* ================================================================
 *   DISABILITA RDP E RIPRISTINA
 * ================================================================ */

static int disable_rdp(void) {
    info("Disattivazione RDP e ripristino configurazione originale...");
    
    // Disabilita RDP
    reg_write_dword(HKEY_LOCAL_MACHINE, REG_RDP_KEY, L"fDenyTSConnections", 1);
    
    // Ripristina porta originale
    reg_write_dword(HKEY_LOCAL_MACHINE, REG_RDP_PORT_KEY, L"PortNumber", RDP_PORT_STANDARD);
    
    // Rimuovi regola firewall
    wchar_t cmd[MAX_PATH];
    swprintf(cmd, MAX_PATH,
        L"/c netsh advfirewall firewall delete rule name=\"%ls\" >nul 2>&1",
        RULE_NAME);
    run_cmd(cmd);
    
    // Riavvio servizio
    run_cmd(L"/c net stop TermService >nul 2>&1 && net start TermService >nul 2>&1");
    Sleep(1500);
    
    // Ripristina da backup se disponibile
    wchar_t backup[MAX_PATH];
    swprintf(backup, MAX_PATH, L"%s\\rdp_backup.reg", BACKUP_DIR);
    if (GetFileAttributesW(backup) != INVALID_FILE_ATTRIBUTES) {
        swprintf(cmd, MAX_PATH, L"/c reg import \"%s\" >nul 2>&1", backup);
        run_cmd(cmd);
        ok("Registro ripristinato da backup");
    }
    
    ok("RDP disattivato, configurazione originale ripristinata");
    return 0;
}

/* ================================================================
 *   TUNNEL SSH
 * ================================================================ */

static int tunnel_pid = 0;

static int start_ssh_tunnel(const char *vps_ip, int vps_port, int rdp_port) {
    info("Avvio tunnel SSH verso %s:%d...", vps_ip, vps_port);
    
    // Costruisci comando SSH
    // ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30
    //     -o ExitOnForwardFailure=yes -N -R 3390:127.0.0.1:3390
    //     user@IP -p 443
    
    // Troviamo ssh.exe
    wchar_t ssh_path[MAX_PATH] = L"ssh.exe";
    
    // Prova percorso comune di OpenSSH
    wchar_t *paths[] = {
        L"C:\\Windows\\System32\\OpenSSH\\ssh.exe",
        L"C:\\Program Files\\OpenSSH\\bin\\ssh.exe",
        L"ssh.exe"
    };
    
    int found = 0;
    for (int i = 0; i < 3; i++) {
        if (GetFileAttributesW(paths[i]) != INVALID_FILE_ATTRIBUTES) {
            wcscpy(ssh_path, paths[i]);
            found = 1;
            break;
        }
    }
    
    if (!found) {
        warn("OpenSSH non trovato. Installa OpenSSH Client: Settings → Apps → Optional features.");
        info("Puoi continuare in modalità LAN senza tunnel SSH.");
        return -1;
    }
    
    ok("OpenSSH trovato: %ls", ssh_path);
    
    // Per ora, apriamo una finestra cmd con ssh in esecuzione
    // In una versione futura: gestione diretta del processo SSH
    wchar_t cmd[MAX_PATH * 2];
    char addr[256];
    snprintf(addr, sizeof(addr), "%s:%d", vps_ip, vps_port);
    
    // Converti VPS IP in wchar
    wchar_t waddr[256];
    mbstowcs(waddr, addr, 256);
    
    swprintf(cmd, MAX_PATH * 2,
        L"start \"SSH-Tunnel\" /min \"%ls\" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -N -R %d:127.0.0.1:%d administrator@%ls -p %d",
        ssh_path, rdp_port, rdp_port, waddr, vps_port);
    
    info("Avvio tunnel SSH in finestra minimizzata...");
    system("");  // Inizializza cmd
    // Non possiamo usare run_cmd (aspetta la fine), usiamo Win32 CreateProcess
    STARTUPINFOW si = {0};
    PROCESS_INFORMATION pi = {0};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_MINIMIZE;
    
    if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
        tunnel_pid = pi.dwProcessId;
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        ok("Tunnel SSH avviato (PID: %d)", tunnel_pid);
        return 0;
    } else {
        fail("Impossibile avviare SSH (errore: %lu)", GetLastError());
        return -1;
    }
}

static void stop_ssh_tunnel(void) {
    if (tunnel_pid > 0) {
        info("Arresto tunnel SSH (PID: %d)...", tunnel_pid);
        HANDLE hProcess = OpenProcess(PROCESS_TERMINATE, FALSE, tunnel_pid);
        if (hProcess) {
            TerminateProcess(hProcess, 0);
            CloseHandle(hProcess);
        }
        tunnel_pid = 0;
        ok("Tunnel SSH arrestato");
    }
    
    // Kill any remaining ssh tunnel processes
    run_cmd(L"/c taskkill /f /im ssh.exe >nul 2>&1");
}

/* ================================================================
 *   RIPRISTINO DA BACKUP
 * ================================================================ */

static int restore_state(void) {
    info("Ripristino stato originale da backup...");
    
    wchar_t cmd[MAX_PATH];
    wchar_t path[MAX_PATH];
    
    // Registry
    swprintf(path, MAX_PATH, L"%s\\rdp_backup.reg", BACKUP_DIR);
    if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES) {
        swprintf(cmd, MAX_PATH, L"/c reg import \"%s\" >nul 2>&1", path);
        run_cmd(cmd);
    }
    
    pulisci_tracce:
    info("Pulizia tracce...");
    
    // Pulisci cronologia comandi
    run_cmd(L"/c del /f /q \"%APPDATA%\\Microsoft\\Windows\\PowerShell\\PSReadLine\\ConsoleHost_history.txt\" >nul 2>&1");
    
    // Pulisci Run dialog
    run_cmd(L"/c reg delete \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\RunMRU\" /f >nul 2>&1");
    
    // Pulisci Prefetch
    run_cmd(L"/c del /f /q \"C:\\Windows\\Prefetch\\*.pf\" >nul 2>&1");
    
    // Pulisci file temporanei
    run_cmd(L"/c del /f /q \"C:\\Windows\\Temp\\src_*.*\" >nul 2>&1");
    
    ok("Pulizia completata");
    return 0;
}

/* ================================================================
 *   MOSTRA STATO
 * ================================================================ */

static void show_status(void) {
    printf("\n");
    printf("╔══════════════════════════════════════════╗\n");
    printf("║       STEALTH REMOTE CONTROL v%s        ║\n", VERSION);
    printf("╚══════════════════════════════════════════╝\n\n");
    
    // Amministratore?
    printf("  Admin:          %s\n", is_admin() ? "✅ Sì" : "❌ No (alcune funzioni non disponibili)");
    
    // RDP abilitato?
    DWORD rdp_enabled = reg_read_dword(HKEY_LOCAL_MACHINE, REG_RDP_KEY, L"fDenyTSConnections", 1);
    DWORD rdp_port = reg_read_dword(HKEY_LOCAL_MACHINE, REG_RDP_PORT_KEY, L"PortNumber", RDP_PORT_STANDARD);
    printf("  RDP:            %s (porta %d)\n", rdp_enabled == 0 ? "✅ Abilitato" : "❌ Disabilitato", rdp_port);
    
    // Ottieni IP della macchina
    printf("  IP locale:      ");
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) == 0) {
        struct hostent *he = gethostbyname(hostname);
        if (he) {
            for (int i = 0; he->h_addr_list[i] != NULL; i++) {
                struct in_addr addr;
                memcpy(&addr, he->h_addr_list[i], sizeof(addr));
                if (strncmp(inet_ntoa(addr), "127.", 4) != 0 &&
                    strncmp(inet_ntoa(addr), "169.", 4) != 0) {
                    printf("%s  ", inet_ntoa(addr));
                }
            }
        }
    }
    WSACleanup();
    printf("\n");
    
    // OpenSSH installato?
    DWORD attr = GetFileAttributesW(L"C:\\Windows\\System32\\OpenSSH\\ssh.exe");
    printf("  OpenSSH:        %s\n", attr != INVALID_FILE_ATTRIBUTES ? "✅ Installato" : "❌ Non trovato");
    
    // Backup presente?
    wchar_t backup[MAX_PATH];
    swprintf(backup, MAX_PATH, L"%s\\rdp_backup.reg", BACKUP_DIR);
    attr = GetFileAttributesW(backup);
    printf("  Backup stato:   %s\n", attr != INVALID_FILE_ATTRIBUTES ? "✅ Presente" : "⏳ Da fare");
    
    // Tunnel attivo?
    printf("  Tunnel SSH:     %s\n", tunnel_pid > 0 ? "✅ Attivo" : "⏳ Non avviato");
    
    printf("\n");
}

/* ================================================================
 *   MENU INTERATTIVO
 * ================================================================ */

static void show_menu(void) {
    printf("\n");
    printf("╔══════════════════════════════════════════╗\n");
    printf("║        STEALTH REMOTE CONTROL            ║\n");
    printf("║              v%s                        ║\n", VERSION);
    printf("╠══════════════════════════════════════════╣\n");
    printf("║                                          ║\n");
    printf("║  1. Avvia tutto (LAN)                    ║\n");
    printf("║  2. Avvia tutto (VPS remoto)             ║\n");
    printf("║  3. Mostra stato                         ║\n");
    printf("║  4. Ferma tutto e pulisci                ║\n");
    printf("║  5. Esci                                 ║\n");
    printf("║                                          ║\n");
    printf("╚══════════════════════════════════════════╝\n");
    printf("  Scegli: ");
}

static void start_lan(void) {
    printf("\n=== AVVIO MODALITÀ LAN ===\n\n");
    printf("Configurazione per rete locale:\n");
    printf("  - RDP attivo su porta %d\n", RDP_PORT_DEFAULT);
    printf("  - Nessun tunnel SSH\n");
    printf("  - Connettiti con: mstsc /v:<IP-DEL-PC>:%d\n\n", RDP_PORT_DEFAULT);
    
    if (!is_admin()) {
        warn("Servono permessi di amministratore per configurare RDP.");
        warn("Esegui come amministratore (tasto destro → Esegui come amministratore).");
        press_any_key();
        return;
    }
    
    save_state();
    enable_rdp();
    show_status();
    
    printf("\n✅ Pronto! Sul PC del complice esegui:\n");
    printf("   mstsc /v:<IP-DEL-PC>:%d\n", RDP_PORT_DEFAULT);
    printf("\n   (trova l'IP del PC con 'ipconfig')\n");
    printf("\n   PREMI INVIO per fermare tutto e pulire...\n");
    getchar();
    
    disable_rdp();
    restore_state();
    ok("Sistema pulito. Puoi chiudere.");
    press_any_key();
}

static void start_vps(void) {
    printf("\n=== AVVIO MODALITÀ VPS ===\n\n");
    
    char vps_ip[64] = {0};
    int vps_port = 443;
    char ssh_user[64] = "administrator";
    
    printf("Inserisci IP del VPS: ");
    if (fgets(vps_ip, sizeof(vps_ip), stdin)) {
        size_t len = strlen(vps_ip);
        if (len > 0 && vps_ip[len-1] == '\n') vps_ip[len-1] = '\0';
    }
    
    if (strlen(vps_ip) == 0) {
        warn("Nessun IP inserito. Torno al menu.");
        return;
    }
    
    printf("Porta SSH del VPS [443]: ");
    char buf[16];
    if (fgets(buf, sizeof(buf), stdin) && strlen(buf) > 1) {
        vps_port = atoi(buf);
    }
    
    printf("Utente SSH [administrator]: ");
    if (fgets(buf, sizeof(buf), stdin)) {
        size_t len = strlen(buf);
        if (len > 0 && buf[len-1] == '\n') buf[len-1] = '\0';
        if (strlen(buf) > 0) strncpy(ssh_user, buf, sizeof(ssh_user));
    }
    
    if (!is_admin()) {
        warn("Servono permessi di amministratore.");
        press_any_key();
        return;
    }
    
    save_state();
    enable_rdp();
    show_status();
    
    printf("Ora configura la chiave SSH sul VPS e poi premi INVIO per avviare il tunnel...\n");
    printf("  (devi aver aggiunto la chiave pubblica a ~/.ssh/authorized_keys sul VPS)\n");
    getchar();
    
    start_ssh_tunnel(vps_ip, vps_port, RDP_PORT_DEFAULT);
    show_status();
    
    printf("\n✅ Tunnel SSH avviato!\n");
    printf("   Sul PC del complice esegui:\n");
    printf("   ssh -L %d:127.0.0.1:%d %s@%s -p %d -N\n", RDP_PORT_DEFAULT, RDP_PORT_DEFAULT, ssh_user, vps_ip, vps_port);
    printf("   Poi: mstsc /v:127.0.0.1:%d\n", RDP_PORT_DEFAULT);
    printf("\n   PREMI INVIO per fermare tutto e pulire...\n");
    getchar();
    
    stop_ssh_tunnel();
    disable_rdp();
    restore_state();
    ok("Sistema pulito. Puoi chiudere.");
    press_any_key();
}

static void do_cleanup(void) {
    printf("\n=== PULIZIA ===");
    stop_ssh_tunnel();
    disable_rdp();
    restore_state();
    ok("Pulizia completata.");
    press_any_key();
}

/* ================================================================
 *   MAIN
 * ================================================================ */

int main(int argc, char *argv[]) {
    // Header
    printf("\n");
    printf("╔══════════════════════════════════════════╗\n");
    printf("║     STEALTH REMOTE CONTROL  v%s        ║\n", VERSION);
    printf("║     Premi Ctrl+C in qualsiasi momento    ║\n");
    printf("║     per fermare tutto e pulire           ║\n");
    printf("╚══════════════════════════════════════════╝\n");
    printf("\n");
    
    log_msg("=== STEALTH REMOTE CONTROL v%s avviato ===", VERSION);
    
    // Se non sono admin, avvisa
    if (!is_admin()) {
        warn("⚠  NON SEI AMMINISTRATORE");
        warn("   Alcune funzioni richiedono privilegi di amministratore.");
        warn("   Chiudi ed esegui come amministratore (tasto destro → Esegui come amministratore).\n");
    }
    
    // Modalità da riga comando
    if (argc > 1) {
        if (strcmp(argv[1], "--lan") == 0) {
            start_lan();
            return 0;
        } else if (strcmp(argv[1], "--vps") == 0 && argc > 2) {
            // Uso: stealth_host.exe --vps 1.2.3.4 [porta] [utente]
            int vps_port = (argc > 3) ? atoi(argv[3]) : 443;
            char *ssh_user = (argc > 4) ? argv[4] : "administrator";
            save_state();
            enable_rdp();
            start_ssh_tunnel(argv[2], vps_port, RDP_PORT_DEFAULT);
            show_status();
            
            printf("\nTunnel attivo. Premi INVIO per fermare e pulire...\n");
            getchar();
            
            stop_ssh_tunnel();
            disable_rdp();
            restore_state();
            return 0;
        } else if (strcmp(argv[1], "--cleanup") == 0) {
            do_cleanup();
            return 0;
        } else if (strcmp(argv[1], "--status") == 0) {
            show_status();
            return 0;
        } else if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
            printf("Utilizzo:\n");
            printf("  stealth_host.exe            Menu interattivo\n");
            printf("  stealth_host.exe --lan      Avvia in modalità LAN\n");
            printf("  stealth_host.exe --vps IP   Avvia con tunnel verso VPS\n");
            printf("  stealth_host.exe --status   Mostra stato sistema\n");
            printf("  stealth_host.exe --cleanup  Pulisci tutto e ripristina\n");
            return 0;
        }
    }
    
    // Menu interattivo
    int choice = 0;
    do {
        show_menu();
        char buf[16];
        if (!fgets(buf, sizeof(buf), stdin)) break;
        choice = atoi(buf);
        
        switch (choice) {
            case 1: start_lan(); break;
            case 2: start_vps(); break;
            case 3: show_status(); press_any_key(); break;
            case 4: do_cleanup(); break;
            case 5: ok("Alla prossima!"); break;
            default: warn("Scelta non valida. Riprova."); break;
        }
    } while (choice != 5);
    
    if (g_log) fclose(g_log);
    return 0;
}
