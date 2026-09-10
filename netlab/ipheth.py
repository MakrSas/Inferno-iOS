#!/usr/bin/env python3
"""Brings the emulated iPhone's "Apple USB Ethernet" function up and talks to it.

The function is interface 2 of configuration 4, class ff/fd/01 — Apple's own,
the one Linux drives with `ipheth`. There is no CDC framing: bulk IN carries an
Ethernet frame behind a two-byte alignment prefix, bulk OUT takes the frame as
is. Two vendor control requests on endpoint 0 hand over the MAC and the carrier
state.

This prototype answers the frames itself — ARP, DHCP, ICMP to the gateway — to
prove the link end to end before any of it is rewritten in C against slirp.
"""

import struct
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from tcpusb import (DESC_DEVICE, RET_SUCCESS, USB_TOKEN_IN, USB_TOKEN_OUT,
                    Link, UsbError, listen)

SOCK = "/tmp/iusb.sock"

CONFIG_VALUE = 4        # PTP + Apple Mobile Device + Apple USB Ethernet
ETH_INTERFACE = 2
ETH_ALT = 2
EP_IN = 6               # 0x86
EP_OUT = 5              # 0x05

CMD_GET_MACADDR = 0x00
CMD_CARRIER_CHECK = 0x45
CTRL_BUF_SIZE = 0x40
VENDOR_IN = 0xC0

RX_PREFIX = 2           # ipheth's IPHETH_IP_ALIGN
RX_SIZE = 1516

# Our side of the wire.
HOST_MAC = bytes.fromhex("02005e000001")
HOST_IP = "10.7.0.1"
GUEST_IP = "10.7.0.2"
NETMASK = "255.255.255.0"


def ip2b(text):
    return bytes(int(x) for x in text.split("."))


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


class Ethernet:
    def __init__(self, link):
        self.link = link
        self.mac = None
        self.guest_mac = None

    def bring_up(self):
        self.link.set_configuration(CONFIG_VALUE)
        self.link.set_interface(ETH_INTERFACE, ETH_ALT)
        raw = self.link.control(VENDOR_IN, CMD_GET_MACADDR, 0, ETH_INTERFACE, CTRL_BUF_SIZE)
        self.mac = raw[:6]
        return raw

    def carrier(self):
        raw = self.link.control(VENDOR_IN, CMD_CARRIER_CHECK, 0, ETH_INTERFACE, CTRL_BUF_SIZE)
        return raw[:8]

    def recv(self, retries=1, delay=0.0):
        status, body = self.link.xfer(USB_TOKEN_IN, EP_IN, length=RX_SIZE,
                                      retries=retries, delay=delay)
        if status != RET_SUCCESS or len(body) <= RX_PREFIX:
            return None
        return body[RX_PREFIX:]

    def send(self, frame):
        status, _ = self.link.xfer(USB_TOKEN_OUT, EP_OUT, frame, retries=50, delay=0.01)
        return status == RET_SUCCESS


def eth_frame(dst, src, ethertype, payload):
    return dst + src + struct.pack("!H", ethertype) + payload


def handle_arp(net, frame):
    body = frame[14:]
    if len(body) < 28:
        return
    htype, ptype, hlen, plen, op = struct.unpack("!HHBBH", body[:8])
    if op != 1 or ptype != 0x0800:
        return
    sender_mac, sender_ip = body[8:14], body[14:18]
    target_ip = body[24:28]
    if target_ip != ip2b(HOST_IP):
        return
    net.guest_mac = sender_mac
    reply = struct.pack("!HHBBH", 1, 0x0800, 6, 4, 2) + HOST_MAC + ip2b(HOST_IP) + sender_mac + sender_ip
    net.send(eth_frame(sender_mac, HOST_MAC, 0x0806, reply))
    print(f"  ARP: сказал, что {HOST_IP} — это {HOST_MAC.hex(':')}")


