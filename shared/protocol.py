"""
Shared protocol definition for Stealth Remote Control.

This file defines the wire protocol between Host (exam PC) and Client (helper PC).
Both sides must use the same protocol version and packet structure.

Protocol: TCP streaming
All multi-byte values are little-endian.

Frame packet (Host -> Client):
  [MAGIC: 4 bytes = "STRM"]
  [VERSION: 4 bytes = uint32]
  [DATA_SIZE: 4 bytes = uint32]  # size of JPEG data
  [WIDTH: 4 bytes = uint32]      # screen width
  [HEIGHT: 4 bytes = uint32]     # screen height
  [JPEG_DATA: DATA_SIZE bytes]

Input packet (Client -> Host):
  Mouse event:
    [TYPE: 1 byte = 0x01]
    [EVENT_TYPE: 2 bytes = uint16]
        0 = mouse move
        1 = left click (down + up at position)
        2 = right click
        3 = left release
    [X: 4 bytes = uint32]
    [Y: 4 bytes = uint32]
  Keyboard event:
    [TYPE: 1 byte = 0x02]
    [EVENT_TYPE: 2 bytes = uint16]
        0 = key down
        1 = key up
    [VK_CODE: 2 bytes = uint16]  # Windows virtual key code
"""

import struct

MAGIC_HEADER = b"STRM"
PROTOCOL_VERSION = 1

# Mouse event types
MOUSE_MOVE = 0
MOUSE_LEFT_CLICK = 1
MOUSE_RIGHT_CLICK = 2
MOUSE_LEFT_RELEASE = 3

# Keyboard event types
KEY_DOWN = 0
KEY_UP = 1

# Packet type identifiers
TYPE_MOUSE = 0x01
TYPE_KEYBOARD = 0x02

# Frame header size: 4 + 4 + 4 + 4 + 4 = 20 bytes
FRAME_HEADER_SIZE = 20


def create_frame_header(data_size: int, width: int, height: int) -> bytes:
    """Create a frame header for screen capture packets."""
    return struct.pack(
        "<5I",
        int.from_bytes(MAGIC_HEADER, "little"),
        PROTOCOL_VERSION,
        data_size,
        width,
        height,
    )


def create_mouse_packet(event_type: int, x: int, y: int) -> bytes:
    """Create a mouse input packet."""
    return struct.pack("<BHHI", TYPE_MOUSE, event_type, x, y)


def create_keyboard_packet(event_type: int, vk_code: int) -> bytes:
    """Create a keyboard input packet."""
    return struct.pack("<BHH", TYPE_KEYBOARD, event_type, vk_code)


def parse_frame_header(data: bytes) -> dict:
    """Parse a frame header from received data."""
    if len(data) < FRAME_HEADER_SIZE:
        raise ValueError(f"Header too short: {len(data)} < {FRAME_HEADER_SIZE}")

    magic = data[:4]
    if magic != MAGIC_HEADER:
        raise ValueError(f"Invalid magic: {magic}")

    version = struct.unpack("<I", data[4:8])[0]
    data_size = struct.unpack("<I", data[8:12])[0]
    width = struct.unpack("<I", data[12:16])[0]
    height = struct.unpack("<I", data[16:20])[0]

    return {
        "magic": magic,
        "version": version,
        "data_size": data_size,
        "width": width,
        "height": height,
    }


def parse_input_packet(data: bytes) -> dict:
    """Parse an input packet from received data."""
    if len(data) < 3:
        raise ValueError(f"Packet too short: {len(data)} < 3")

    packet_type = data[0]

    if packet_type == TYPE_MOUSE:
        if len(data) < 11:
            raise ValueError(f"Mouse packet too short: {len(data)} < 11")
        return {
            "type": "mouse",
            "event_type": struct.unpack("<H", data[1:3])[0],
            "x": struct.unpack("<I", data[3:7])[0],
            "y": struct.unpack("<I", data[7:11])[0],
        }
    elif packet_type == TYPE_KEYBOARD:
        if len(data) < 5:
            raise ValueError(f"Keyboard packet too short: {len(data)} < 5")
        return {
            "type": "keyboard",
            "event_type": struct.unpack("<H", data[1:3])[0],
            "vk_code": struct.unpack("<H", data[3:5])[0],
        }
    else:
        raise ValueError(f"Unknown packet type: {packet_type}")
