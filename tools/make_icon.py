"""Draws the app icon (1024x1024 RGB PNG, no alpha, as iOS requires) with the stdlib only.

A green gradient with three rising bars. Run it from the repo root:
  python -I tools/make_icon.py
"""
import struct
import zlib
from pathlib import Path

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "App/Finance/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

TOP, BOTTOM = (16, 92, 64), (22, 150, 98)  # dark to light green
BAR = (245, 250, 247)
BARS = [  # (left, width, height) in pixels; bars stand on a common baseline
    (262, 140, 250),
    (442, 140, 400),
    (622, 140, 560),
]
BASELINE = 800
RADIUS = 44


def inside_rounded(x, y, left, top, right, bottom, r):
    if not (left <= x < right and top <= y < bottom):
        return False
    cx = min(max(x, left + r), right - r - 1)
    cy = min(max(y, top + r), bottom - r - 1)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def pixel(x, y):
    for left, width, height in BARS:
        if inside_rounded(x, y, left, BASELINE - height, left + width, BASELINE, RADIUS):
            return BAR
    t = y / (SIZE - 1)
    return tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))


def main():
    rows = bytearray()
    for y in range(SIZE):
        rows.append(0)  # PNG filter: none
        for x in range(SIZE):
            rows.extend(pixel(x, y))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(png)
    print(f"wrote {OUT} ({len(png) // 1024} KB)")


if __name__ == "__main__":
    main()
