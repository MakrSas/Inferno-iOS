#!/usr/bin/env python3
"""Pairs with the emulated device, then checks whether that wakes its Ethernet.

Pairing is what the stock setup gets from usbmuxd plus `idevicepair pair`, and
the evidence so far says it is the gate: with a live mux link and the interface's
alternate setting selected, iOS still refuses to activate `AppleUSBEthernet`.

The host mints a throwaway CA, issues itself a certificate and one for the
device's own public key, and hands all three to lockdownd. iOS then asks its user
to trust us; until that tap happens it answers PairingDialogResponsePending.
"""

import datetime
import plistlib
import struct
import sys
import time
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from lockdown import Lockdown, TcpChannel, LOCKDOWN_PORT
from muxprobe import (CONFIG_VALUE, ETH_INTERFACE, MUX_PROTO_SETUP,
                      MUX_PROTO_VERSION, Mux)
from tcpusb import (DESC_DEVICE, RET_SUCCESS, USB_TOKEN_IN, Link, UsbError, listen)

SOCK = "/tmp/iusb.sock"
ETH_EP_IN = 6
LABEL = "inferno-netlab"

PEM = serialization.Encoding.PEM


def rsa_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def certificate(subject_key, issuer_key, ca):
    """Mints one certificate the way libimobiledevice does: no names, ten years."""
    now = datetime.datetime.now(datetime.timezone.utc)
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([]))
        .issuer_name(x509.Name([]))
        .public_key(subject_key)
        .serial_number(1)
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(subject_key), critical=False)
    )
    if not ca:
        builder = builder.add_extension(
            x509.KeyUsage(digital_signature=True, key_encipherment=True,
                          content_commitment=False, data_encipherment=False,
                          key_agreement=False, key_cert_sign=False, crl_sign=False,
                          encipher_only=False, decipher_only=False),
            critical=True)
    return builder.sign(issuer_key, hashes.SHA256())


def build_pair_record(device_public_pem):
    device_key = serialization.load_pem_public_key(device_public_pem)

    root = rsa_key()
    host = rsa_key()
    root_cert = certificate(root.public_key(), root, ca=True)
    host_cert = certificate(host.public_key(), root, ca=False)
    device_cert = certificate(device_key, root, ca=False)

    private = serialization.PrivateFormat.TraditionalOpenSSL
    nocrypt = serialization.NoEncryption()
    record = {
        "DeviceCertificate": device_cert.public_bytes(PEM),
        "HostCertificate": host_cert.public_bytes(PEM),
        "RootCertificate": root_cert.public_bytes(PEM),
        "HostID": str(uuid.uuid4()).upper(),
        "SystemBUID": str(uuid.uuid4()).upper(),
    }
    secrets = {
        "HostPrivateKey": host.private_bytes(PEM, private, nocrypt),
        "RootPrivateKey": root.private_bytes(PEM, private, nocrypt),
    }
    return record, secrets


def watch_ethernet(link, seconds, label, alt=2):
    """Drives the function the way ipheth does and listens for anything at all."""
    import ipheth

    link.set_interface(ETH_INTERFACE, alt)
    net = ipheth.Ethernet(link)
    net.mac = link.control(0xC0, 0x00, 0, ETH_INTERFACE, 0x40)[:6]
    print(f"  alt {alt}, MAC {net.mac.hex(':')}")

    frames = 0
    last_carrier = None
    next_poll = 0.0
    poked = False
    deadline = time.time() + seconds
    while time.time() < deadline:
        now = time.time()
        if now >= next_poll:
            # ipheth polls this once a second; the device may take it as proof
            # that a real driver is attached.
            next_poll = now + 1.0
            carrier = net.carrier().hex()
            if carrier != last_carrier:
                print(f"  carrier → {carrier}")
                last_carrier = carrier
            if not poked:
                poked = True
                ipheth.send_router_advert(net)
                ipheth.send_arp_probe(net)
        status, body = link.xfer(USB_TOKEN_IN, ETH_EP_IN, length=1516, retries=1, delay=0)
        if status == RET_SUCCESS and len(body) > 2:
            frames += 1
            print(f"  ETH ← кадр {len(body) - 2} б: {body[2:20].hex()}")
        else:
            time.sleep(0.01)
    print(f"[{label}] кадров с Ethernet: {frames}")
    return frames


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

    mux = Mux(link)
    mux.send(MUX_PROTO_VERSION, struct.pack("!III", 2, 0, 0))
    proto, packet = mux.recv(timeout=8)
    if proto != MUX_PROTO_VERSION:
        print("mux не ответил")
        return
    mux.version = min(struct.unpack("!I", packet[8:12])[0], 2)
    if mux.version >= 2:
        mux.send(MUX_PROTO_SETUP, b"", b"\x07")
    print(f"mux версии {mux.version}")

    channel = TcpChannel(mux, LOCKDOWN_PORT)
    if not channel.connect():
        print("lockdownd не ответил")
        return
    lock = Lockdown(channel)
    print(f"lockdownd: {lock.request({'Request': 'QueryType', 'Label': LABEL})}")

    answer = lock.request({"Request": "GetValue", "Key": "DevicePublicKey", "Label": LABEL})
    device_public = answer.get("Value") if answer else None
    if not device_public:
        print("публичный ключ устройства не отдали")
        return
    print(f"публичный ключ устройства: {len(device_public)} б")

    record, secrets = build_pair_record(device_public)
    print(f"выпустил CA, хостовый и устройственный сертификаты; HostID {record['HostID']}")

    print("\n→ Pair. Если гость спросит про доверие — нажми «Доверять».")
    deadline = time.time() + 120
    result = None
    while time.time() < deadline:
        result = lock.request({
            "Request": "Pair",
            "PairRecord": record,
            "Label": LABEL,
            "ProtocolVersion": "2",
            "PairingOptions": {"ExtendedPairingErrors": True},
        })
        if result is None:
            print("  ответа нет")
            break
        error = result.get("Error")
        if error is None:
            break
        print(f"  {error}")
        if error not in ("PairingDialogResponsePending", "PasswordProtected"):
            break
        time.sleep(2)

    print(f"Pair → { {k: (v if not isinstance(v, bytes) else f'<{len(v)} б>') for k, v in (result or {}).items()} }")

    if result and result.get("Error") is None:
        session = lock.request({
            "Request": "StartSession",
            "HostID": record["HostID"],
            "SystemBUID": record["SystemBUID"],
            "Label": LABEL,
        })
        print(f"StartSession → {session}")

    # iOS may hand out a different descriptor set once it trusts the host —
    # notably the CDC/NCM functions it registers but never exposes to strangers.
    print("\nПеречитываю конфигурации после пейринга…")
    time.sleep(8)
    from dump_helper import summarise
    summarise(link)

    for alt in (2, 1):
        if watch_ethernet(link, 20, f"после пейринга, alt {alt}", alt):
            break


if __name__ == "__main__":
    try:
        main()
    except (ConnectionError, KeyboardInterrupt) as exc:
        print(f"\nЗавершено: {exc}")
    except UsbError as exc:
        print(f"\nUSB: {exc}")
