# Come compilare ed eseguire su Windows

> Istruzioni passo-passo per chi non ha mai compilato un programma C su Windows.

---

## Il modo più facile: compilazione automatica

1. Copia la cartella del progetto sul PC Windows
2. Fai **doppio click** su **`build_mingw.bat`**
3. Il programma:
   - Cerca MinGW (compilatore C gratuito)
   - Se non lo trova, lo **scarica e installa automaticamente**
   - Compila **`stealth_host.exe`** e **`stealth_client.exe`**
   - Ti dice quando ha finito
4. I due `.exe` sono pronti nella cartella principale

✅ **Fatto. Non devi installare nulla.**

---

## Compilazione manuale (se preferisci)

### Con MinGW-w64 (consigliato)

Se hai già MinGW installato:

```cmd
cd host\core_c
gcc -o ..\..\stealth_host.exe stealth_host.c -ladvapi32 -liphlpapi -lws2_32 -luser32 -lshlwapi
cd ..\..\client\core_c
gcc -o ..\..\stealth_client.exe stealth_client.c -luser32 -lws2_32
```

### Con Visual Studio

Se preferisci Visual Studio (più grande, ma già presente in alcuni ambienti):

1. Apri **"Developer Command Prompt for VS 2022"** dal menu Start
2. Vai nella cartella:
   ```cmd
   cd C:\percorso\stealth-remote-control\host\core_c
   ```
3. Compila:
   ```cmd
   nmake /f Makefile all
   ```

---

## Esegui sul PC ESAME

Copia **solo `stealth_host.exe`** sul PC che farà l'esame.

1. **Tasto destro → Esegui come amministratore**
2. Si apre un menu:
   ```
   1. Avvia tutto (LAN)
   2. Avvia tutto (VPS remoto)
   3. Mostra stato
   4. Ferma tutto e pulisci
   5. Esci
   ```
3. Scegli **1** per LAN, **2** per VPS
4. Il programma fa tutto da solo:
   - Salva lo stato originale
   - Abilita RDP sulla porta 3390
   - Apre le porte sul firewall
   - Mostra l'IP del PC
5. Quando hai finito, premi **INVIO** e lui pulisce tutto

⚠ **Importante**: Esegui SEMPRE come amministratore (tasto destro sul file → "Esegui come amministratore").

---

## Passo 4: Esegui sul PC COMPLICE

Copia **`stealth_client.exe`** sul PC del complice.

**Se siete nella stessa rete (LAN):**

```cmd
stealth_client.exe <IP-DEL-PC-ESAME>
```

Esempio:
```cmd
stealth_client.exe 192.168.1.50
```

Trovi l'IP del PC esame scritto a schermo da `stealth_host.exe`.

**Se usate il VPS (tunnel SSH):**

Prima avvia il tunnel SSH manualmente, poi:

```cmd
stealth_client.exe /v:127.0.0.1:3390
```

Il programma apre automaticamente `mstsc.exe` (Connessione Desktop Remoto).

---

## Se qualcosa non funziona

| Problema | Soluzione |
|----------|-----------|
| "Accesso negato" | Esegui come amministratore |
| "OpenSSH non trovato" | Vai su Impostazioni → App → Funzionalità opzionali → Aggiungi "OpenSSH Client" |
| "Porta non raggiungibile" | Controlla che i due PC siano sulla stessa rete |
| "Visual Studio non trovato" | Non hai aperto "Developer Command Prompt" ma il cmd normale |
| Il programma non si apre | Windows Defender potrebbe bloccarlo. Clicca "Ulteriori informazioni → Esegui comunque" |

---

## Compilare senza Visual Studio (MinGW)

Se preferisci usare MinGW (GCC per Windows):

```cmd
gcc -o stealth_host.exe host/core_c/stealth_host.c -ladvapi32 -liphlpapi -lws2_32 -luser32 -lshlwapi
```

Oppure nella cartella `host/core_c`:

```cmd
mingw32-make -f Makefile gcc
```
