#!/usr/bin/env python3
"""Speak the agent's protocol over the scratch NVMe backing file, from the host.

This is the rig twin of the app's Swift client (`GuestAgent`): it writes a
request into the namespace backing file and reads the answer back, exactly the
way the phone will. The guest agent, polling the raw device, is on the other
end.

    agenttest.py --image FILE ping
    agenttest.py --image FILE exec 'uptime'
    agenttest.py --image FILE statusbar        # a sample Wi-Fi look
    agenttest.py --image FILE clearbar
    agenttest.py --image FILE push LOCAL REMOTE
    agenttest.py --image FILE pull REMOTE LOCAL
    agenttest.py --image FILE wait             # retry ping until it answers

The layout and header must match agent.h.
"""
import argparse
import fcntl
import json
import os
import struct
import sys
import time

HEADER_SIZE = 64
BLOCK = 4096
HEADER_BLOCK = BLOCK
REQ_OFFSET = 0
REQ_BODY = REQ_OFFSET + HEADER_BLOCK
REQ_SIZE = 256 * 1024
RSP_OFFSET = 256 * 1024
RSP_BODY = RSP_OFFSET + HEADER_BLOCK
RSP_SIZE = 768 * 1024
DATA_OFFSET = 1024 * 1024
PROTO = 1
REQ_MAGIC = b"INFAGREQ"
RSP_MAGIC = b"INFAGRSP"
F_NOCACHE = 48

# struct AgentHeader: 8s magic, I proto, I flags, Q session, Q seq, Q agent,
# I length, I crc, I headcrc, 12x pad  = 64 bytes.
HEADER = struct.Struct("<8sIIQQQIII12x")
assert HEADER.size == HEADER_SIZE, HEADER.size


