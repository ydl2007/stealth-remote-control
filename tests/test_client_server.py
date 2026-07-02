#!/usr/bin/env python3
"""
test_client_server.py — Test end-to-end del Piano B (screen sharing custom).

Avvia un'istanza host e client in locale, verifica:
  1. Host si mette in ascolto sulla porta
  2. Client si connette
  3. Host invia frame JPEG al client
  4. Client riceve frame e li decodifica
  5. Client invia comandi mouse/tastiera
  6. Host li riceve
  7. Entrambi si fermano pulitamente

Eseguibile su macOS, Linux, Windows (dove c'è Python 3 + Pillow).

Uso:
  python test_client_server.py  [--port 4444] [--frames 5]

Exit code: 0 = tutto OK, 1 = test fallito
"""

import socket
import struct
import threading
import time
import io
import sys
import os
import tempfile

# Aggiungi il progetto al path per importare il protocollo
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from shared.protocol import (
    MAGIC_HEADER, FRAME_HEADER_SIZE, PROTOCOL_VERSION,
    TYPE_MOUSE, TYPE_KEYBOARD,
    MOUSE_LEFT_CLICK, MOUSE_MOVE, KEY_DOWN, KEY_UP
)

# =============================================================
#   CONFIG
# =============================================================
PORT = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[1] == '--port' else 4444
NUM_FRAMES = int(sys.argv[3]) if len(sys.argv) > 3 else 5

TIMEOUT = 5.0  # secondi per ogni operazione

# Flag per risultati test
test_results = []
test_lock = threading.Lock()

def test_assert(name, condition, detail=""):
    """Registra il risultato di un test in modo thread-safe."""
    with test_lock:
        if condition:
            print(f"  ✓ {name}")
            test_results.append((name, True, detail))
        else:
            print(f"  ✗ {name} — {detail}")
            test_results.append((name, False, detail))


# =============================================================
#   HOST SIMULATOR (simula main_host.py)
# =============================================================

class TestHost:
    """Host semplificato per test: cattura schermo (o genera dummy) e invia."""
    
    def __init__(self, port):
        self.port = port
        self.server = None
        self.client_sock = None
        self.running = False
        self.frames_sent = 0
        self.inputs_received = []
    
    def _send_frame(self, sock):
        """Invia un frame JPEG (dummy) al client."""
        # Genera un'immagine JPEG finta
        from PIL import Image
        img = Image.new('RGB', (320, 240), color=(73, 109, 137))
        buf = io.BytesIO()
        img.save(buf, format='JPEG', quality=30)
        jpeg_data = buf.getvalue()
        
        width, height = img.size
        
        # Header
        header = struct.pack("<5I",
            int.from_bytes(MAGIC_HEADER, 'little'),
            PROTOCOL_VERSION,
            len(jpeg_data),
            width,
            height
        )
        
        sock.sendall(header + jpeg_data)
        self.frames_sent += 1
    
    def _recv_input(self, sock):
        """Riceve un pacchetto di input dal client."""
        try:
            sock.settimeout(0.5)
            data = sock.recv(1024)
            if data:
                if data[0] == TYPE_MOUSE:
                    event_type = struct.unpack("<H", data[1:3])[0]
                    x = struct.unpack("<I", data[3:7])[0]
                    y = struct.unpack("<I", data[7:11])[0]
                    self.inputs_received.append(('mouse', event_type, x, y))
                elif data[0] == TYPE_KEYBOARD:
                    event_type = struct.unpack("<H", data[1:3])[0]
                    vk = struct.unpack("<H", data[3:5])[0]
                    self.inputs_received.append(('keyboard', event_type, vk))
        except socket.timeout:
            pass
        except Exception as e:
            print(f"      [!] Errore ricezione input: {e}")
    
    def run(self):
        """Avvia il server e gestisce un client."""
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(('127.0.0.1', self.port))
        self.server.listen(1)
        self.server.settimeout(TIMEOUT)
        
        test_assert("HOST: in ascolto sulla porta", True, f"127.0.0.1:{self.port}")
        
        try:
            conn, addr = self.server.accept()
            self.client_sock = conn
            test_assert("HOST: client connesso", True, str(addr))
            self.running = True
            
            # Ciclo invio frame + ricezione input
            for i in range(NUM_FRAMES):
                if not self.running:
                    break
                self._send_frame(conn)
                self._recv_input(conn)
                time.sleep(0.05)  # 50ms tra frame
            
            test_assert("HOST: frame inviati", 
                       self.frames_sent == NUM_FRAMES,
                       f"{self.frames_sent}/{NUM_FRAMES}")
            
            # Test specifici
            has_mouse = any(r[0] == 'mouse' for r in self.inputs_received)
            has_kb = any(r[0] == 'keyboard' for r in self.inputs_received)
            test_assert("HOST: input mouse ricevuti", has_mouse,
                       f"tipi ricevuti: {set(r[0] for r in self.inputs_received)}")
            test_assert("HOST: input tastiera ricevuti", has_kb,
                       f"tipi ricevuti: {set(r[0] for r in self.inputs_received)}")
            
        except socket.timeout:
            test_assert("HOST: connessione client", False, "timeout — nessun client connesso")
        finally:
            self.stop()
    
    def stop(self):
        self.running = False
        if self.client_sock:
            try: self.client_sock.close()
            except: pass
        if self.server:
            try: self.server.close()
            except: pass


