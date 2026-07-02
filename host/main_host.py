#!/usr/bin/env python3
"""
Stealth Remote Control - Host (exam PC)
========================================
Captures screen and streams it to the client (helper PC).
Receives mouse/keyboard input events and injects them locally.

This is the component that runs on the PC being examined.
It uses GDI (not DXGI) for screen capture to avoid detection.

Usage (Piano B - standalone, no RDP):
  python main_host.py <listen_port>
  python main_host.py 4444

For Piano A (RDP via SSH tunnel), use enable_rdp_stealth.bat + tunnel scripts instead.
"""

import socket
import struct
import threading
import time
import io
import os
import sys
import random
from PIL import Image, ImageGrab

# Try to import Windows-specific input injection
try:
    import ctypes
    from ctypes import wintypes

    # Windows virtual key codes
    class MOUSEINPUT(ctypes.Structure):
        _fields_ = [
            ("dx", wintypes.LONG),
            ("dy", wintypes.LONG),
            ("mouseData", wintypes.DWORD),
            ("dwFlags", wintypes.DWORD),
            ("time", wintypes.DWORD),
            ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
        ]

    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [
            ("wVk", wintypes.WORD),
            ("wScan", wintypes.WORD),
            ("dwFlags", wintypes.DWORD),
            ("time", wintypes.DWORD),
            ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
        ]

    class INPUT_UNION(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT)]

    class INPUT(ctypes.Structure):
        _fields_ = [("type", wintypes.DWORD), ("union", INPUT_UNION)]

    SendInput = ctypes.windll.user32.SendInput
    SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
    SendInput.restype = wintypes.UINT

    MOUSEEVENTF_MOVE = 0x0001
    MOUSEEVENTF_ABSOLUTE = 0x8000
    MOUSEEVENTF_LEFTDOWN = 0x0002
    MOUSEEVENTF_LEFTUP = 0x0004
    MOUSEEVENTF_RIGHTDOWN = 0x0008
    MOUSEEVENTF_RIGHTUP = 0x0010

    KEYEVENTF_KEYUP = 0x0002

    SCREEN_WIDTH = ctypes.windll.user32.GetSystemMetrics(0)
    SCREEN_HEIGHT = ctypes.windll.user32.GetSystemMetrics(1)

    HAS_WIN_API = True
except ImportError:
    # Running on non-Windows (macOS/Linux) - can't inject input
    HAS_WIN_API = False
    SCREEN_WIDTH = 1920
    SCREEN_HEIGHT = 1080

# Protocol constants
MAGIC_HEADER = b"STRM"
PROTOCOL_VERSION = 1
FRAME_QUALITY = 60  # JPEG quality (lower = smaller, more stealth)
FRAME_INTERVAL_MS = 100  # 10 FPS base
FRAME_JITTER_MS = 40  # Random jitter to avoid fixed-interval detection


def inject_mouse_click(x: int, y: int, button: int = 0):
    """
    Inject mouse click at absolute coordinates.
    Uses randomized timing to avoid detection of synthetic input.
    """
    if not HAS_WIN_API:
        return

    # Add tiny random delay to simulate human-like input timing
    time.sleep(random.uniform(0.005, 0.015))

    # Normalize coordinates to absolute (0-65535)
    abs_x = int(x * 65535 / SCREEN_WIDTH)
    abs_y = int(y * 65535 / SCREEN_HEIGHT)

    # Move to position
    move_input = INPUT()
    move_input.type = 0  # INPUT_MOUSE
    move_input.union.mi.dx = abs_x
    move_input.union.mi.dy = abs_y
    move_input.union.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
    SendInput(1, ctypes.byref(move_input), ctypes.sizeof(INPUT))

    time.sleep(random.uniform(0.01, 0.02))

    # Click down
    down_input = INPUT()
    down_input.type = 0
    down_input.union.mi.dwFlags = (
        MOUSEEVENTF_LEFTDOWN if button == 0 else MOUSEEVENTF_RIGHTDOWN
    )
    SendInput(1, ctypes.byref(down_input), ctypes.sizeof(INPUT))

    time.sleep(random.uniform(0.03, 0.08))

    # Click up
    up_input = INPUT()
    up_input.type = 0
    up_input.union.mi.dwFlags = (
        MOUSEEVENTF_LEFTUP if button == 0 else MOUSEEVENTF_RIGHTUP
    )
    SendInput(1, ctypes.byref(up_input), ctypes.sizeof(INPUT))


def inject_key_press(vk_code: int):
    """Inject a key press (down then up)."""
    if not HAS_WIN_API:
        return

    time.sleep(random.uniform(0.005, 0.015))

    # Key down
    down_input = INPUT()
    down_input.type = 1  # INPUT_KEYBOARD
    down_input.union.ki.wVk = vk_code
    down_input.union.ki.dwFlags = 0
    SendInput(1, ctypes.byref(down_input), ctypes.sizeof(INPUT))

    time.sleep(random.uniform(0.05, 0.15))

    # Key up
    up_input = INPUT()
    up_input.type = 1
    up_input.union.ki.wVk = vk_code
    up_input.union.ki.dwFlags = KEYEVENTF_KEYUP
    SendInput(1, ctypes.byref(up_input), ctypes.sizeof(INPUT))


