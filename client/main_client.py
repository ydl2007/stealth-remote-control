#!/usr/bin/env python3
"""
Stealth Remote Control - Client (helper PC)
============================================
Receives screen capture stream from the host (exam PC) via TCP
and sends mouse/keyboard inputs back.

Usage:
  python main_client.py <host_ip> <port>
  python main_client.py 127.0.0.1 3390   # via SSH tunnel (Piano A)
  python main_client.py 192.168.1.100 4444  # direct connection (Piano B)
"""

import socket
import struct
import threading
import time
import io
import tkinter as tk
from PIL import Image, ImageTk
import sys

# Protocol constants
MAGIC_HEADER = b"STRM"
PROTOCOL_VERSION = 1


class RemoteViewer:
    """Displays the remote screen stream and captures mouse/keyboard input."""

    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.sock = None
        self.running = False

        # GUI
        self.root = tk.Tk()
        self.root.title(f"Remote Control - {host}:{port}")
        self.root.configure(bg="black")

        # Canvas for displaying the remote screen
        self.canvas = tk.Canvas(self.root, bg="black", highlightthickness=0)
        self.canvas.pack(fill=tk.BOTH, expand=True)

        # Current image
        self.current_image = None
        self.current_photo = None
        self.canvas_image_id = None

        # Screen dimensions
        self.remote_width = 1920
        self.remote_height = 1080

        # Connection status
        self.status_label = tk.Label(
            self.root,
            text="Connecting...",
            fg="white",
            bg="black",
            font=("Consolas", 10),
        )
        self.status_label.pack(side=tk.BOTTOM, fill=tk.X)

        # FPS counter
        self.frame_count = 0
        self.fps = 0
        self.last_fps_time = time.time()

        # Bind mouse events
        self.canvas.bind("<Button-1>", self.on_mouse_click)
        self.canvas.bind("<B1-Motion>", self.on_mouse_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_mouse_release)
        self.canvas.bind("<Button-3>", self.on_mouse_right_click)
        self.canvas.bind("<Motion>", self.on_mouse_move)
        self.root.bind("<KeyPress>", self.on_key_press)
        self.root.bind("<KeyRelease>", self.on_key_release)

    def connect(self) -> bool:
        """Connect to the remote host."""
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sock.settimeout(10.0)
            self.sock.connect((self.host, self.port))
            self.sock.settimeout(None)  # Back to blocking
            self.status_label.config(text=f"Connected to {self.host}:{self.port}")
            return True
        except Exception as e:
            self.status_label.config(text=f"Connection failed: {e}")
            return False

    def recv_exact(self, n: int) -> bytes:
        """Receive exactly n bytes from the socket."""
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("Connection closed")
            data += chunk
        return data

    def receive_stream(self):
        """Receive and display the screen stream (runs in a thread)."""
        while self.running:
            try:
                # Read frame header: MAGIC(4) + version(4) + data_size(4) + width(4) + height(4)
                header = self.recv_exact(20)

                magic = header[:4]
                if magic != MAGIC_HEADER:
                    # Try to realign
                    continue

                version = struct.unpack("<I", header[4:8])[0]
                data_size = struct.unpack("<I", header[8:12])[0]
                width = struct.unpack("<I", header[12:16])[0]
                height = struct.unpack("<I", header[16:20])[0]

                if data_size > 10 * 1024 * 1024:  # Sanity check: max 10MB
                    continue

                # Read JPEG data
                jpeg_data = self.recv_exact(data_size)

                # Update remote dimensions
                self.remote_width = width
                self.remote_height = height

                # Decode and display
                self.update_image(jpeg_data)

                # FPS counter
                self.frame_count += 1
                now = time.time()
                if now - self.last_fps_time >= 1.0:
                    self.fps = self.frame_count
                    self.frame_count = 0
                    self.last_fps_time = now
                    self.root.after(0, self.update_fps_display)

            except ConnectionError:
                self.status_label.config(text="Connection lost. Reconnecting...")
                break
            except Exception as e:
                if self.running:
                    self.status_label.config(text=f"Stream error: {e}")
                break

    def update_image(self, jpeg_data: bytes):
        """Update the displayed image (called from stream thread)."""
        try:
            img = Image.open(io.BytesIO(jpeg_data))

            # Resize to fit window if needed
            window_width = self.canvas.winfo_width()
            window_height = self.canvas.winfo_height()
            if window_width > 50 and window_height > 50:
                img = img.resize((window_width, window_height), Image.LANCZOS)

            self.current_image = img
            self.current_photo = ImageTk.PhotoImage(img)

            def update_canvas():
                if self.canvas_image_id:
                    self.canvas.itemconfig(self.canvas_image_id, image=self.current_photo)
                else:
                    self.canvas_image_id = self.canvas.create_image(
                        0, 0, anchor=tk.NW, image=self.current_photo
                    )

            self.root.after(0, update_canvas)

        except Exception as e:
            pass  # Skip corrupted frames

    def update_fps_display(self):
        """Update the FPS display."""
        self.status_label.config(
            text=f"Connected to {self.host}:{self.port} | FPS: {self.fps}"
        )

    def send_mouse_event(self, event_type: int, x: int, y: int):
        """Send mouse event to the host."""
        if not self.sock:
            return

        # Convert canvas coordinates to remote screen coordinates
        canvas_width = self.canvas.winfo_width()
        canvas_height = self.canvas.winfo_height()
        if canvas_width == 0 or canvas_height == 0:
            return

        remote_x = int(x * self.remote_width / canvas_width)
        remote_y = int(y * self.remote_height / canvas_height)

        # Clamp coordinates
        remote_x = max(0, min(remote_x, self.remote_width - 1))
        remote_y = max(0, min(remote_y, self.remote_height - 1))

        packet = struct.pack("<BHHI", 0x01, event_type, remote_x, remote_y)
        try:
            self.sock.sendall(packet)
        except:
            pass

    def send_key_event(self, event_type: int, key_code: int):
        """Send keyboard event to the host."""
        if not self.sock:
            return

        packet = struct.pack("<BHH", 0x02, event_type, key_code)
        try:
            self.sock.sendall(packet)
        except:
            pass

    # Mouse event handlers
    def on_mouse_click(self, event):
        self.send_mouse_event(1, event.x, event.y)  # type 1 = left click

    def on_mouse_drag(self, event):
        self.send_mouse_event(0, event.x, event.y)  # type 0 = move (dragging)

    def on_mouse_release(self, event):
        self.send_mouse_event(3, event.x, event.y)  # type 3 = left release

    def on_mouse_right_click(self, event):
        self.send_mouse_event(2, event.x, event.y)  # type 2 = right click

    def on_mouse_move(self, event):
        self.send_mouse_event(0, event.x, event.y)  # type 0 = move

    def on_key_press(self, event):
        if event.keysym == "Escape":
            self.running = False
            self.root.quit()
        else:
            # Convert tk keycode to Windows VK code if possible
            vk = self.tk_to_vk(event)
            if vk:
                self.send_key_event(0, vk)  # type 0 = key down

    def on_key_release(self, event):
        vk = self.tk_to_vk(event)
        if vk:
            self.send_key_event(1, vk)  # type 1 = key up

    @staticmethod
    def tk_to_vk(event) -> int:
        """Convert tkinter key event to approximate Windows virtual key code."""
        # Mapping for common keys
        key_map = {
            "a": 0x41, "b": 0x42, "c": 0x43, "d": 0x44,
            "e": 0x45, "f": 0x46, "g": 0x47, "h": 0x48,
            "i": 0x49, "j": 0x4A, "k": 0x4B, "l": 0x4C,
            "m": 0x4D, "n": 0x4E, "o": 0x4F, "p": 0x50,
            "q": 0x51, "r": 0x52, "s": 0x53, "t": 0x54,
            "u": 0x55, "v": 0x56, "w": 0x57, "x": 0x58,
            "y": 0x59, "z": 0x5A,
            "0": 0x30, "1": 0x31, "2": 0x32, "3": 0x33,
            "4": 0x34, "5": 0x35, "6": 0x36, "7": 0x37,
            "8": 0x38, "9": 0x39,
            "Return": 0x0D, "BackSpace": 0x08, "Tab": 0x09,
            "space": 0x20, "Shift_L": 0xA0, "Shift_R": 0xA1,
            "Control_L": 0xA2, "Control_R": 0xA3,
            "Up": 0x26, "Down": 0x28, "Left": 0x25, "Right": 0x27,
            "Escape": 0x1B, "Delete": 0x2E, "Home": 0x24, "End": 0x23,
        }
        return key_map.get(event.keysym, 0)

    def run(self):
        """Main loop."""
        if not self.connect():
            self.status_label.config(text="Failed to connect. Retrying in 5s...")
            self.root.after(5000, self.retry_connect)

        self.running = True
        stream_thread = threading.Thread(target=self.receive_stream, daemon=True)
        stream_thread.start()

        # Handle window close
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

        self.root.mainloop()

    def retry_connect(self):
        """Retry connection."""
        if self.connect():
            self.running = True
            stream_thread = threading.Thread(target=self.receive_stream, daemon=True)
            stream_thread.start()
        else:
            self.root.after(5000, self.retry_connect)

    def on_close(self):
        """Clean up on window close."""
        self.running = False
        if self.sock:
            try:
                self.sock.close()
            except:
                pass
        self.root.quit()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python main_client.py <host_ip> <port>")
        print("  Default: python main_client.py 127.0.0.1 3390")
        sys.exit(1)

    host = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 3390

    viewer = RemoteViewer(host, port)
    viewer.run()