def dhcp_reply(net, frame, msg_type):
    """Builds a DHCP OFFER (2) or ACK (5) for the one address we hand out."""
    udp = frame[14 + 20:]
    bootp = udp[8:]
    xid = bootp[4:8]
    chaddr = bootp[28:34]
    net.guest_mac = chaddr

    payload = b"\x02\x01\x06\x00" + xid + b"\x00\x00\x00\x00"
    payload += b"\x00\x00\x00\x00"          # ciaddr
    payload += ip2b(GUEST_IP)               # yiaddr
    payload += ip2b(HOST_IP)                # siaddr
    payload += b"\x00\x00\x00\x00"          # giaddr
    payload += chaddr + b"\x00" * 10
    payload += b"\x00" * 192
    payload += bytes.fromhex("63825363")
    payload += bytes([53, 1, msg_type])
    payload += bytes([54, 4]) + ip2b(HOST_IP)
    payload += bytes([51, 4]) + struct.pack("!I", 86400)
    payload += bytes([1, 4]) + ip2b(NETMASK)
    payload += bytes([3, 4]) + ip2b(HOST_IP)
    payload += bytes([6, 4]) + ip2b(HOST_IP)
    payload += bytes([26, 2]) + struct.pack("!H", 1500)
    payload += b"\xff"

    udp_hdr = struct.pack("!HHHH", 67, 68, 8 + len(payload), 0)
    ip_total = 20 + len(udp_hdr) + len(payload)
    ip_hdr = struct.pack("!BBHHHBBH", 0x45, 0, ip_total, 0, 0, 64, 17, 0) + ip2b(HOST_IP) + ip2b(GUEST_IP)
    ip_hdr = ip_hdr[:10] + struct.pack("!H", checksum(ip_hdr)) + ip_hdr[12:]
    net.send(eth_frame(chaddr, HOST_MAC, 0x0800, ip_hdr + udp_hdr + payload))
    print(f"  DHCP: выдал {GUEST_IP} ({'OFFER' if msg_type == 2 else 'ACK'})")


def handle_ipv4(net, frame):
    ip = frame[14:]
    if len(ip) < 20:
        return
    ihl = (ip[0] & 0xF) * 4
    proto = ip[9]
    src, dst = ip[12:16], ip[16:20]

    if proto == 17:
        sport, dport = struct.unpack("!HH", ip[ihl:ihl + 4])
        if dport == 67:
            options = ip[ihl + 8 + 240:]
            msg = 1
            i = 0
            while i + 1 < len(options):
                if options[i] == 53:
                    msg = options[i + 2]
                    break
                if options[i] == 255:
                    break
                i += 2 + options[i + 1]
            dhcp_reply(net, frame, 2 if msg == 1 else 5)
            return
        print(f"  UDP {'.'.join(map(str, src))}:{sport} → {'.'.join(map(str, dst))}:{dport}")
        return

    if proto == 1 and dst == ip2b(HOST_IP):
        icmp = ip[ihl:]
        if icmp[0] != 8:
            return
        reply = b"\x00\x00" + b"\x00\x00" + icmp[4:]
        reply = reply[:2] + struct.pack("!H", checksum(reply)) + reply[4:]
        total = 20 + len(reply)
        hdr = struct.pack("!BBHHHBBH", 0x45, 0, total, 0, 0, 64, 1, 0) + ip2b(HOST_IP) + src
        hdr = hdr[:10] + struct.pack("!H", checksum(hdr)) + hdr[12:]
        net.send(eth_frame(frame[6:12], HOST_MAC, 0x0800, hdr + reply))
        print(f"  ICMP: ответил на пинг с {'.'.join(map(str, src))}")
        return

    print(f"  IPv4 proto {proto}: {'.'.join(map(str, src))} → {'.'.join(map(str, dst))}")



def icmpv6_checksum(src, dst, payload):
    pseudo = src + dst + struct.pack("!I", len(payload)) + b"\x00\x00\x00\x3a"
    return checksum(pseudo + payload)


