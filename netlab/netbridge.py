#!/usr/bin/env python3
"""Talks Ethernet to the guest over CDC-NCM and answers it.

Everything before this established the link: mode 3, configuration 5, the CDC
Data interface's alternate setting. The guest then starts transmitting on its
own, wrapped in NCM transfer blocks — an NTH16 header ("NCMH") pointing at an
NDP16 table ("NCM0") of datagram offset/length pairs.

This unwraps them, answers ARP, DHCP and pings itself, and forwards UDP through
real host sockets. It is a proof that the path carries traffic both ways; the
production side will hand the same frames to slirp instead.
"""

import selectors
import socket
import struct
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import ipheth
from ipheth import HOST_IP, HOST_MAC, GUEST_IP, eth_frame, handle_arp, ip2b, checksum
from ncm import (CLASS_IN, MODE_NCM, NCM_GET_NTB_PARAMETERS, REQ_GET_MODE,
                 REQ_SET_MODE, VENDOR_IN, describe)
from tcpusb import (DESC_CONFIG, DESC_DEVICE, RET_SUCCESS, USB_TOKEN_IN,
                    USB_TOKEN_OUT, Link, UsbError, listen)

SOCK = "/tmp/iusb.sock"
NTH16 = b"NCMH"
NDP16 = b"NCM0"


class NcmLink:
    """Ethernet frames in and out of the guest, wrapped in NCM blocks."""

    def __init__(self, link, ep_in, ep_out):
        self.link = link
        self.ep_in = ep_in
        self.ep_out = ep_out
        self.seq = 0
        self.guest_mac = None

    def recv_frames(self):
        status, block = self.link.xfer(USB_TOKEN_IN, self.ep_in, length=4096,
                                       retries=1, delay=0)
        if status != RET_SUCCESS or len(block) < 12 or block[:4] != NTH16:
            return []
        _, header_len, _, block_len, ndp_index = struct.unpack("<4sHHHH", block[:12])
        frames = []
        while ndp_index and ndp_index + 8 <= len(block):
            sig, ndp_len, next_ndp = struct.unpack("<4sHH", block[ndp_index:ndp_index + 8])
            if sig != NDP16:
                break
            cursor = ndp_index + 8
            while cursor + 4 <= ndp_index + ndp_len:
                offset, length = struct.unpack("<HH", block[cursor:cursor + 4])
                cursor += 4
                if offset == 0 or length == 0:
                    break
                if offset + length <= len(block):
                    frames.append(block[offset:offset + length])
            ndp_index = next_ndp
        return frames

    def send(self, frame):
        """One datagram per block keeps this honest and simple."""
        header_len, ndp_len = 12, 16
        ndp_index = header_len
        data_offset = ndp_index + ndp_len
        total = data_offset + len(frame)
        nth = struct.pack("<4sHHHH", NTH16, header_len, self.seq & 0xFFFF, total, ndp_index)
        ndp = struct.pack("<4sHHHHHH", NDP16, ndp_len, 0, data_offset, len(frame), 0, 0)
        self.seq += 1
        status, _ = self.link.xfer(USB_TOKEN_OUT, self.ep_out, nth + ndp + frame,
                                   retries=50, delay=0.01)
        return status == RET_SUCCESS


