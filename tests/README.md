# Test Suite — Stealth Remote Control

## Panoramica

| Test | Cosa verifica | Eseguibile su |
|------|--------------|---------------|
| `test_parser.c` | Parsing argomenti, IP, porte, menu | **Mac, Linux, Windows** (solo C standard) |
| `test_client_server.py` | Piano B: host+client, invio frame, input | **Mac, Linux, Windows** (Python 3 + Pillow) |
| `test_rdp_config.bat` | RDP on/off, porta, firewall, cleanup | **Windows** (admin) |
| `test_integration.ps1` | Ciclo completo setup→stato→cleanup | **Windows** (admin) |
| `test_security.ps1` | Invisibilità durante uso attivo | **Windows** (admin) |

---

## Test eseguibili subito (da Mac)

### test_parser.c — test unitari C

```bash
cd tests
gcc -o test_parser test_parser.c && ./test_parser
```

Output atteso: 50/50 test passati.

Cosa testa:
- `parse_address()` — input come `192.168.1.5:3390`, `/v:IP:porta`
- `validate_ipv4()` — IP validi, stringhe non IP, overflow, null
- `classify_address()` — loopback vs LAN vs remote
- Menu parsing — input numerici, negativi, vuoti

### test_client_server.py — Piano B end-to-end

```bash
pip install Pillow       # prima volta
python tests/test_client_server.py
```

Output atteso: tutti i test passati, ~20 verifiche.

Cosa testa:
- Protocollo wire (header, MAGIC, versioni)
- Connessione TCP host → client
- Invio frame JPEG + decodifica
- Invio comandi mouse/tastiera
- Cleanup di entrambi i lati

---

## Test su Windows

### Requisiti

- Windows 10/11
- Amministratore per i test su RDP
- PowerShell 5.1+ (built-in)
- Per `test_rdp_config.bat`: nessun prerequisito
- Per `test_integration.ps1` e `test_security.ps1`: PowerShell execution policy non restrittiva:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### Esecuzione

```cmd
:: 1. Test RDP (il più veloce)
tests\test_rdp_config.bat
:: → Esegui come amministratore

:: 2. Test integrazione (completo)
powershell -ExecutionPolicy Bypass -File tests\test_integration.ps1
:: → Esegui come amministratore

:: 3. Test sicurezza (mentre programma attivo)
powershell -ExecutionPolicy Bypass -File tests\test_security.ps1
:: → Esegui come amministratore
```

### Output atteso (Windows)

| Test | Passaggi attesi |
|------|----------------|
| `test_rdp_config.bat` | 10 check: backup, enable, porta, firewall, servizio, disable, rollback |
| `test_integration.ps1` | 16 check: backup state → enable → status → detection → cleanup → verify rollback |
| `test_security.ps1` | 10+ check: baseline → enable → detection while active → verify no flags → cleanup |

### Se un test fallisce

| Sintomo | Causa probabile |
|---------|----------------|
| "Accesso negato" | Esegui come amministratore |
| "TermService non trovato" | Windows Home edition |
| "Porta 3390 non in ascolto" | Firewall blocca o script enable fallito |
| "Firma non valida" | Processo custom rilevato (non nostro) |
| "Regola firewall non rimossa" | Cleanup eseguito 2 volte |

---

## Integrazione continua (manuale)

Prima di un uso reale:

```cmd
:: 1. Compila
build_mingw.bat

:: 2. Test di sicurezza (con programma attivo)
powershell -ExecutionPolicy Bypass -File tests\test_security.ps1

:: 3. Se tutto OK → procedi
```

Se `test_security.ps1` passa, il programma è invisibile al detection sandbox. Se fallisce, non procedere.