def send_router_advert(net):
    """Pokes the guest with an RA.

    If its interface is up at all, iOS autoconfigures an address off this and
    immediately sends duplicate-address detection — which makes the link visibly
    alive without needing anything configured inside the guest.
    """
    src = bytes.fromhex("fe800000000000000000000000000001")
    dst = bytes.fromhex("ff020000000000000000000000000001")
    ra = struct.pack("!BBHBBHII", 134, 0, 0, 64, 0, 1800, 0, 0)
    ra += bytes([1, 1]) + HOST_MAC                       # source link-layer address
    ra += bytes([3, 4, 64, 0xC0]) + struct.pack("!III", 86400, 14400, 0)
    ra += bytes.fromhex("fd000007000000000000000000000000")
    ra = ra[:2] + struct.pack("!H", icmpv6_checksum(src, dst, ra)) + ra[4:]
    hdr = struct.pack("!IHBB", 0x60000000, len(ra), 58, 255) + src + dst
    net.send(eth_frame(bytes.fromhex("333300000001"), HOST_MAC, 0x86DD, hdr + ra))
    print("  отправил IPv6 Router Advertisement")


def send_arp_probe(net):
    body = struct.pack("!HHBBH", 1, 0x0800, 6, 4, 1) + HOST_MAC + ip2b(HOST_IP)
    body += b"\x00" * 6 + ip2b(GUEST_IP)
    net.send(eth_frame(b"\xff" * 6, HOST_MAC, 0x0806, body))
    print(f"  отправил широковещательный ARP «кто такой {GUEST_IP}»")


def main():
    srv = listen(SOCK)
    print(f"Слушаю {SOCK}…")
    conn, _ = srv.accept()
    print("Эмулятор подключился.")
    time.sleep(1.0)

    link = Link(conn)
    link.reset()
    dev = link.get_descriptor(DESC_DEVICE, 0, 18)
    print(f"Устройство: VID {int.from_bytes(dev[8:10], 'little'):#06x} "
          f"PID {int.from_bytes(dev[10:12], 'little'):#06x}")

    net = Ethernet(link)
    link.set_configuration(CONFIG_VALUE)
    print(f"Конфигурация {CONFIG_VALUE} выбрана")
    raw = link.control(VENDOR_IN, CMD_GET_MACADDR, 0, ETH_INTERFACE, CTRL_BUF_SIZE)
    net.mac = raw[:6]
    print(f"MAC устройства: {net.mac.hex(':')}")

    # Which alternate setting actually wakes the function up is the question:
    # both alt 1 and alt 2 declare the same pair of bulk endpoints.
    for alt in (1, 2, 1):
        link.set_interface(ETH_INTERFACE, alt)
        got = link.control(0x81, 10, 0, ETH_INTERFACE, 1)
        print(f"\nalt {alt} выставлен (GET_INTERFACE вернул {got.hex()}), "
              f"carrier {net.carrier().hex()}")
        send_router_advert(net)
        send_arp_probe(net)
        deadline = time.time() + 8
        seen = 0
        while time.time() < deadline:
            frame = net.recv()
            if frame:
                seen += 1
                print(f"  кадр {len(frame)} б, тип {frame[12:14].hex()}")
            else:
                time.sleep(0.01)
        print(f"  за 6 с получено кадров: {seen}")
        if seen:
            break

    print("\nСлушаю кадры от гостя (Ctrl+C для выхода)…")
    idle = 0
    while True:
        frame = net.recv()
        if frame is None:
            idle += 1
            time.sleep(0.01)
            if idle % 1000 == 0:
                print(f"  … тишина ({idle} пустых чтений)")
            continue
        idle = 0
        dst, src = frame[0:6], frame[6:12]
        ethertype = struct.unpack("!H", frame[12:14])[0]
        print(f"кадр {len(frame)} б: {src.hex(':')} → {dst.hex(':')} тип {ethertype:#06x}")
        if ethertype == 0x0806:
            handle_arp(net, frame)
        elif ethertype == 0x0800:
            handle_ipv4(net, frame)


if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, KeyboardInterrupt) as exc:
        print(f"\nЗавершено: {exc}")
    except UsbError as exc:
        print(f"\nUSB: {exc}")
