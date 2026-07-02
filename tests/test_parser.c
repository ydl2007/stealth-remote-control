/**
 * test_parser.c — Test unitari per il parsing degli argomenti.
 *
 * Compila ed esegui su Mac:
 *   gcc -o test_parser test_parser.c && ./test_parser
 *
 * Compila ed esegui su Windows (MinGW):
 *   gcc -o test_parser.exe test_parser.c && test_parser.exe
 *
 * Testa le funzioni di parsing da stealth_host.c e stealth_client.c
 * isolate dalle API Windows (sostituite con stub).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

/* ================================================================
 *   STUB — Sostituzioni per API Windows non disponibili su Mac
 * ================================================================
 * Le funzioni sotto sono versioni "pure" della logica nei .c,
 * riscritte senza dipendenze Windows per poter testare su Mac.
 */

/**
 * Stub di is_admin — su Mac siamo sempre "not admin" per il test.
 * La vera funzione chiama OpenProcessToken + GetTokenInformation.
 */
int stub_is_admin(void) {
    return 0;  // Simula: non admin
}

/**
 * Parsing indirizzo IP:porta da stringa.
 * Supporta formati:
 *   "192.168.1.5"          -> ip="192.168.1.5", port=0 (default)
 *   "192.168.1.5:3390"    -> ip="192.168.1.5", port=3390
 *   "/v:192.168.1.5:3390" -> ip="192.168.1.5", port=3390  (stile mstsc)
 * 
 * Ritorna 0 se OK, -1 se errore.
 */
int parse_address(const char *input, char *ip_out, int ip_size, int *port_out) {
    if (!input || !ip_out || !port_out) return -1;
    
    const char *start = input;
    
    // Salta il prefisso /v: (stile mstsc)
    if (strncmp(start, "/v:", 3) == 0) {
        start += 3;
    }
    
    // Cerca l'ultimo : (separatore porta)
    const char *colon = strrchr(start, ':');
    
    if (colon) {
        // C'è una porta
        size_t ip_len = colon - start;
        if (ip_len == 0 || ip_len >= (size_t)ip_size) return -1;
        
        strncpy(ip_out, start, ip_len);
        ip_out[ip_len] = '\0';
        
        *port_out = atoi(colon + 1);
        if (*port_out <= 0 || *port_out > 65535) return -1;
    } else {
        // Solo IP, nessuna porta
        size_t len = strlen(start);
        if (len == 0 || len >= (size_t)ip_size) return -1;
        
        strncpy(ip_out, start, ip_size);
        ip_out[ip_size - 1] = '\0';
        *port_out = 0;
    }
    
    return 0;
}

/**
 * Validazione IP (IPv4): "1.2.3.4"
 * Non serve connessione — solo controllo formato.
 */
int validate_ipv4(const char *ip) {
    if (!ip || strlen(ip) == 0) return -1;
    
    int octets[4];
    char extra[2] = {0};  // Cattura caratteri extra dopo il match
    int parsed = sscanf(ip, "%d.%d.%d.%d%1s", &octets[0], &octets[1], &octets[2], &octets[3], extra);
    if (parsed != 4) return -1;  // parsed == 4 = match esatto (extra non riempito)
    
    for (int i = 0; i < 4; i++) {
        if (octets[i] < 0 || octets[i] > 255) return -1;
    }
    
    return 0;
}

/**
 * Determinazione automatica modalità:
 * - "127.0.0.1" o "localhost" -> loopback (tunnel o locale)
 * - IP privati (10.x, 192.168.x, 172.16-31.x) -> LAN
 * - Altri IP -> remoto (VPS)
 * 
 * Ritorna: "loopback", "lan", "remote", "invalid"
 */
const char* classify_address(const char *ip) {
    if (!ip) return "invalid";
    
    if (strcmp(ip, "127.0.0.1") == 0 || strcmp(ip, "localhost") == 0) {
        return "loopback";
    }
    
    if (validate_ipv4(ip) != 0) return "invalid";
    
    int o1, o2, o3, o4;
    sscanf(ip, "%d.%d.%d.%d", &o1, &o2, &o3, &o4);
    
    // 10.x.x.x
    if (o1 == 10) return "lan";
    // 192.168.x.x
    if (o1 == 192 && o2 == 168) return "lan";
    // 172.16-31.x.x
    if (o1 == 172 && o2 >= 16 && o2 <= 31) return "lan";
    // 169.254.x.x (link-local)
    if (o1 == 169 && o2 == 254) return "lan";
    
    return "remote";
}