def setup(link, srv, conn):
    """Puts the device into NCM mode and returns a live NcmLink."""
    link.reset()
    mode = link.control(VENDOR_IN, REQ_GET_MODE, 0, 0, 4)
    if not mode.startswith(b"\x05"):
        print(f"GET_MODE {mode.hex()} → переключаю в режим {MODE_NCM}")
        link.control(VENDOR_IN, REQ_SET_MODE, 0, MODE_NCM, 1)
        conn.close()
        srv.settimeout(60)
        conn, _ = srv.accept()
        print("переподключился")
        time.sleep(1.5)
        link = Link(conn)
        link.reset()

    dev = link.get_descriptor(DESC_DEVICE, 0, 18)
    target = None
    for index in range(dev[17]):
        head = link.get_descriptor(DESC_CONFIG, index, 9)
        total = int.from_bytes(head[2:4], "little")
        raw = link.get_descriptor(DESC_CONFIG, index, total)
        if "NCM" in link.string(raw[6]):
            target = index
    if target is None:
        raise RuntimeError("NCM-конфигурации нет")

    value, control_iface, data_iface, alts, endpoints = describe(link, target)
    link.set_configuration(value)
    if control_iface is not None:
        try:
            link.control(CLASS_IN, NCM_GET_NTB_PARAMETERS, 0, control_iface, 28)
        except UsbError:
            pass
    alt = max(a for a in alts[data_iface] if a)
    link.set_interface(data_iface, alt)
    eps = endpoints[(data_iface, alt)]
    ep_in = next(e & 0xF for e in eps if e & 0x80)
    ep_out = next(e for e in eps if not e & 0x80)
    print(f"NCM поднят: конфигурация {value}, интерфейс {data_iface} alt {alt}, "
          f"IN ep{ep_in}, OUT ep{ep_out}")
    return link, NcmLink(link, ep_in, ep_out)


def forward_udp(net, frame, sessions, sel):
    """Sends the guest's UDP out through a real socket and remembers where."""
    ip = frame[14:]
    ihl = (ip[0] & 0xF) * 4
    sport, dport = struct.unpack("!HH", ip[ihl:ihl + 4])
    payload = ip[ihl + 8:]
    dst = ".".join(map(str, ip[16:20]))
    key = (sport, dst, dport)
    sock = sessions.get(key)
    if sock is None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setblocking(False)
        sessions[key] = sock
        sel.register(sock, selectors.EVENT_READ, (key, frame[6:12], ip[12:16]))
    try:
        sock.sendto(payload, (dst, dport))
        print(f"  UDP → {dst}:{dport} ({len(payload)} б)")
    except OSError as exc:
        print(f"  UDP не ушёл: {exc}")


def udp_back(net, key, guest_mac, guest_ip, payload, src_ip):
    sport, dst, dport = key
    udp = struct.pack("!HHHH", dport, sport, 8 + len(payload), 0) + payload
    total = 20 + len(udp)
    hdr = struct.pack("!BBHHHBBH", 0x45, 0, total, 0, 0, 64, 17, 0) + ip2b(src_ip) + guest_ip
    hdr = hdr[:10] + struct.pack("!H", checksum(hdr)) + hdr[12:]
    net.send(eth_frame(guest_mac, HOST_MAC, 0x0800, hdr + udp))
    print(f"  UDP ← {src_ip}:{dport} ({len(payload)} б)")


def main():
    srv = listen(SOCK)
    print(f"Слушаю {SOCK}…")
    conn, _ = srv.accept()
    print("Эмулятор подключился.")
    time.sleep(1.0)
    link = Link(conn)
    link, net = setup(link, srv, conn)

    sel = selectors.DefaultSelector()
    sessions = {}
    print("\nМост поднят. Жду трафик от гостя…")
    seen = 0
    while True:
        for frame in net.recv_frames():
            seen += 1
            ethertype = struct.unpack("!H", frame[12:14])[0]
            if ethertype == 0x0806:
                handle_arp(net, frame)
            elif ethertype == 0x0800:
                ip = frame[14:]
                proto = ip[9]
                if proto == 17:
                    sport, dport = struct.unpack("!HH", ip[(ip[0] & 0xF) * 4:][:4])
                    if dport == 67:
                        ipheth.handle_ipv4(net, frame)
                    else:
                        forward_udp(net, frame, sessions, sel)
                else:
                    ipheth.handle_ipv4(net, frame)
            elif ethertype == 0x86DD:
                pass
            else:
                print(f"  кадр типа {ethertype:#06x}, {len(frame)} б")

        for key, events in sel.select(timeout=0):
            payload, addr = key.fileobj.recvfrom(65535)
            session, guest_mac, guest_ip = key.data
            udp_back(net, session, guest_mac, guest_ip, payload, addr[0])
        time.sleep(0.005)


if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, KeyboardInterrupt, RuntimeError) as exc:
        print(f"\nЗавершено: {exc}")
    except UsbError as exc:
        print(f"\nUSB: {exc}")
