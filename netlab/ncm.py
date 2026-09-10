#!/usr/bin/env python3
"""Switches the device into CDC-NCM mode and brings that interface up.

Mode 3 is what `USBMUXD_DEFAULT_DEVICE_MODE=3` asks for: the device re-enumerates
with a fifth configuration, "PTP + Apple Mobile Device + NCM", whose CDC Data
interface carries Ethernet inside NCM transfer blocks. This is the path macOS
uses for internet sharing, and the one the guest is expected to bring up on its
own side.
"""

import struct
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from tcpusb import (DESC_CONFIG, DESC_DEVICE, RET_SUCCESS, USB_TOKEN_IN,
                    USB_TOKEN_OUT, Link, UsbError, listen)

SOCK = "/tmp/iusb.sock"

VENDOR_IN = 0xC0
REQ_GET_MODE = 0x45
REQ_SET_MODE = 0x52
MODE_NCM = 3

CLASS_IN = 0xA1
CLASS_OUT = 0x21
NCM_GET_NTB_PARAMETERS = 0x80
NCM_SET_NTB_INPUT_SIZE = 0x86
NCM_GET_NTB_INPUT_SIZE = 0x85

XFER = {0: "control", 1: "isoc", 2: "bulk", 3: "interrupt"}


def parse_config(raw):
    i = 0
    while i + 1 < len(raw):
        length = raw[i]
        if length == 0:
            break
        yield length, raw[i + 1], raw[i:i + length]
        i += length


def describe(link, index):
    """Prints one configuration and returns (value, control_iface, data_iface, alts, eps)."""
    head = link.get_descriptor(DESC_CONFIG, index, 9)
    total = int.from_bytes(head[2:4], "little")
    raw = link.get_descriptor(DESC_CONFIG, index, total)
    value = raw[5]
    print(f"  конфигурация value={value} «{link.string(raw[6])}»")

    control_iface = data_iface = None
    alts = {}
    endpoints = {}
    current = None
    for length, dtype, d in parse_config(raw):
        if dtype == 0x04 and length >= 9:
            num, alt, neps, cls, sub, proto = d[2], d[3], d[4], d[5], d[6], d[7]
            current = (num, alt)
            print(f"    интерфейс {num} alt {alt}: {cls:02x}/{sub:02x}/{proto:02x}, эндпоинтов {neps}")
            if cls == 0x02 and sub == 0x0D:
                control_iface = num
            if cls == 0x0A:
                data_iface = num
                alts.setdefault(num, []).append(alt)
        elif dtype == 0x05 and length >= 7 and current:
            addr, attr = d[2], d[3]
            mps = int.from_bytes(d[4:6], "little")
            print(f"        эндпоинт 0x{addr:02x} {XFER.get(attr & 3, '?')} mps={mps}")
            endpoints.setdefault(current, []).append(addr)
        elif dtype == 0x24:
            print(f"        CS_INTERFACE подтип 0x{d[2]:02x}: {d.hex()}")
    return value, control_iface, data_iface, alts, endpoints


def main():
    srv = listen(SOCK)
    print(f"Слушаю {SOCK}…")
    conn, _ = srv.accept()
    print("Эмулятор подключился.")
    time.sleep(1.0)
    link = Link(conn)
    link.reset()

    mode = link.control(VENDOR_IN, REQ_GET_MODE, 0, 0, 4)
    print(f"GET_MODE → {mode.hex()}")
    if not mode.startswith(b"\x05"):
        print(f"→ SET_MODE {MODE_NCM}")
        link.control(VENDOR_IN, REQ_SET_MODE, 0, MODE_NCM, 1)
        try:
            conn.close()
        except OSError:
            pass
        srv.settimeout(60)
        conn, _ = srv.accept()
        print("   переподключился")
        time.sleep(1.5)
        link = Link(conn)
        link.reset()
        print(f"GET_MODE → {link.control(VENDOR_IN, REQ_GET_MODE, 0, 0, 4).hex()}")

    dev = link.get_descriptor(DESC_DEVICE, 0, 18)
    target = None
    for index in range(dev[17]):
        head = link.get_descriptor(DESC_CONFIG, index, 9)
        total = int.from_bytes(head[2:4], "little")
        raw = link.get_descriptor(DESC_CONFIG, index, total)
        if b"NCM" in link.string(raw[6]).encode():
            target = index
    if target is None:
        print("NCM-конфигурации нет")
        return

    print(f"\n=== конфигурация с NCM (индекс {target}) ===")
    value, control_iface, data_iface, alts, endpoints = describe(link, target)

    link.set_configuration(value)
    print(f"\nSET_CONFIGURATION({value})")

    if control_iface is not None:
        try:
            params = link.control(CLASS_IN, NCM_GET_NTB_PARAMETERS, 0, control_iface, 28)
            length, formats, in_max, in_div, in_rem, in_align = struct.unpack("<HHIHHH", params[:14])
            print(f"NTB-параметры: длина {length}, форматы {formats:#06x}, "
                  f"IN max {in_max}, делитель {in_div}, остаток {in_rem}, выравнивание {in_align}")
        except UsbError as exc:
            print(f"GET_NTB_PARAMETERS: {exc}")

    data_alts = sorted(a for a in alts.get(data_iface, []) if a)
    for alt in data_alts:
        link.set_interface(data_iface, alt)
        eps = endpoints.get((data_iface, alt), [])
        ep_in = next((e & 0xF for e in eps if e & 0x80), None)
        ep_out = next((e for e in eps if not e & 0x80), None)
        print(f"\nSET_INTERFACE({data_iface}, alt {alt}): IN ep{ep_in}, OUT ep{ep_out}")
        if ep_in is None:
            continue
        frames = 0
        deadline = time.time() + 20
        while time.time() < deadline:
            status, body = link.xfer(USB_TOKEN_IN, ep_in, length=2048, retries=1, delay=0)
            if status == RET_SUCCESS and body:
                frames += 1
                print(f"  NCM ← {len(body)} б: {body[:48].hex()}")
                if frames > 8:
                    break
            else:
                time.sleep(0.01)
        print(f"  за 20 с получено блоков: {frames}")
        if frames:
            break


if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, KeyboardInterrupt) as exc:
        print(f"\nЗавершено: {exc}")
    except UsbError as exc:
        print(f"\nUSB: {exc}")
