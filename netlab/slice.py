#!/usr/bin/env python3
"""Copies the APFS container out of the guest disk, keeping holes as holes.

macOS attaches raw images as 512-byte-sector devices, and this disk's partition
table is written for 4096-byte sectors, so the container is invisible through
it. Handing macOS the bare container sidesteps the partition table entirely:
APFS records its own block size in the superblock.
"""
import os, sys

SRC, DST = sys.argv[1], sys.argv[2]
OFFSET, LENGTH = 24576, 34359693312
CHUNK = 4 << 20
ZERO = bytes(CHUNK)

with open(SRC, "rb") as src, open(DST, "wb") as dst:
    dst.truncate(LENGTH)
    src.seek(OFFSET)
    done = 0
    while done < LENGTH:
        want = min(CHUNK, LENGTH - done)
        data = src.read(want)
        if not data:
            break
        if data != ZERO[:len(data)]:
            dst.seek(done)
            dst.write(data)
        done += len(data)
        if done % (2 << 30) == 0:
            print(f"  {done >> 30} ГБ", flush=True)
print("готово")
