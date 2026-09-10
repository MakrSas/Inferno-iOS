#!/usr/bin/env python3
"""Установка `.ipa` в гостя.

    installipa.py --image <подложка namespace> App.ipa      # быстро, по NVMe
    installipa.py App.ipa                                   # по USB-сети

Установка сама по себе простая: ядро гостя пропатчено на `bypass code signature
checks` и `all binaries in trustcache`, так что подпись не нужна — приложение
достаточно распаковать в `/Applications` и показать его SpringBoard'у через
`uicache`. Долго не хватало не установщика, а канала, по которому внести
десятки мегабайт; теперь их два, и оба здесь.

Три вещи, на которых это ломается, и что с ними сделано:

1. **Корень смонтирован только на чтение.** `/Applications` лежит в системном
   томе, и без `mount -uw /` распаковка падает на первом же файле. Перемонтировать
   надо каждый раз: до перезагрузки гостя и не дольше.
2. **Распаковывать `.ipa` надо на хосте.** `unzip` в госте есть не всегда — на
   голом бутстрапе его нет вовсе, — а `tar` есть везде. Поэтому хост
   разворачивает zip сам и посылает `.tar`.
3. **macOS кладёт в архив свои метаданные.** Без `COPYFILE_DISABLE=1` рядом с
   каждым файлом появляется `._имя`, и в `/Applications` уезжает мусор, который
   SpringBoard потом показывает как битые ресурсы.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from guestfs import Guest, NetChannel, shell_quote, human
from nvmefs import Namespace, DEFAULT_DEV, DEFAULT_NSIO

GUEST_TAR = "/var/mobile/.install.tar"


def unpack(ipa, workdir):
    """Разворачивает `.ipa` и возвращает (каталог с Payload, имя .app)."""
    with zipfile.ZipFile(ipa) as archive:
        archive.extractall(workdir)
    payload = os.path.join(workdir, "Payload")
    if not os.path.isdir(payload):
        raise IOError("в %s нет папки Payload — это не .ipa" % os.path.basename(ipa))
    apps = [n for n in os.listdir(payload) if n.endswith(".app")]
    if not apps:
        raise IOError("в Payload нет ни одного .app")
    return payload, apps[0]


def make_tar(payload, app, out):
    """Складывает .app в tar без метаданных macOS.

    zip не годится: `unzip` в госте может не оказаться, а `tar` есть всегда.
    Права внутри архива сохраняются, поэтому исполняемый бит переживёт дорогу.
    """
    env = dict(os.environ, COPYFILE_DISABLE="1")
    subprocess.run(["tar", "--no-xattrs", "-cf", out, "-C", payload, app],
                   check=True, env=env)
    return os.path.getsize(out)


def install(guest, channel, tar_path, app, progress=None):
    size = channel.push(tar_path, GUEST_TAR, progress) if progress else channel.push(tar_path, GUEST_TAR)
    target = "/Applications/" + app

    # По одной короткой команде: занятый гость теряет байты внутри длинной
    # строки, и она приходит покалеченной.
    #
    # Ни одну из них нельзя заканчивать конвейером. `guestfs` забирает код
    # возврата последней команды строки, а у конвейера это код `head`, то есть
    # ноль почти всегда: провалившийся `tar` отрапортовал бы об успехе.
    # Помечены и те шаги, на которых установка обязана остановиться.
    steps = [
        ("перемонтирую корень", "mount -uw /", True),
        ("убираю прежнюю копию", "rm -rf %s" % shell_quote(target), False),
        ("распаковываю", "tar xf %s -C /Applications" % GUEST_TAR, True),
        ("права", "chown -R root:wheel %s && chmod -R 755 %s"
                  % (shell_quote(target), shell_quote(target)), True),
        # uicache ругается, если гость старше, чем MinimumOSVersion приложения.
        # Файлы при этом уже на месте, так что это не повод считать установку
        # проваленной.
        ("регистрирую в SpringBoard", "/usr/bin/uicache -p %s" % shell_quote(target), False),
        ("прибираю", "rm -f %s" % GUEST_TAR, False),
    ]
    for label, command, critical in steps:
        out, status = guest.run(command, timeout=300)
        tail = [l.strip() for l in out.splitlines()
                if l.strip() and "$e$t" not in l and not l.startswith("e=END")]
        note = "ok" if status == 0 else "код %s: %s" % (status, tail[-1] if tail else "молча")
        print("  %-26s %s" % (label, note))
        if critical and status != 0:
            raise IOError("%s — гость ответил %s" % (label, status))

    out, status = guest.run("test -d %s && echo YES || echo NO" % shell_quote(target))
    return size, "YES" in out


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ipa")
    parser.add_argument("--port", type=int, default=4555)
    parser.add_argument("--image", help="подложка namespace'а: с ней передача идёт по NVMe")
    parser.add_argument("--dev", default=DEFAULT_DEV)
    parser.add_argument("--nsio", default=DEFAULT_NSIO)
    args = parser.parse_args()

    workdir = tempfile.mkdtemp(prefix="installipa.")
    try:
        payload, app = unpack(args.ipa, workdir)
        tar_path = os.path.join(workdir, "app.tar")
        size = make_tar(payload, app, tar_path)
        print("%s → %s (%s)" % (os.path.basename(args.ipa), app, human(size)))

        guest = Guest(port=args.port, timeout=300)
        if args.image:
            channel = Namespace(guest, args.image, args.dev, args.nsio)
            ok, detail = channel.guest_ready()
            if not ok:
                sys.stderr.write("гость не видит носитель %s: %s\n" % (args.dev, detail))
                return 1
            print("канал: NVMe %s" % args.dev)
        else:
            channel = NetChannel(guest)
            print("канал: USB-сеть")

        start = time.time()

        def show(done, total):
            took = max(time.time() - start, 0.001)
            sys.stderr.write("\r  %s из %s, %.0f КБ/с   " % (human(done), human(total), done / took / 1024))
            sys.stderr.flush()

        try:
            moved, ok = install(guest, channel, tar_path, app, show)
            sys.stderr.write("\n")
            took = time.time() - start
            print("%s за %.1f с (%.0f КБ/с)" % (human(moved), took, moved / took / 1024))
            print("установлено: /Applications/%s" % app if ok else "НЕ УСТАНОВЛЕНО")
            return 0 if ok else 1
        except Exception as exc:
            sys.stderr.write("\nне вышло: %s\n" % exc)
            guest.recover()
            return 1
        finally:
            guest.close()
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