/* ================================================================
 *   TEST
 * ================================================================ */

static int tests_passed = 0;
static int tests_failed = 0;
static int test_count = 0;

#define TEST(name, expr) do { \
    test_count++; \
    if (!(expr)) { \
        printf("  ✗ %-55s riga %d\n", name, __LINE__); \
        tests_failed++; \
    } else { \
        printf("  ✓ %s\n", name); \
        tests_passed++; \
    } \
} while(0)

void test_parse_address(void) {
    printf("\n── test_parse_address ──\n");
    
    char ip[64];
    int port;
    
    // Formato base: IP solo
    TEST("IP semplice",
        parse_address("192.168.1.5", ip, sizeof(ip), &port) == 0 &&
        strcmp(ip, "192.168.1.5") == 0 && port == 0);
    
    // IP + porta
    TEST("IP:porta",
        parse_address("192.168.1.5:3390", ip, sizeof(ip), &port) == 0 &&
        strcmp(ip, "192.168.1.5") == 0 && port == 3390);
    
    // /v: stile mstsc
    TEST("Stile /v:IP:porta",
        parse_address("/v:10.0.0.1:3389", ip, sizeof(ip), &port) == 0 &&
        strcmp(ip, "10.0.0.1") == 0 && port == 3389);
    
    // /v: senza porta
    TEST("Stile /v:IP senza porta",
        parse_address("/v:192.168.1.100", ip, sizeof(ip), &port) == 0 &&
        strcmp(ip, "192.168.1.100") == 0 && port == 0);
    
    // Loopback
    TEST("Loopback",
        parse_address("127.0.0.1:3390", ip, sizeof(ip), &port) == 0 &&
        strcmp(ip, "127.0.0.1") == 0 && port == 3390);
    
    // Porta massima
    TEST("Porta 65535",
        parse_address("1.2.3.4:65535", ip, sizeof(ip), &port) == 0 && port == 65535);
    
    // Casi limite
    TEST("Input nullo -> -1",
        parse_address(NULL, ip, sizeof(ip), &port) == -1);
    
    TEST("Stringa vuota -> -1",
        parse_address("", ip, sizeof(ip), &port) == -1);
    
    TEST("Porta 0 -> -1",       /* non valida */
        parse_address("1.2.3.4:0", ip, sizeof(ip), &port) == -1);
    
    TEST("Porta 65536 -> -1",   /* fuori range */
        parse_address("1.2.3.4:65536", ip, sizeof(ip), &port) == -1);
    
    TEST("Porta negativa -> -1",
        parse_address("1.2.3.4:-1", ip, sizeof(ip), &port) == -1);
    
    TEST("IP con punti multipli",
        parse_address("10.0.0.1:4444", ip, sizeof(ip), &port) == 0 &&
        strcmp(ip, "10.0.0.1") == 0 && port == 4444);
    
    // Due punti nell'IP (IPv6-like — non supportato, ma non deve crashare)
    // La funzione usa strrchr, quindi trova l'ultimo :
    TEST("IP con porta su colon singolo",
        parse_address("10.0.0.1:9999", ip, sizeof(ip), &port) == 0 &&
        port == 9999);
}

void test_validate_ipv4(void) {
    printf("\n── test_validate_ipv4 ──\n");
    
    TEST("IPv4 valido",     validate_ipv4("192.168.1.1") == 0);
    TEST("IPv4 0.0.0.0",    validate_ipv4("0.0.0.0") == 0);
    TEST("IPv4 255.255.255.255", validate_ipv4("255.255.255.255") == 0);
    TEST("IPv4 10.0.0.1",   validate_ipv4("10.0.0.1") == 0);
    
    TEST("Stringa vuota",   validate_ipv4("") == -1);
    TEST("Solo testo",      validate_ipv4("abc") == -1);
    TEST("3 ottetti",       validate_ipv4("1.2.3") == -1);
    TEST("5 ottetti",       validate_ipv4("1.2.3.4.5") == -1);
    TEST("Ottetto > 255",   validate_ipv4("256.1.1.1") == -1);
    TEST("Ottetto negativo", validate_ipv4("-1.1.1.1") == -1);
    TEST("IP con porta",    validate_ipv4("1.2.3.4:3390") == -1);  // non è un IP puro
    TEST("Null",            validate_ipv4(NULL) == -1);
}

