#!/usr/bin/env python3
"""Opens a usbmux TCP channel to lockdownd and asks it who it is.

usbmux carries a cut-down TCP inside `MUX_PROTO_TCP` packets: a standard 20-byte
header, big-endian, with the window scaled down by eight bits. lockdownd listens
on device port 62078 and speaks length-prefixed XML property lists.

Getting a QueryType answer back is the checkpoint that says the whole pairing
path is reachable.
"""

import plistlib
import struct
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from muxprobe import (CONFIG_VALUE, ETH_INTERFACE, MUX_PROTO_SETUP,
                      MUX_PROTO_TCP, MUX_PROTO_VERSION, Mux)
from tcpusb import DESC_DEVICE, Link, UsbError, listen

SOCK = "/tmp/iusb.sock"
LOCKDOWN_PORT = 62078

TH_FIN, TH_SYN, TH_RST, TH_PSH, TH_ACK = 0x01, 0x02, 0x04, 0x08, 0x10


def flag_names(flags):
    names = [n for bit, n in ((TH_FIN, "FIN"), (TH_SYN, "SYN"), (TH_RST, "RST"),
                              (TH_PSH, "PSH"), (TH_ACK, "ACK")) if flags & bit]
    return "|".join(names) or hex(flags)


class TcpChannel:
    """One usbmux TCP connection to a port on the device."""

    def __init__(self, mux, dport, sport=0xF001):
        self.mux = mux
        self.sport = sport
        self.dport = dport
        self.tx_seq = 0
        self.tx_ack = 0
        self.tx_win = 131072
        self.inbox = b""

    def _send(self, flags, payload=b""):
        header = struct.pack("!HHIIBBHHH", self.sport, self.dport, self.tx_seq,
                             self.tx_ack, 5 << 4, flags, self.tx_win >> 8, 0, 0)
        ok = self.mux.send(MUX_PROTO_TCP, header, payload)
        self.tx_seq += len(payload) + (1 if flags & TH_SYN else 0)
        return ok

    def _pump(self, timeout):
        """Reads one mux packet and, if it is ours, files the payload away."""
        proto, packet = self.mux.recv(timeout=timeout)
        if proto is None:
            return None
        if proto != MUX_PROTO_TCP or len(packet) < self.mux.header_size + 20:
            print(f"      [не-TCP пакет proto={proto} len={len(packet)}: {packet[:48].hex()}]")
            return None
        th = packet[self.mux.header_size:self.mux.header_size + 20]
        sport, dport, seq, ack, off_x2, flags, win, _, _ = struct.unpack("!HHIIBBHHH", th)
        if dport != self.sport:
            print(f"      [чужой порт {dport}, ждём {self.sport}]")
            return None
        payload = packet[self.mux.header_size + 20:]
        self._dumped = getattr(self, "_dumped", 0)
        if self._dumped < 4:
            self._dumped += 1
            print(f"      [сырой пакет {len(packet)} б: {packet.hex()}]")
        print(f"      [TCP {flag_names(flags)} off={off_x2 >> 4} sport={sport} dport={dport} "
              f"seq={seq} ack={ack} win={win} данных={len(payload)}: {payload[:40]!r}]")
        self.tx_win = win << 8
        if flags & TH_SYN:
            self.tx_ack = seq + 1
        elif payload:
            self.tx_ack = seq + len(payload)
            self.inbox += payload
            self._send(TH_ACK)
        return flags, payload

    def connect(self, timeout=8):
        self._send(TH_SYN)
        deadline = time.time() + timeout
        while time.time() < deadline:
            got = self._pump(1.0)
            if got and got[0] & TH_SYN and got[0] & TH_ACK:
                self._send(TH_ACK)
                return True
            if got and got[0] & TH_RST:
                return False
        return False

    def write(self, data):
        # Data rides on a plain ACK: the device's mux rejects PSH outright
        # ("th.th_flags = 0x18, not …").
        self._send(TH_ACK, data)

    def read(self, want, timeout=10):
        deadline = time.time() + timeout
        while len(self.inbox) < want and time.time() < deadline:
            self._pump(0.5)
        out, self.inbox = self.inbox[:want], self.inbox[want:]
        return out


class Lockdown:
    def __init__(self, channel):
        self.channel = channel

    def request(self, body):
        payload = plistlib.dumps(body, fmt=plistlib.FMT_XML)
        self.channel.write(struct.pack("!I", len(payload)) + payload)
        head = self.channel.read(4)
        if len(head) < 4:
            return None
        (length,) = struct.unpack("!I", head)
        raw = self.channel.read(length)
        if len(raw) < length:
            return None
        return plistlib.loads(raw)


def main():
    srv = listen(SOCK)
    print(f"Слушаю {SOCK}…")
    conn, _ = srv.accept()
    print("Эмулятор подключился.")
    time.sleep(1.0)

    link = Link(conn)
    link.reset()
    link.get_descriptor(DESC_DEVICE, 0, 18)
    link.set_configuration(CONFIG_VALUE)
    print(f"Конфигурация {CONFIG_VALUE} выбрана")

    mux = Mux(link)
    mux.send(MUX_PROTO_VERSION, struct.pack("!III", 2, 0, 0))
    proto, packet = mux.recv(timeout=8)
    if proto != MUX_PROTO_VERSION:
        print(f"← вместо VERSION пришло {proto}")
        return
    major = struct.unpack("!I", packet[8:12])[0]
    mux.version = min(major, 2)
    print(f"mux версии {major} → работаем по {mux.version}")
    if mux.version >= 2:
        mux.send(MUX_PROTO_SETUP, b"", b"\x07")

    channel = TcpChannel(mux, LOCKDOWN_PORT)
    print(f"→ SYN на порт {LOCKDOWN_PORT} (lockdownd)")
    if not channel.connect():
        print("lockdownd не ответил на SYN")
        return
    print("← SYN|ACK, соединение установлено")

    lock = Lockdown(channel)
    answer = lock.request({"Request": "QueryType", "Label": "inferno-netlab"})
    print(f"QueryType → {answer}")

    for key in ("ProductVersion", "DeviceName", "UniqueDeviceID", "WiFiAddress"):
        answer = lock.request({"Request": "GetValue", "Key": key, "Label": "inferno-netlab"})
        value = answer.get("Value") if answer else None
        print(f"GetValue {key} → {value}")

    answer = lock.request({"Request": "GetValue", "Key": "DevicePublicKey", "Label": "inferno-netlab"})
    key = answer.get("Value") if answer else None
    if isinstance(key, bytes):
        print(f"DevicePublicKey: {len(key)} б\n{key[:120].decode(errors='replace')}")
    else:
        print(f"DevicePublicKey → {key}")


if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, KeyboardInterrupt) as exc:
        print(f"\nЗавершено: {exc}")
    except UsbError as exc:
        print(f"\nUSB: {exc}")