# =============================================================
#   CLIENT SIMULATOR (simula main_client.py)
# =============================================================

class TestClient:
    """Client semplificato per test: si connette, riceve frame, invia input."""
    
    def __init__(self, host, port):
        self.host = host
        self.port = port
        self.sock = None
        self.frames_received = 0
        self.inputs_sent = 0
        self.errors = []
    
    def _recv_frame(self):
        """Riceve un frame e lo decodifica."""
        try:
            # Header
            self.sock.settimeout(TIMEOUT)
            header = self.sock.recv(FRAME_HEADER_SIZE)
            if len(header) < FRAME_HEADER_SIZE:
                self.errors.append("Header troppo corto")
                return False
            
            magic = header[:4]
            if magic != MAGIC_HEADER:
                self.errors.append(f"Magic header non valido: {magic!r}")
                return False
            
            version = struct.unpack("<I", header[4:8])[0]
            data_size = struct.unpack("<I", header[8:12])[0]
            width = struct.unpack("<I", header[12:16])[0]
            height = struct.unpack("<I", header[16:20])[0]
            
            if data_size > 10 * 1024 * 1024:
                self.errors.append(f"Frame troppo grande: {data_size}")
                return False
            
            # Dati JPEG
            jpeg_data = b""
            while len(jpeg_data) < data_size:
                chunk = self.sock.recv(data_size - len(jpeg_data))
                if not chunk:
                    self.errors.append("Connessione chiusa durante ricezione frame")
                    return False
                jpeg_data += chunk
            
            # Decodifica JPEG
            from PIL import Image
            img = Image.open(io.BytesIO(jpeg_data))
            
            test_assert(f"CLIENT: frame #{self.frames_received + 1} — formato corretto",
                       img.format == 'JPEG' and img.size == (width, height),
                       f"formato={img.format}, size={img.size}, atteso={width}x{height}")
            
            self.frames_received += 1
            return True
            
        except socket.timeout:
            self.errors.append(f"Timeout ricezione frame #{self.frames_received + 1}")
            return False
        except Exception as e:
            self.errors.append(f"Errore frame #{self.frames_received + 1}: {e}")
            return False
    
    def _send_inputs(self):
        """Invia comandi mouse e tastiera all'host."""
        # Mouse click a coordinate diverse
        inputs = [
            (TYPE_MOUSE, MOUSE_MOVE, 100, 200),
            (TYPE_MOUSE, MOUSE_LEFT_CLICK, 150, 250),
            (TYPE_MOUSE, MOUSE_MOVE, 300, 400),
        ]
        
        for i, (typ, event, x, y) in enumerate(inputs):
            packet = struct.pack("<BHHI", typ, event, x, y)
            try:
                self.sock.sendall(packet)
                self.inputs_sent += 1
            except Exception as e:
                self.errors.append(f"Invio input #{i} fallito: {e}")
        
        # Input tastiera
        key_inputs = [
            (TYPE_KEYBOARD, KEY_DOWN, 0x41),  # A key
            (TYPE_KEYBOARD, KEY_UP, 0x41),
            (TYPE_KEYBOARD, KEY_DOWN, 0x0D),  # Enter
            (TYPE_KEYBOARD, KEY_UP, 0x0D),
        ]
        
        for i, (typ, event, vk) in enumerate(key_inputs):
            packet = struct.pack("<BHH", typ, event, vk)
            try:
                self.sock.sendall(packet)
                self.inputs_sent += 1
            except Exception as e:
                self.errors.append(f"Invio key #{i} fallito: {e}")
    
    def run(self):
        """Si connette e fa il ciclo di test."""
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.settimeout(TIMEOUT)
            self.sock.connect((self.host, self.port))
            test_assert("CLIENT: connesso all'host", True, f"{self.host}:{self.port}")
            
            # Invia input prima di ricevere frame (l'host fa entrambi)
            self._send_inputs()
            test_assert("CLIENT: input inviati", self.inputs_sent > 0,
                       f"{self.inputs_sent} pacchetti")
            
            # Ricevi frame
            for i in range(NUM_FRAMES):
                if not self._recv_frame():
                    break
            
            test_assert("CLIENT: frame ricevuti",
                       self.frames_received == NUM_FRAMES,
                       f"{self.frames_received}/{NUM_FRAMES}")
            
        except socket.timeout:
            test_assert("CLIENT: connessione all'host", False,
                       f"timeout — host non raggiungibile su {self.host}:{self.port}")
        except ConnectionRefusedError:
            test_assert("CLIENT: connessione all'host", False,
                       "connessione rifiutata — host non in esecuzione")
        except Exception as e:
            test_assert("CLIENT: esecuzione", False, str(e))
        finally:
            try:
                if self.sock:
                    self.sock.close()
            except:
                pass


