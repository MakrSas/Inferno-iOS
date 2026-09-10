#!/usr/bin/env python3
"""Writes the modified container back into the guest disk, changed blocks only.

Reading both sides and writing just the differences keeps the window in which
the master image is inconsistent down to seconds, and avoids moving 34 GB.
"""
import sys

DISK, CONTAINER = sys.argv[1], sys.argv[2]
OFFSET, LENGTH = 24576, 34359693312
CHUNK = 4 << 20

changed = 0
with open(CONTAINER, "rb") as src, open(DISK, "r+b") as dst:
    done = 0
    while done < LENGTH:
        want = min(CHUNK, LENGTH - done)
        new = src.read(want)
        if not new:
            break
        dst.seek(OFFSET + done)
        old = dst.read(len(new))
        if old != new:
            dst.seek(OFFSET + done)
            dst.write(new)
            changed += len(new)
        done += len(new)
    dst.flush()
print(f"переписано {changed >> 20} МБ из {LENGTH >> 30} ГБ")
