#!/usr/bin/env python3
"""Does the usbmux version handshake and then checks what the guest wakes up.

The question this answers: is a live mux link enough for iOS to activate its
"Apple USB Ethernet" function, or does that need the full lockdown pairing?

The mux protocol is usbmuxd's `struct mux_header`: 32-bit protocol, 32-bit total
length, and — from version 2 — a 0xfeedface magic plus 16-bit tx/rx sequence
numbers, all big-endian. Version 1 packets carry only the first eight bytes,
which is what the opening exchange uses.
"""

import struct
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from tcpusb import (DESC_DEVICE, RET_SUCCESS, USB_TOKEN_IN, USB_TOKEN_OUT,
                    Link, UsbError, listen)

SOCK = "/tmp/iusb.sock"

CONFIG_VALUE = 4
MUX_EP_OUT = 4          # 0x04
MUX_EP_IN = 5           # 0x85
ETH_INTERFACE = 2
ETH_EP_IN = 6           # 0x86

MUX_PROTO_VERSION = 0
MUX_PROTO_CONTROL = 1
MUX_PROTO_SETUP = 2
MUX_PROTO_TCP = 6
MUX_MAGIC = 0xFEEDFACE

PROTO_NAMES = {0: "VERSION", 1: "CONTROL", 2: "SETUP", 6: "TCP"}


class Mux:
    def __init__(self, link):
        self.link = link
        self.version = 0
        self.tx_seq = 0
        self.rx_seq = 0xFFFF

    @property
    def header_size(self):
        return 8 if self.version < 2 else 16

    def send(self, proto, header=b"", payload=b""):
        total = self.header_size + len(header) + len(payload)
        if self.version < 2:
            head = struct.pack("!II", proto, total)
        else:
            if proto == MUX_PROTO_SETUP:
                self.tx_seq, self.rx_seq = 0, 0xFFFF
            head = struct.pack("!IIIHH", proto, total, MUX_MAGIC, self.tx_seq, self.rx_seq)
            self.tx_seq += 1
        status, _ = self.link.xfer(USB_TOKEN_OUT, MUX_EP_OUT, head + header + payload,
                                   retries=100, delay=0.01)
        return status == RET_SUCCESS

    def recv(self, timeout=5.0):
        """Reads one mux packet, reassembling across bulk transfers."""
        deadline = time.time() + timeout
        buf = b""
        while time.time() < deadline:
            status, chunk = self.link.xfer(USB_TOKEN_IN, MUX_EP_IN, length=512,
                                           retries=1, delay=0)
            if status != RET_SUCCESS or not chunk:
                time.sleep(0.01)
                continue
            buf += chunk
            if len(buf) < 8:
                continue
            proto, total = struct.unpack("!II", buf[:8])
            # From version 2 the device numbers its own packets; echoing that
            # number back as rx_seq is what keeps a session alive.
            if self.version >= 2 and len(buf) >= 14:
                self.rx_seq = struct.unpack("!H", buf[12:14])[0]
            while len(buf) < total and time.time() < deadline:
                status, more = self.link.xfer(USB_TOKEN_IN, MUX_EP_IN, length=512,
                                              retries=1, delay=0)
                if status == RET_SUCCESS and more:
                    buf += more
                else:
                    time.sleep(0.01)
            return proto, buf[:total]
        return None, b""


def main():
    srv = listen(SOCK)
    print(f"Слушаю {SOCK}…")
    conn, _ = srv.accept()
    print("Эмулятор подключился.")
    time.sleep(1.0)

    link = Link(conn)
    link.reset()
    dev = link.get_descriptor(DESC_DEVICE, 0, 18)
    print(f"Устройство {int.from_bytes(dev[8:10], 'little'):#06x}:"
          f"{int.from_bytes(dev[10:12], 'little'):#06x}")

    link.set_configuration(CONFIG_VALUE)
    print(f"Конфигурация {CONFIG_VALUE} выбрана")

    mux = Mux(link)
    version_body = struct.pack("!III", 2, 0, 0)
    print("→ VERSION (major 2)")
    if not mux.send(MUX_PROTO_VERSION, version_body):
        print("не удалось отправить VERSION")
        return

    proto, packet = mux.recv(timeout=8)
    if proto is None:
        print("← ответа на VERSION нет")
        return
    print(f"← {PROTO_NAMES.get(proto, proto)} {len(packet)} б: {packet.hex()}")
    if proto == MUX_PROTO_VERSION and len(packet) >= 20:
        major, minor, _ = struct.unpack("!III", packet[8:20])
        mux.version = min(major, 2)
        print(f"   версия устройства {major}.{minor} → работаем по {mux.version}")

    if mux.version >= 2:
        print("→ SETUP (0x07)")
        mux.send(MUX_PROTO_SETUP, b"", b"\x07")

    # Only now, with the mux link live, wake the ethernet interface: at alt 0 it
    # has no endpoints at all, so the earlier probe could not have worked.
    for alt in (1, 2):
        link.set_interface(ETH_INTERFACE, alt)
        print(f"→ SET_INTERFACE({ETH_INTERFACE}, alt {alt})")
        time.sleep(2)

    print("\nСмотрю, что придёт по mux и поднимется ли Ethernet…")
    deadline = time.time() + 40
    eth_frames = 0
    while time.time() < deadline:
        proto, packet = mux.recv(timeout=1.0)
        if proto is not None:
            print(f"  mux ← {PROTO_NAMES.get(proto, proto)} {len(packet)} б: {packet[:64].hex()}")
        status, body = link.xfer(USB_TOKEN_IN, ETH_EP_IN, length=1516, retries=1, delay=0)
        if status == RET_SUCCESS and len(body) > 2:
            eth_frames += 1
            print(f"  ETH ← кадр {len(body) - 2} б, тип {body[14:16].hex()}")
    print(f"\nКадров с Ethernet-эндпоинта: {eth_frames}")


if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, KeyboardInterrupt) as exc:
        print(f"\nЗавершено: {exc}")
    except UsbError as exc:
        print(f"\nUSB: {exc}")
