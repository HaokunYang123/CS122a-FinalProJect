#!/usr/bin/env python3
# ============================================================================
#  Laptop-side receiver for the Pico smart-camera image.
#
#  WHAT IT DOES
#    Listens on TCP port 4242. When the Pico connects and sends the image,
#    it reads exactly 153600 bytes (76800 pixels x 2 bytes, RGB565), saves
#    the raw bytes, and (if Pillow is installed) decodes them to a PNG you
#    can actually look at.
#
#  RUN IT
#    python3 receiver.py
#    (Leave it running. Then press the button on the Pico to send.)
#
#  REQUIREMENTS
#    - Python 3. Raw save works with nothing extra.
#    - For the PNG: pip install pillow   (optional but recommended)
#
#  NOTES
#    - WIDTH/HEIGHT must match what the FPGA sends (320x240).
#    - Pixels arrive little-endian (Pico is little-endian): each 16-bit pixel
#      is low-byte-first on the wire. This script handles that.
#    - PORT must match TCP_PORT in the Pico code (4242).
# ============================================================================

import socket
import struct

HOST = "0.0.0.0"      # listen on all interfaces (any of your laptop's IPs)
PORT = 4242           # must match TCP_PORT on the Pico
WIDTH = 320
HEIGHT = 240
PIXELS = WIDTH * HEIGHT          # 76800
IMAGE_BYTES = PIXELS * 2         # 153600

RAW_OUT = "frame.bin"
PNG_OUT = "frame.png"


def recv_exact(conn, n):
    """Read exactly n bytes, or fewer if the connection closes early."""
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            break          # peer closed
        buf.extend(chunk)
    return bytes(buf)


def rgb565_to_png(data):
    """Decode little-endian RGB565 bytes into a PNG. Returns True on success."""
    try:
        from PIL import Image
    except ImportError:
        print("Pillow not installed; skipping PNG. (pip install pillow)")
        return False

    img = Image.new("RGB", (WIDTH, HEIGHT))
    px = img.load()
    # each pixel = 2 bytes, little-endian: value = lo | (hi << 8)
    for i in range(PIXELS):
        lo = data[2 * i]
        hi = data[2 * i + 1]
        v = lo | (hi << 8)
        r = (v >> 11) & 0x1F
        g = (v >> 5) & 0x3F
        b = v & 0x1F
        # scale 5/6/5 bits up to 8 bits
        r8 = (r << 3) | (r >> 2)
        g8 = (g << 2) | (g >> 4)
        b8 = (b << 3) | (b >> 2)
        px[i % WIDTH, i // WIDTH] = (r8, g8, b8)
    img.save(PNG_OUT)
    print("Saved decoded image to", PNG_OUT)
    return True


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(1)
    print(f"Listening on {HOST}:{PORT} ... waiting for the Pico.")
    print("Press Ctrl-C to stop.\n")

    try:
        while True:
            conn, addr = srv.accept()
            print("Connection from", addr)
            data = recv_exact(conn, IMAGE_BYTES)
            conn.close()

            print(f"Received {len(data)} bytes (expected {IMAGE_BYTES}).")
            if len(data) != IMAGE_BYTES:
                print("WARNING: short read — image may be incomplete.")

            with open(RAW_OUT, "wb") as f:
                f.write(data)
            print("Saved raw bytes to", RAW_OUT)

            # quick sanity peek at the first few pixels (little-endian uint16)
            if len(data) >= 6:
                p = struct.unpack("<3H", data[:6])
                print("first 3 pixels (hex):", " ".join(f"{x:04x}" for x in p))

            if len(data) == IMAGE_BYTES:
                rgb565_to_png(data)
            else:
                print("Skipping PNG decode (incomplete data).")
            
            print("\nWaiting for the next image...\n")
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        srv.close()


if __name__ == "__main__":
    main()