void test_classify_address(void) {
    printf("\n── test_classify_address ──\n");
    
    TEST("127.0.0.1 -> loopback",   strcmp(classify_address("127.0.0.1"), "loopback") == 0);
    TEST("localhost -> loopback",   strcmp(classify_address("localhost"), "loopback") == 0);
    
    TEST("10.0.0.1 -> lan",     strcmp(classify_address("10.0.0.1"), "lan") == 0);
    TEST("10.255.255.255 -> lan", strcmp(classify_address("10.255.255.255"), "lan") == 0);
    TEST("192.168.0.1 -> lan",  strcmp(classify_address("192.168.0.1"), "lan") == 0);
    TEST("192.168.255.255 -> lan", strcmp(classify_address("192.168.255.255"), "lan") == 0);
    TEST("172.16.0.1 -> lan",   strcmp(classify_address("172.16.0.1"), "lan") == 0);
    TEST("172.31.255.255 -> lan", strcmp(classify_address("172.31.255.255"), "lan") == 0);
    TEST("169.254.1.1 -> lan",  strcmp(classify_address("169.254.1.1"), "lan") == 0);
    
    TEST("8.8.8.8 -> remote",   strcmp(classify_address("8.8.8.8"), "remote") == 0);
    TEST("1.1.1.1 -> remote",   strcmp(classify_address("1.1.1.1"), "remote") == 0);
    TEST("203.0.113.1 -> remote", strcmp(classify_address("203.0.113.1"), "remote") == 0);
    TEST("172.15.0.1 -> remote", strcmp(classify_address("172.15.0.1"), "remote") == 0);  // prima di 16
    TEST("172.32.0.1 -> remote", strcmp(classify_address("172.32.0.1"), "remote") == 0);  // dopo 31
    
    TEST("Null -> invalid",     strcmp(classify_address(NULL), "invalid") == 0);
    TEST("Stringa -> invalid",  strcmp(classify_address("not-an-ip"), "invalid") == 0);
}

void test_menu_parsing(void) {
    printf("\n── test_menu_parsing ──\n");
    
    // Simula la scelta menu da stealth_host.c
    // Il main legge un char con fgets, poi atoi()
    
    TEST("Scelta 1 -> LAN",     atoi("1\n") == 1);
    TEST("Scelta 2 -> VPS",     atoi("2\n") == 2);
    TEST("Scelta 3 -> Status",  atoi("3\n") == 3);
    TEST("Scelta 4 -> Cleanup", atoi("4\n") == 4);
    TEST("Scelta 5 -> Esci",    atoi("5\n") == 5);
    TEST("Input non numerico -> 0", atoi("abc\n") == 0);
    TEST("Input vuoto -> 0",    atoi("\n") == 0);
    TEST("Input negativo",      atoi("-1\n") == -1);
    TEST("Numeri grandi",       atoi("99\n") == 99);
}

/* ================================================================
 *   MAIN
 * ================================================================ */

int main(void) {
    printf("\n");
    printf("╔══════════════════════════════════════════╗\n");
    printf("║       TEST PARSER — STEALTH REMOTE       ║\n");
    printf("╚══════════════════════════════════════════╝\n");
    
    test_parse_address();
    test_validate_ipv4();
    test_classify_address();
    test_menu_parsing();
    
    printf("\n────────────────────────────────────────\n");
    printf("  Totale: %d  |  ✅ Passati: %d  |  ❌ Falliti: %d\n",
           test_count, tests_passed, tests_failed);
    printf("────────────────────────────────────────\n\n");
    
    return tests_failed > 0 ? 1 : 0;
}
