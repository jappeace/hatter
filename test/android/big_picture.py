"""Writes a PNG of noise, 4600 pixels square and about 85 MB, to argv[1]."""
import os
import struct
import sys
import zlib

SIDE = 4600


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


rows = b"".join(b"\0" + os.urandom(SIDE * 4) for _ in range(SIDE))
with open(sys.argv[1], "wb") as out:
    out.write(b"\x89PNG\r\n\x1a\n")
    out.write(chunk(b"IHDR", struct.pack(">IIBBBBB", SIDE, SIDE, 8, 6, 0, 0, 0)))
    # In chunks, as encoders write it: Android 11's libpng won't read one
    # larger than it reckons the picture needs, and noise only grows.
    data = zlib.compress(rows, 1)
    for start in range(0, len(data), 1 << 16):
        out.write(chunk(b"IDAT", data[start:start + (1 << 16)]))
    out.write(chunk(b"IEND", b""))