def capture_screen_jpeg() -> bytes:
    """
    Capture the screen and return JPEG bytes.
    Uses PIL's ImageGrab (GDI-based on Windows - less detectable than DXGI).
    """
    # Random capture interval jitter
    time.sleep(random.uniform(0, FRAME_JITTER_MS / 1000))

    screenshot = ImageGrab.grab()
    buf = io.BytesIO()
    screenshot.save(buf, format="JPEG", quality=FRAME_QUALITY, optimize=True)
    return buf.getvalue(), screenshot.width, screenshot.height


class StealthHost:
    """Host server for stealth remote control."""

    def __init__(self, port: int):
        self.port = port
        self.running = False
        self.client_sock = None
        self.server_sock = None

    def start(self):
        """Start the server."""
        self.server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_sock.bind(("0.0.0.0", self.port))
        self.server_sock.listen(1)
        self.server_sock.settimeout(1.0)

        print(f"[*] Stealth Host listening on port {self.port}")
        print(f"[*] SCREEN: {SCREEN_WIDTH}x{SCREEN_HEIGHT}")
        print(f"[*] MODE: Piano B - Direct screen capture")
        print(f"[*] QUALITY: JPEG {FRAME_QUALITY}, ~{FRAME_INTERVAL_MS}ms interval")
        if not HAS_WIN_API:
            print("[!] WARNING: Running on non-Windows. Input injection disabled.")
        print()

        self.running = True

        # Accept connection
        while self.running:
            try:
                self.client_sock, addr = self.server_sock.accept()
                print(f"[+] Client connected: {addr}")
                self.handle_client(addr)
            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    print(f"[!] Accept error: {e}")

    def handle_client(self, addr):
        """Handle a connected client."""
        if not self.client_sock:
            return

        # Start stream thread
        stream_thread = threading.Thread(
            target=self.stream_screen, daemon=True
        )
        stream_thread.start()

        # Handle input commands from client
        self.handle_input_commands()

    def stream_screen(self):
        """Stream screen captures to the client."""
        while self.running and self.client_sock:
            try:
                # Capture screen
                jpeg_data, width, height = capture_screen_jpeg()

                # Build header: MAGIC(4) + VERSION(4) + SIZE(4) + WIDTH(4) + HEIGHT(4)
                header = (
                    MAGIC_HEADER
                    + struct.pack("<I", PROTOCOL_VERSION)
                    + struct.pack("<I", len(jpeg_data))
                    + struct.pack("<I", width)
                    + struct.pack("<I", height)
                )

                self.client_sock.sendall(header + jpeg_data)

                # Dynamic sleep with jitter to avoid detection
                sleep_ms = FRAME_INTERVAL_MS + random.randint(
                    -FRAME_JITTER_MS, FRAME_JITTER_MS
                )
                time.sleep(max(10, sleep_ms) / 1000.0)

            except (ConnectionError, BrokenPipeError):
                print("[!] Client disconnected")
                break
            except Exception as e:
                print(f"[!] Stream error: {e}")
                break

    def handle_input_commands(self):
        """Receive and process input commands from the client."""
        while self.running and self.client_sock:
            try:
                data = self.client_sock.recv(1024)
                if not data:
                    break

                # Parse command
                # Format: type(1 byte) + event_type/vk(2 bytes) + x(4 bytes) + y(4 bytes)
                if data[0] == 0x01:  # Mouse event
                    event_type = struct.unpack("<H", data[1:3])[0]
                    x = struct.unpack("<I", data[3:7])[0]
                    y = struct.unpack("<I", data[7:11])[0]

                    if event_type == 1:  # Left click
                        inject_mouse_click(x, y, button=0)
                    elif event_type == 2:  # Right click
                        inject_mouse_click(x, y, button=1)
                    elif event_type == 0:  # Mouse move
                        if HAS_WIN_API:
                            abs_x = int(x * 65535 / SCREEN_WIDTH)
                            abs_y = int(y * 65535 / SCREEN_HEIGHT)
                            move_input = INPUT()
                            move_input.type = 0
                            move_input.union.mi.dx = abs_x
                            move_input.union.mi.dy = abs_y
                            move_input.union.mi.dwFlags = (
                                MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
                            )
                            SendInput(
                                1, ctypes.byref(move_input), ctypes.sizeof(INPUT)
                            )

                elif data[0] == 0x02:  # Keyboard event
                    event_type = struct.unpack("<H", data[1:3])[0]
                    vk_code = struct.unpack("<H", data[3:5])[0]
                    if event_type == 0:  # Key down
                        inject_key_press(vk_code)

            except (ConnectionError, BrokenPipeError):
                break
            except Exception as e:
                print(f"[!] Input handler error: {e}")
                break

        print("[*] Input handler stopped")

    def stop(self):
        """Stop the server."""
        self.running = False
        if self.client_sock:
            try:
                self.client_sock.close()
            except:
                pass
        if self.server_sock:
            try:
                self.server_sock.close()
            except:
                pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4444

    host = StealthHost(port)
    try:
        host.start()
    except KeyboardInterrupt:
        print("\n[*] Shutting down...")
        host.stop()
