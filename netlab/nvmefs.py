#!/usr/bin/env python3
"""Передача файлов в гостя и обратно через отдельное пространство имён NVMe.

    nvmefs.py push <локальный> <путь в госте>
    nvmefs.py pull <путь в госте> <локальный>
    nvmefs.py size

Быстрее сети и консоли, потому что байты вообще никуда не едут: хост пишет их
в файл-подложку namespace'а, а гость читает то же место как блочное устройство.
Через консоль идёт только короткая команда с адресом и длиной.

Что для этого понадобилось — три вещи, каждая проверена на стенде:

1. **Гость не перечисляет namespace'ы сам.** `AppleEmbeddedNVMeController` берёт
   их список из device tree и прямо об этом пишет: `SetNamespacesStruct: Obtained
   7 namespaces from DT`. Namespace, добавленный только в командную строку QEMU,
   гость не видит вовсе. Поэтому в `hw/block/ans.c` свойство `namespaces` узла
   `arm-io/ans` пересобирается из реально подключённых namespace'ов.

2. **Шеллу блочные устройства закрыты.** `dd if=/dev/rdisk1` даёт `Operation not
   permitted` и от root, хотя `/dev/urandom` читается, а `/sbin/fsck_hfs` то же
   устройство спокойно читает. Дело в правах бинарника, не в носителе: помощник
   `nsio`, подписанный `ldid` с `platform-application` и
   `com.apple.private.security.disk-device-access`, устройство открывает.
   Без прав его убивает AMFI — `Killed: 9` ещё до main().

3. **Смонтировать namespace нельзя.** `mount_hfs` отвечает `Operation not
   permitted` именно на `mount()`, так что путь «носить файловую систему, понятную
   обеим сторонам» закрыт. Поэтому носим сырые байты, а не файловую систему.

Подложку QEMU обязан открывать с `cache=none`: иначе он держит страницы файла в
кэше хоста и отдаёт гостю то, что было до записи.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from guestfs import Guest, posix_cksum, shell_quote, human

BLOCK = 4096
# Куда гость складывает кусок, прежде чем тот станет файлом.
GUEST_TMP = "/var/mobile/.nvmefs.part"
DEFAULT_DEV = "/dev/rdisk2"
DEFAULT_NSIO = "/var/mobile/nsio-ent"


def blocks_up(size):
    return (size + BLOCK - 1) // BLOCK * BLOCK


class Namespace:
    """Общий носитель: у хоста это файл, у гостя — блочное устройство."""

    def __init__(self, guest, image, dev=DEFAULT_DEV, nsio=DEFAULT_NSIO):
        self.guest = guest
        self.image = image
        self.dev = dev
        self.nsio = nsio
        self.capacity = os.path.getsize(image)

    # -- хост -------------------------------------------------------------

    def write_host(self, data, offset=0):
        """Кладёт байты в подложку и доводит их до диска.

        Без fsync гость прочитает старое: страницы файла останутся в кэше хоста,
        а QEMU читает подложку заново на каждый запрос.
        """
        with open(self.image, "r+b") as handle:
            handle.seek(offset)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())

    def read_host(self, length, offset=0):
        with open(self.image, "rb") as handle:
            handle.seek(offset)
            return handle.read(length)

    # -- гость ------------------------------------------------------------

    def guest_ready(self):
        """Есть ли в госте устройство и рабочий помощник."""
        out, _ = self.guest.run("%s size %s 2>&1 | head -1" % (self.nsio, self.dev), timeout=45)
        return "blocksize=" in out, out.strip().splitlines()[-1:] or [""]

    def push(self, local, remote, progress=None):
        size = os.path.getsize(local)
        with open(local, "rb") as handle:
            data = handle.read()

        window = self.capacity
        sent = 0
        first = True
        while sent < size:
            piece = data[sent:sent + window]
            padded = piece + b"\0" * (blocks_up(len(piece)) - len(piece))
            self.write_host(padded)
            # Гость читает ровно столько, сколько лежит, и дописывает к файлу.
            # `>` на первом куске и `>>` дальше: так файл собирается за один
            # проход, без отдельной команды на создание.
            redirect = ">" if first else ">>"
            command = "%s read %s 0 %d %s && cat %s %s %s" % (
                self.nsio, self.dev, len(piece), GUEST_TMP, GUEST_TMP, redirect, shell_quote(remote))
            out, status = self.guest.run(command, timeout=180)
            if status != 0:
                raise IOError("гость не смог прочитать кусок: %s" % out.strip()[-200:])
            sent += len(piece)
            first = False
            if progress:
                progress(sent, size)

        self.guest.run("rm -f %s" % GUEST_TMP, timeout=45)
        self.verify(remote, data)
        return size

    def pull(self, remote, local, progress=None):
        _, status = self.guest.run("test -f %s" % shell_quote(remote), timeout=45)
        if status != 0:
            raise IOError("нет файла %s" % remote)
        size = self.guest.number("wc -c < %s" % shell_quote(remote))

        window = self.capacity
        got = 0
        pieces = []
        while got < size:
            take = min(window, size - got)
            # Гость вырезает окно в отдельный файл и кладёт его в namespace.
            command = "dd if=%s of=%s bs=%d skip=%d count=1 2>/dev/null && %s write %s 0 %s" % (
                shell_quote(remote), GUEST_TMP, window, got // window, self.nsio, self.dev, GUEST_TMP)
            out, status = self.guest.run(command, timeout=180)
            if status != 0:
                raise IOError("гость не смог записать кусок: %s" % out.strip()[-200:])
            pieces.append(self.read_host(take))
            got += take
            if progress:
                progress(got, size)

        self.guest.run("rm -f %s" % GUEST_TMP, timeout=45)
        data = b"".join(pieces)[:size]
        with open(local, "wb") as handle:
            handle.write(data)
        self.verify(remote, data)
        return size

    def verify(self, remote, data):
        size = self.guest.number("wc -c < %s" % shell_quote(remote))
        crc = self.guest.number("cksum < %s | cut -d' ' -f1" % shell_quote(remote))
        if size != len(data) or crc != posix_cksum(data):
            raise IOError("не сошлось: в госте %s Б, cksum %s; у нас %d Б, cksum %d"
                          % (size, crc, len(data), posix_cksum(data)))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=4555)
    parser.add_argument("--image", required=True, help="файл-подложка namespace'а на хосте")
    parser.add_argument("--dev", default=DEFAULT_DEV, help="блочное устройство в госте")
    parser.add_argument("--nsio", default=DEFAULT_NSIO, help="помощник в госте")
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("push"); p.add_argument("local"); p.add_argument("remote")
    p = sub.add_parser("pull"); p.add_argument("remote"); p.add_argument("local")
    sub.add_parser("size")
    args = parser.parse_args()

    # `cksum` на мегабайтах в загруженном госте идёт долго, а консоль в это
    # время молчит; короткого ожидания здесь не хватает.
    guest = Guest(port=args.port, timeout=300)
    ns = Namespace(guest, args.image, args.dev, args.nsio)
    ok, detail = ns.guest_ready()
    if not ok:
        sys.stderr.write("гость не видит носитель (%s): %s\n" % (args.dev, detail))
        guest.close()
        return 1
    if args.action == "size":
        print("носитель %s, в госте %s: %s" % (human(ns.capacity), args.dev, detail))
        guest.close()
        return 0

    start = time.time()

    def show(done, total):
        took = max(time.time() - start, 0.001)
        sys.stderr.write("\r%s из %s, %.0f КБ/с   " % (human(done), human(total), done / took / 1024))
        sys.stderr.flush()

    try:
        if args.action == "push":
            size = ns.push(args.local, args.remote, show)
        else:
            size = ns.pull(args.remote, args.local, show)
        sys.stderr.write("\n")
        took = time.time() - start
        print("%s за %.1f с (%.0f КБ/с)" % (human(size), took, size / took / 1024))
        return 0
    except Exception as exc:
        sys.stderr.write("\nне вышло: %s\n" % exc)
        guest.recover()
        return 1
    finally:
        guest.close()


if __name__ == "__main__":
    sys.exit(main())