def cksum(data):
    table = []
    for i in range(256):
        c = i << 24
        for _ in range(8):
            c = ((c << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if c & 0x80000000 else (c << 1) & 0xFFFFFFFF
        table.append(c)
    c = 0
    for b in data:
        c = ((c << 8) & 0xFFFFFFFF) ^ table[((c >> 24) ^ b) & 0xFF]
    n = len(data)
    while n:
        c = ((c << 8) & 0xFFFFFFFF) ^ table[((c >> 24) ^ (n & 0xFF)) & 0xFF]
        n >>= 8
    return (~c) & 0xFFFFFFFF


class Channel:
    def __init__(self, image):
        self.image = image
        # Unique per run: the agent dedups by (session, seq), so a session that
        # repeats across runs with seq reset would look like a duplicate and be
        # answered from stale data. Milliseconds, pid and a nonce keep it apart.
        self.session = ((int(time.time() * 1000) & 0xFFFFFFFFFF) << 24) \
            ^ ((os.getpid() & 0xFFF) << 12) ^ (int.from_bytes(os.urandom(2), "big"))
        self.seq = 0

    def _open(self):
        fd = os.open(self.image, os.O_RDWR)
        try:
            fcntl.fcntl(fd, F_NOCACHE, 1)
        except OSError:
            pass
        return fd

    def _write_region(self, fd, offset, blob):
        span = (len(blob) + BLOCK - 1) // BLOCK * BLOCK
        padded = blob + b"\0" * (span - len(blob))
        os.pwrite(fd, padded, offset)
        os.fsync(fd)

    def _read_region(self, fd, offset, size):
        return os.pread(fd, size, offset)

    def request(self, obj, timeout=30, quiet_ok=False):
        self.seq += 1
        body = json.dumps(obj).encode()
        head = bytearray(HEADER_SIZE)
        # body first, then header, so the agent never sees a new seq before the
        # body it names is on disk.
        fd = self._open()
        try:
            self._write_region(fd, REQ_BODY, body)
            partial = HEADER.pack(REQ_MAGIC, PROTO, 0, self.session, self.seq, 0,
                                  len(body), cksum(body), 0)
            headcrc = cksum(partial[:48])  # over the bytes before headcrc (offsetof)
            full = HEADER.pack(REQ_MAGIC, PROTO, 0, self.session, self.seq, 0,
                               len(body), cksum(body), headcrc)
            self._write_region(fd, REQ_OFFSET, full)
        finally:
            os.close(fd)

        end = time.time() + timeout
        while time.time() < end:
            fd = self._open()
            try:
                raw = self._read_region(fd, RSP_OFFSET, HEADER_SIZE)
            finally:
                os.close(fd)
            magic, proto, _flags, session, seq, agent, length, crc, headcrc = HEADER.unpack(raw)
            if magic == RSP_MAGIC and proto == PROTO and session == self.session and seq == self.seq:
                if cksum(raw[:48]) != headcrc:
                    time.sleep(0.05)
                    continue
                fd = self._open()
                try:
                    payload = self._read_region(fd, RSP_BODY, length)
                finally:
                    os.close(fd)
                if cksum(payload) != crc:
                    time.sleep(0.05)
                    continue
                return json.loads(payload.decode("utf-8", "replace"))
            time.sleep(0.1)
        if quiet_ok:
            return None
        raise TimeoutError("no answer to seq %d" % self.seq)

    # -- file windows through the data region -----------------------------

    def push_file(self, local, remote):
        size = os.path.getsize(local)
        window = self._capacity() - DATA_OFFSET
        with open(local, "rb") as handle:
            data = handle.read()
        sent = 0
        first = True
        while sent < size or (size == 0 and first):
            piece = data[sent:sent + window]
            fd = self._open()
            try:
                self._write_region(fd, DATA_OFFSET, piece)
            finally:
                os.close(fd)
            answer = self.request({"op": "push", "path": remote, "len": len(piece),
                                   "at": sent, "first": first, "crc": cksum(piece)}, timeout=120)
            if not answer.get("ok"):
                raise IOError("push: %s" % answer.get("error"))
            sent += len(piece)
            first = False
            if size == 0:
                break
        return size

    def pull_file(self, remote, local):
        info = self.request({"op": "stat", "path": remote})
        if not info.get("exists"):
            raise IOError("no such file: %s" % remote)
        total = info["size"]
        window = self._capacity() - DATA_OFFSET
        got = 0
        pieces = []
        while got < total:
            take = min(window, total - got)
            answer = self.request({"op": "pull", "path": remote, "at": got, "len": take}, timeout=120)
            if not answer.get("ok"):
                raise IOError("pull: %s" % answer.get("error"))
            fd = self._open()
            try:
                blob = self._read_region(fd, DATA_OFFSET, answer["len"])
            finally:
                os.close(fd)
            if cksum(blob) != answer["crc"]:
                raise IOError("pull: window checksum at %d" % got)
            pieces.append(blob)
            got += answer["len"]
        with open(local, "wb") as handle:
            handle.write(b"".join(pieces))
        return got

    def _capacity(self):
        return os.path.getsize(self.image)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    parser.add_argument("--timeout", type=float, default=30)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("ping")
    sub.add_parser("wait")
    sb = sub.add_parser("statusbar")
    sb.add_argument("--second", action="store_true", help="also a second SIM with its own bars")
    sub.add_parser("clearbar")
    e = sub.add_parser("exec"); e.add_argument("cmd"); e.add_argument("--wait", type=float, default=10)
    e.add_argument("--timeout-job", type=float, default=60)
    p = sub.add_parser("poll"); p.add_argument("id"); p.add_argument("--wait", type=float, default=5)
    k = sub.add_parser("kill"); k.add_argument("id")
    pu = sub.add_parser("push"); pu.add_argument("local"); pu.add_argument("remote")
    pl = sub.add_parser("pull"); pl.add_argument("remote"); pl.add_argument("local")
    args = parser.parse_args()

    ch = Channel(args.image)
    if args.action == "wait":
        end = time.time() + args.timeout
        while time.time() < end:
            answer = ch.request({"op": "ping"}, timeout=3, quiet_ok=True)
            if answer:
                print(json.dumps(answer, ensure_ascii=False))
                return 0
            time.sleep(1)
        print("agent did not answer", file=sys.stderr)
        return 1
    if args.action == "ping":
        print(json.dumps(ch.request({"op": "ping"}, timeout=args.timeout), ensure_ascii=False, indent=1))
        return 0
    if args.action == "exec":
        jid = "t%d" % (time.time() * 1000 % 1000000)
        answer = ch.request({"op": "exec", "id": jid, "cmd": args.cmd,
                             "timeout": args.timeout_job, "wait": args.wait}, timeout=args.timeout + args.wait)
        print(json.dumps(answer, ensure_ascii=False, indent=1))
        return 0
    if args.action == "poll":
        print(json.dumps(ch.request({"op": "poll", "id": args.id, "wait": args.wait}), ensure_ascii=False, indent=1))
        return 0
    if args.action == "kill":
        print(json.dumps(ch.request({"op": "kill", "id": args.id}), ensure_ascii=False, indent=1))
        return 0
    if args.action == "statusbar":
        look = {"cellularBars": 4, "network": 4, "carrier": "rig", "wifi": True, "wifiBars": 3}
        if args.second:
            # The second SIM's own half: its bars, its carrier, its network.
            look.update({"secondSIM": True, "secondBars": 2,
                         "secondCarrier": "rig2", "secondNetwork": 1})
        print(json.dumps(ch.request({"op": "statusbar", "look": look}), ensure_ascii=False))
        return 0
    if args.action == "clearbar":
        print(json.dumps(ch.request({"op": "statusbar", "look": {"clear": True}}), ensure_ascii=False))
        return 0
    if args.action == "push":
        t = time.time(); n = ch.push_file(args.local, args.remote)
        print("pushed %d bytes in %.1fs" % (n, time.time() - t))
        return 0
    if args.action == "pull":
        t = time.time(); n = ch.pull_file(args.remote, args.local)
        print("pulled %d bytes in %.1fs" % (n, time.time() - t))
        return 0


if __name__ == "__main__":
    sys.exit(main())
