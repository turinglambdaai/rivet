#!/usr/bin/env python3
"""Create a deterministic Windows icon for the packaged WinUI regression only.

Run inside the disposable examples/taskboard working tree on Windows CI.
The checked-in sample remains intentionally unbranded by default.
"""
from pathlib import Path
import struct

width = height = 16
# A solid, opaque test color; little-endian 32-bit BGRA DIB pixels.
pixels = bytes((0xBA, 0x73, 0x19, 0xFF)) * (width * height)
and_mask = bytes(((width + 31) // 32) * 4 * height)
bitmap = struct.pack(
    "<IiiHHIIiiII",
    40, width, height * 2, 1, 32, 0,
    len(pixels) + len(and_mask), 0, 0, 0, 0,
) + pixels + and_mask
icon = (
    struct.pack("<HHH", 0, 1, 1)
    + struct.pack("<BBBBHHII", width, height, 0, 0, 1, 32, len(bitmap), 22)
    + bitmap
)
icon_path = Path("assets/ci-winui-icon.ico")
icon_path.parent.mkdir(parents=True, exist_ok=True)
icon_path.write_bytes(icon)

config_path = Path("rivet.rktd")
config = config_path.read_text(encoding="utf-8")
prefix = "#hasheq("
if config.count(prefix) != 1 or "windows-icon" in config:
    raise SystemExit("Taskboard's icon fixture expects an unbranded #hasheq configuration")
config_path.write_text(
    config.replace(prefix, prefix + '(windows-icon . "assets/ci-winui-icon.ico") ', 1),
    encoding="utf-8",
)
print(f"Prepared packaged WinUI icon regression fixture: {icon_path}")