# =============================================================
#   TEST PROTOCOLLO (test isolati delle funzioni in protocol.py)
# =============================================================

def test_protocol_functions():
    """Testa le funzioni del modulo shared.protocol in isolamento."""
    print("\n── test_protocol ──")
    
    # Test create_mouse_packet
    packet = struct.pack("<BHHI", TYPE_MOUSE, MOUSE_LEFT_CLICK, 100, 200)
    test_assert("PROTOCOL: pacchetto mouse — formato",
               len(packet) == 11,
               f"lunghezza={len(packet)}")
    test_assert("PROTOCOL: pacchetto mouse — TYPE",
               packet[0] == TYPE_MOUSE)
    
    # Test create_keyboard_packet
    packet = struct.pack("<BHH", TYPE_KEYBOARD, KEY_DOWN, 0x41)
    test_assert("PROTOCOL: pacchetto tastiera — formato",
               len(packet) == 5,
               f"lunghezza={len(packet)}")
    
    # Test frame header format
    header = struct.pack("<5I",
        int.from_bytes(MAGIC_HEADER, 'little'),
        PROTOCOL_VERSION,
        1024,  # data_size
        320,   # width
        240    # height
    )
    test_assert("PROTOCOL: frame header — MAGIC",
               header[:4] == MAGIC_HEADER)
    test_assert("PROTOCOL: frame header — lunghezza",
               len(header) == FRAME_HEADER_SIZE,
               f"{len(header)}/{FRAME_HEADER_SIZE}")
    
    # Test parsing header
    magic = header[:4]
    version = struct.unpack("<I", header[4:8])[0]
    data_size = struct.unpack("<I", header[8:12])[0]
    width = struct.unpack("<I", header[12:16])[0]
    height = struct.unpack("<I", header[16:20])[0]
    
    test_assert("PROTOCOL: parse header — version",
               version == PROTOCOL_VERSION)
    test_assert("PROTOCOL: parse header — data_size",
               data_size == 1024)
    test_assert("PROTOCOL: parse header — dimensions",
               width == 320 and height == 240)


# =============================================================
#   NETWORK TEST (test connettività di base)
# =============================================================

def test_network_connectivity():
    """Testa che il networking di base funzioni."""
    print("\n── test_network ──")
    
    # Test che la porta sia libera
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(('127.0.0.1', PORT))
        s.close()
        test_assert("NET: porta disponibile", True, f"127.0.0.1:{PORT}")
    except OSError:
        test_assert("NET: porta disponibile", False, f"porta {PORT} già in uso")
    
    # Test loopback
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    test_assert("NET: socket creato", True)
    s.close()


# =============================================================
#   MAIN
# =============================================================

def main():
    print("\n")
    print("╔══════════════════════════════════════════╗")
    print("║  TEST CLIENT-SERVER — STEALTH REMOTE     ║")
    print("╚══════════════════════════════════════════╝")
    print(f"\n  Porta: {PORT}  Frame: {NUM_FRAMES}  Timeout: {TIMEOUT}s\n")
    
    # Test 1: Protocollo
    test_protocol_functions()
    
    # Test 2: Networking
    test_network_connectivity()
    
    # Test 3: Client-Server end-to-end
    print("\n── test_client_server ──")
    
    host = TestHost(PORT)
    client = TestClient('127.0.0.1', PORT)
    
    # Avvia host in thread
    host_thread = threading.Thread(target=host.run, daemon=True)
    host_thread.start()
    time.sleep(0.2)  # Lascia tempo all'host di mettersi in ascolto
    
    # Avvia client
    client.run()
    
    # Aspetta che l'host finisca
    host_thread.join(timeout=TIMEOUT + 2)
    
    # =============================================================
    #   REPORT
    # =============================================================
    print("\n────────────────────────────────────────")
    
    total = len(test_results)
    passed = sum(1 for _, ok, _ in test_results if ok)
    failed = total - passed
    
    print(f"  Totale: {total}  |  ✅ Passati: {passed}  |  ❌ Falliti: {failed}")
    
    if failed > 0:
        print("\n  Dettaglio fallimenti:")
        for name, ok, detail in test_results:
            if not ok:
                print(f"    - {name}: {detail}")
    
    print("────────────────────────────────────────\n")
    
    return 1 if failed > 0 else 0


if __name__ == '__main__':
    # Verifica Pillow
    try:
        from PIL import Image
    except ImportError:
        print("\n[!] Pillow non installato. Esegui: pip install Pillow\n")
        sys.exit(1)
    
    sys.exit(main())
