#!/usr/bin/env python3
"""Enumerates the emulated device and prints what its USB configurations hold.

This answers the only real unknown in the plan: whether the interface behind
usbmuxd's "device mode 3" is plain CDC-NCM or MBIM, and which endpoints carry
its data.
"""

import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from tcpusb import (DESC_CONFIG, DESC_DEVICE, Link, UsbError, listen)

SOCK = "/tmp/iusb.sock"

CLASS_NAMES = {
    0x00: "по интерфейсам", 0x02: "CDC Communications", 0x0A: "CDC Data",
    0x03: "HID", 0x08: "Mass Storage", 0x09: "Hub", 0xEF: "Miscellaneous",
    0xFF: "Vendor Specific",
}
CDC_SUBCLASS = {
    0x02: "ACM", 0x06: "Ethernet (ECM)", 0x0D: "NCM", 0x0E: "MBIM",
}
XFER = {0: "control", 1: "isoc", 2: "bulk", 3: "interrupt"}


def parse_config(raw):
    """Walks the configuration descriptor and yields (offset, bLength, bType, bytes)."""
    i = 0
    while i + 1 < len(raw):
        length = raw[i]
        if length == 0:
            break
        yield i, length, raw[i + 1], raw[i:i + length]
        i += length


def show_config(link, index):
    head = link.get_descriptor(DESC_CONFIG, index, 9)
    if len(head) < 9:
        print(f"  конфигурация {index}: короткий дескриптор ({len(head)} б)")
        return
    total = int.from_bytes(head[2:4], "little")
    raw = link.get_descriptor(DESC_CONFIG, index, total)
    n_ifaces, value, s_index, attrs, power = raw[4], raw[5], raw[6], raw[7], raw[8]
    name = link.string(s_index)
    print(f"\n  === Конфигурация #{index}: bConfigurationValue={value}, "
          f"интерфейсов {n_ifaces}, {total} б{', ' + name if name else ''} ===")

    for _, length, dtype, d in parse_config(raw):
        if dtype == 0x04 and length >= 9:                      # INTERFACE
            num, alt, neps, cls, sub, proto, si = d[2], d[3], d[4], d[5], d[6], d[7], d[8]
            label = CLASS_NAMES.get(cls, f"0x{cls:02x}")
            extra = CDC_SUBCLASS.get(sub, f"0x{sub:02x}") if cls in (0x02, 0x0A) else f"0x{sub:02x}"
            iname = link.string(si)
            print(f"    интерфейс {num} alt {alt}: класс {cls:#04x} ({label}), "
                  f"подкласс {extra}, протокол {proto:#04x}, эндпоинтов {neps}"
                  f"{', ' + iname if iname else ''}")
        elif dtype == 0x05 and length >= 7:                    # ENDPOINT
            addr, attr = d[2], d[3]
            mps = int.from_bytes(d[4:6], "little")
            direction = "IN" if addr & 0x80 else "OUT"
            print(f"        эндпоинт 0x{addr:02x} ({direction} {addr & 0xF}): "
                  f"{XFER.get(attr & 3, '?')}, wMaxPacketSize={mps}")
        elif dtype == 0x24:                                    # CS_INTERFACE
            sub = d[2] if length > 2 else 0
            hint = {0x00: "Header", 0x06: "Union", 0x0F: "Ethernet",
                    0x1A: "NCM", 0x1B: "MBIM", 0x1C: "MBIM Extended"}.get(sub, "")
            print(f"        CS_INTERFACE подтип 0x{sub:02x} {hint} {d.hex()}")
        elif dtype == 0x0B and length >= 8:                    # IAD
            first, count, cls, sub, proto = d[2], d[3], d[4], d[5], d[6]
            print(f"    [объединение интерфейсов {first}..{first + count - 1}: "
                  f"класс {cls:#04x}, подкласс {sub:#04x}, протокол {proto:#04x}]")


def main():
    srv = listen(SOCK)
    print(f"Слушаю {SOCK}, жду подключения эмулятора…")
    conn, _ = srv.accept()
    print("Подключился. Даю шине устояться…")
    time.sleep(1.0)

    link = Link(conn, verbose="-v" in sys.argv)
    link.reset()

    dev = link.get_descriptor(DESC_DEVICE, 0, 18)
    if len(dev) < 18:
        print(f"Дескриптор устройства короткий: {dev.hex()}")
        return
    vid = int.from_bytes(dev[8:10], "little")
    pid = int.from_bytes(dev[10:12], "little")
    n_configs = dev[17]
    print(f"\nУстройство: VID {vid:#06x} PID {pid:#06x}, "
          f"класс {dev[4]:#04x}/{dev[5]:#04x}/{dev[6]:#04x}, "
          f"bMaxPacketSize0={dev[7]}, конфигураций {n_configs}")
    for label, idx in (("производитель", dev[14]), ("продукт", dev[15]), ("серийник", dev[16])):
        value = link.string(idx)
        if value:
            print(f"  {label}: {value}")

    for i in range(n_configs):
        try:
            show_config(link, i)
        except UsbError as exc:
            print(f"  конфигурация {i}: {exc}")

    try:
        print(f"\nТекущая bConfigurationValue: {link.get_configuration()}")
    except UsbError as exc:
        print(f"\nGET_CONFIGURATION: {exc}")


if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, KeyboardInterrupt) as exc:
        print(f"\nОборвалось: {exc}")
