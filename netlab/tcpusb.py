"""Host side of Inferno's USB-over-socket link.

The emulated device exports its USB port through `hw/usb/hcd-tcp.c`, which
*connects* to a socket and expects whoever listens there to act as the USB
host: send `TCP_USB_REQUEST`, read back `TCP_USB_RESPONSE`. That is the role the
companion Linux VM plays in the stock setup, and the role this module replaces.

The wire format is `hw/usb/tcp-usb.h`, packed little-endian structs.
"""

import os
import socket
import struct
import time

TCP_USB_REQUEST = 1
TCP_USB_RESPONSE = 2
TCP_USB_RESET = 3
TCP_USB_CANCEL = 4

USB_TOKEN_SETUP = 0x2D
USB_TOKEN_IN = 0x69
USB_TOKEN_OUT = 0xE1

# QEMU's USB_RET_* — carried in a uint32 field, read back as signed.
RET_SUCCESS = 0
RET_NODEV = -1
RET_NAK = -2
RET_STALL = -3
RET_BABBLE = -4
RET_IOERROR = -5
RET_ASYNC = -6

RET_NAMES = {
    0: "SUCCESS", -1: "NODEV", -2: "NAK", -3: "STALL",
    -4: "BABBLE", -5: "IOERROR", -6: "ASYNC",
}

_HDR = struct.Struct("<B")
_REQ = struct.Struct("<BiBQIBBH")   # addr, pid, ep, id, stream, short_not_ok, int_req, length
_RSP = struct.Struct("<BiBQIH")     # addr, pid, ep, id, status, length

DIR_OUT = 0x00
DIR_IN = 0x80
TYPE_STANDARD = 0x00
TYPE_CLASS = 0x20
RECIP_DEVICE = 0x00
RECIP_INTERFACE = 0x01

REQ_GET_DESCRIPTOR = 6
REQ_SET_CONFIGURATION = 9
REQ_GET_CONFIGURATION = 8
REQ_SET_INTERFACE = 11

DESC_DEVICE = 1
DESC_CONFIG = 2
DESC_STRING = 3


class UsbError(Exception):
    def __init__(self, status, what=""):
        super().__init__(f"{what}: {RET_NAMES.get(status, status)}")
        self.status = status


class Link:
    """One accepted connection from the emulated device."""

    def __init__(self, conn, verbose=False):
        self.conn = conn
        self.verbose = verbose
        self._next_id = 1
        self.addr = 0

    # ---- framing -------------------------------------------------------

    def _recv(self, n):
        out = b""
        while len(out) < n:
            chunk = self.conn.recv(n - len(out))
            if not chunk:
                raise ConnectionError("устройство закрыло соединение")
            out += chunk
        return out

    def _request(self, pid, ep, data=b"", length=None, short_not_ok=0):
        """Issues one USB packet and returns (status, payload)."""
        pid_id = self._next_id
        self._next_id += 1
        if length is None:
            length = len(data)
        body = _REQ.pack(self.addr, pid, ep, pid_id, 0, short_not_ok, 0, length)
        payload = data if pid != USB_TOKEN_IN else b""
        self.conn.sendall(_HDR.pack(TCP_USB_REQUEST) + body + payload)

        # An ASYNC reply is a promise, not an answer: the real one follows with
        # the same id.
        while True:
            (kind,) = _HDR.unpack(self._recv(1))
            if kind != TCP_USB_RESPONSE:
                raise ConnectionError(f"неожиданный тип пакета: {kind}")
            addr, rpid, rep, rid, status, rlen = _RSP.unpack(self._recv(_RSP.size))
            status = struct.unpack("<i", struct.pack("<I", status))[0]
            body = b""
            if rlen > 0 and status != RET_ASYNC and rpid == USB_TOKEN_IN:
                body = self._recv(rlen)
            if self.verbose:
                print(f"    <- id={rid} pid=0x{rpid:02x} ep={rep} "
                      f"{RET_NAMES.get(status, status)} len={rlen}")
            if rid != pid_id or status == RET_ASYNC:
                continue
            return status, body

    def reset(self):
        """Drives a USB bus reset.

        The device controller only starts servicing endpoint 0 once it has seen
        one; without it every SETUP comes back NAK.
        """
        self.conn.sendall(_HDR.pack(TCP_USB_RESET))
        self.addr = 0
        time.sleep(0.3)

    # ---- transfers -----------------------------------------------------

    def xfer(self, pid, ep, data=b"", length=None, retries=200, delay=0.01, short_not_ok=0):
        """One packet, retried while the device answers NAK.

        NAK is not an error: it means "not ready yet", and a real host controller
        simply reissues the token. Everything above this depends on that.
        """
        for _ in range(retries):
            status, body = self._request(pid, ep, data, length, short_not_ok)
            if status != RET_NAK:
                return status, body
            time.sleep(delay)
        return RET_NAK, b""

    def control(self, bmRequestType, bRequest, wValue, wIndex, wLength=0, data=b""):
        """A full control transfer: SETUP, optional data stage, status stage."""
        setup = struct.pack("<BBHHH", bmRequestType, bRequest, wValue, wIndex, wLength)
        status, _ = self.xfer(USB_TOKEN_SETUP, 0, setup)
        if status != RET_SUCCESS:
            raise UsbError(status, "SETUP")

        incoming = bool(bmRequestType & DIR_IN)
        out = b""
        if wLength:
            if incoming:
                status, out = self.xfer(USB_TOKEN_IN, 0, length=wLength)
            else:
                status, _ = self.xfer(USB_TOKEN_OUT, 0, data[:wLength])
            if status != RET_SUCCESS:
                raise UsbError(status, "стадия данных")

        # Status stage runs the other way and carries nothing.
        status, _ = self.xfer(USB_TOKEN_OUT if incoming else USB_TOKEN_IN, 0, length=0)
        if status != RET_SUCCESS:
            raise UsbError(status, "стадия статуса")
        return out

    def get_descriptor(self, desc_type, index, length, lang=0):
        return self.control(DIR_IN | TYPE_STANDARD | RECIP_DEVICE, REQ_GET_DESCRIPTOR,
                            (desc_type << 8) | index, lang, length)

    def set_configuration(self, value):
        self.control(DIR_OUT | TYPE_STANDARD | RECIP_DEVICE, REQ_SET_CONFIGURATION, value, 0, 0)

    def get_configuration(self):
        return self.control(DIR_IN | TYPE_STANDARD | RECIP_DEVICE, REQ_GET_CONFIGURATION, 0, 0, 1)[0]

    def set_interface(self, interface, alt):
        self.control(DIR_OUT | TYPE_STANDARD | RECIP_INTERFACE, REQ_SET_INTERFACE, alt, interface, 0)

    def string(self, index, lang=0x0409):
        if index == 0:
            return ""
        try:
            raw = self.get_descriptor(DESC_STRING, index, 255, lang)
        except (UsbError, ConnectionError):
            return ""
        if len(raw) < 2:
            return ""
        return raw[2:raw[0]].decode("utf-16-le", errors="replace")


def listen(path):
    """Creates the socket the emulated device dials into."""
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.chmod(path, 0o666)
    srv.listen(1)
    return srv
