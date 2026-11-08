#!/usr/bin/env python3
"""Package rendered PNG sizes into a macOS ICNS file."""

import struct
import sys
from pathlib import Path


source = Path(sys.argv[1])
destination = Path(sys.argv[2])
types = [
    (16, b"icp4"), (32, b"icp5"), (64, b"icp6"), (128, b"ic07"),
    (256, b"ic08"), (512, b"ic09"), (1024, b"ic10"),
    (32, b"ic11"), (64, b"ic12"), (256, b"ic13"), (512, b"ic14"),
]
chunks = []
for size, code in types:
    png = (source / f"{size}.png").read_bytes()
    if png[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", png[16:24]) != (size, size):
        raise ValueError(f"Invalid {size}×{size} PNG")
    chunks.append(code + struct.pack(">I", len(png) + 8) + png)
payload = b"".join(chunks)
destination.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
