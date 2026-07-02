# Come compilare ed eseguire su Windows

> Istruzioni passo-passo per chi non ha mai compilato un programma C su Windows.

---

## Cosa devi fare

1. **Installare Visual Studio** (una volta sola)
2. **Compilare il programma** (un click)
3. **Copiare l'exe sul PC** (una volta)
4. **Eseguire** (sempre così)

---

## Passo 1: Installa Visual Studio

1. Vai su: https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022
2. Clicca **"Download Build Tools for Visual Studio 2022"**
3. Esegui il file scaricato
4. Nella finestra che si apre, seleziona:
   - **"Desktop development with C++"**
5. Clicca **"Install"** in basso a destra
6. Aspetta che finisca (5-10 minuti, dipende da internet)

✅ Fatto. Visual Studio è installato.

---

## Passo 2: Compila il programma

1. Apri il **menu Start**
2. Cerca e apri **"Developer Command Prompt for VS 2022"** (non il normale cmd)
3. Nella finestra nera che si apre, scrivi:

```cmd
cd C:\percorso\dove\hai\salvato\stealth-remote-control\host\core_c
```

(Sostituisci `C:\percorso\dove\hai\salvato` con il percorso vero — esempio: `C:\Users\Mario\Desktop\stealth-remote-control`)

4. Poi scrivi:

```cmd
nmake /f Makefile all
```

5. Se tutto va bene, vedrai:

```
[+] Compilato: ..\..\stealth_host.exe
[+] Compilato: ..\..\stealth_client.exe
```

6. I file `.exe` sono apparsi nella cartella principale `stealth-remote-control\`.

✅ Fatto. Hai due programmi:
- **`stealth_host.exe`** — da eseguire sul PC che fa l'esame
- **`stealth_client.exe`** — da eseguire sul PC del complice

---

## Passo 3: Esegui sul PC ESAME

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
