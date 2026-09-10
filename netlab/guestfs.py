#!/usr/bin/env python3
"""Передача файлов в гостя и обратно через его консоль.

    guestfs.py push    <локальный> <путь в госте>     через консоль
    guestfs.py pull    <путь в госте> <локальный>     через консоль
    guestfs.py netpush <локальный> <путь в госте>     через USB-сеть, быстро
    guestfs.py netpull <путь в госте> <локальный>     через USB-сеть, быстро
    guestfs.py run  '<команда>'
    guestfs.py recover

Консоль — единственный канал, который есть всегда: он не зависит ни от сети, ни
от пейринга и работает с той минуты, когда в госте поднялся шелл бутстрапа.

Скорости резко несимметричны. Из гостя — около 55 КБ/с: он просто печатает и
никого не ждёт. В гостя — от 1 до 13 КБ/с: там на каждые 2048 байт нужен оборот
подтверждения, и упирается всё в загрузку гостя, а не в скорость линии. Это
путь для конфигов, скриптов и небольших архивов, а не для гигабайтов.

Четыре вещи, на которых это ломалось, — все проверены на стенде:

1. **У консоли нет управления потоком.** Гость молча теряет байты, если слать
   быстрее, чем он читает: 21903 отправленных превращались в 18282 принятых.
   Отсюда окно и подтверждение на каждые PAGE байт. Окна больше 2048 снова
   начинают терять.
2. **Эхо команды неотличимо от её вывода.** Маркеры поэтому собираются в госте
   из переменных: в эхе видно `$d$t`, в выводе — уже `FIN1a2b`.
3. **bash читает с tty большими кусками.** Данные, посланные сразу за командой,
   он затянет в свой буфер вместе с командной строкой и выполнит как команды.
   Поэтому передача начинается только после того, как гость сказал «готов».
4. **Перенаправление всего цикла уводит в файл и подтверждения.** Данные идут в
   отдельный дескриптор, подтверждения — в консоль.

В госте `base64` из GNU coreutils (флаг `-d`), а не BSD (`-D`); на голом образе
может оказаться наоборот, поэтому флаг определяется на месте. `unzip` там нет
вовсе — архивы носить в `tar`.
"""
import argparse
import base64
import select
import socket
import sys
import time

CONSOLE_PORT = 4555
PAGE = 2048                 # столько байт между подтверждениями
CHUNK = 32 * 1024           # столько сырых байт между проверками
# Длина строки base64. Соблазнительно сделать шире — меньше оборотов цикла
# `read` в госте, — но проверено: при 400 куски перестают доходить целиком даже
# с тем же окном. Семьдесят шесть — то, на чём передача сходится побайтно.
WIDTH = 76
TRIES = 3
BASE64_ALPHABET = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")

STAGE_B64 = "/tmp/.guestfs.b64"
STAGE_BIN = "/tmp/.guestfs.bin"


def posix_cksum(data):
    """То же число, что печатает `cksum` в госте: CRC-32/CKSUM с длиной в хвосте."""
    table = []
    for i in range(256):
        crc = i << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
        table.append(crc)

    crc = 0
    for byte in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ table[((crc >> 24) ^ byte) & 0xFF]
    length = len(data)
    while length:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ table[((crc >> 24) ^ (length & 0xFF)) & 0xFF]
        length >>= 8
    return (~crc) & 0xFFFFFFFF


def shell_quote(path):
    """Путь для шелла гостя без единого не-ASCII байта в командной строке.

    Консоль отдаёт bash байты старше 0x7F так, что строка ломается: команда с
    кириллическим именем файла не завершается, и bash остаётся ждать внутри неё.
    `$'…'` с восьмеричными кодами записывает те же байты чистым ASCII.
    """
    raw = path.encode("utf-8")
    if all(0x20 <= b < 0x7F for b in raw):
        return "'" + path.replace("'", "'\\''") + "'"
    out = "$'"
    for b in raw:
        if 0x20 <= b < 0x7F and b not in (0x27, 0x5C):
            out += chr(b)
        else:
            out += "\\%03o" % b
    return out + "'"


def human(size):
    return "%.1f КБ" % (size / 1024) if size < 1 << 20 else "%.1f МБ" % (size / (1 << 20))


class Guest:
    def __init__(self, host="127.0.0.1", port=CONSOLE_PORT, timeout=120):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.setblocking(False)
        self.timeout = timeout
        self.buf = b""
        self.seq = int(time.time() * 1000) & 0xFFFF
        self.drain(0.4)
        self.b64 = self.decode_flag()

    def close(self):
        self.sock.close()

    # ------------------------------------------------------------------
    # Сырой ввод-вывод
    # ------------------------------------------------------------------

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            if select.select([self.sock], [], [], 0.1)[0]:
                data = self.sock.recv(1 << 20)
                if not data:
                    return
                self.buf += data

    def send(self, payload):
        if isinstance(payload, str):
            payload = payload.encode()
        while payload:
            readable, writable, _ = select.select([self.sock], [self.sock], [], 15)
            if readable:
                # Гость печатает в консоль постоянно. Если это не вычитывать,
                # его окно закроется и наша отправка встанет намертво.
                data = self.sock.recv(1 << 20)
                if not data:
                    raise IOError("консоль закрылась")
                self.buf += data
            if writable:
                payload = payload[self.sock.send(payload):]

    def expect(self, marker, timeout=None):
        """Ждёт маркер. Возвращает (что пришло до него, строку с ним)."""
        needle = marker.encode()
        end = time.time() + (timeout or self.timeout)
        while time.time() < end:
            index = self.buf.find(needle)
            if index >= 0:
                line_end = self.buf.find(b"\n", index)
                if line_end >= 0:
                    before, line = self.buf[:index], self.buf[index:line_end]
                    self.buf = self.buf[line_end + 1:]
                    return before, line.decode("utf-8", "replace")
            if select.select([self.sock], [], [], 0.5)[0]:
                data = self.sock.recv(1 << 20)
                if not data:
                    raise IOError("консоль закрылась")
                self.buf += data
        raise TimeoutError("не дождался %s" % marker)

    def nonce(self):
        self.seq += 1
        return "%04x" % (self.seq & 0xFFFF)

    # ------------------------------------------------------------------
    # Команды
    # ------------------------------------------------------------------

    def run(self, command, timeout=None):
        tag = self.nonce()
        self.send('e=END; t=%s; %s; echo "$e$t $?"\n' % (tag, command))
        before, line = self.expect("END" + tag, timeout)
        status = line.split()[-1]
        return before.decode("utf-8", "replace"), int(status) if status.isdigit() else -1

    def number(self, expression):
        """Число, посчитанное в госте, — на одной строке с маркером.

        Искать его в свободном выводе нельзя: туда попадает и эхо команды, и
        приглашение `bash-5.0#`, и строки ядра со своими числами. На строке
        маркера двусмысленности нет.
        """
        tag = self.nonce()
        self.send('v=VAL; t=%s; echo "$v$t $(%s)"\n' % (tag, expression))
        _, line = self.expect("VAL" + tag)
        fields = line.split()
        if len(fields) < 2 or not fields[1].isdigit():
            raise ValueError("вместо числа пришло %r" % line)
        return int(fields[1])

    def decode_flag(self):
        """`-d` у GNU coreutils, `-D` у BSD. Перепутанный флаг тихо даёт пустой файл."""
        out, _ = self.run("printf QUJD | /usr/bin/base64 -d 2>/dev/null")
        return "-d" if "ABC" in out else "-D"

    def recover(self):
        """Возвращает консоль в чувство: обрывает приёмный цикл и чинит режим tty.

        Ctrl-D здесь использовать нельзя, хотя он и обрывает `read`: демон bash
        поставлен без `KeepAlive`, так что выход из шелла закрывает консоль
        насмерть до перезагрузки гостя. Ctrl-C — можно и нужно: он сбрасывает
        строку, покалеченную потерей байт, и выводит из незакрытой кавычки
        (приглашение `>`), где иначе тонут все следующие команды. Приёмный цикл
        он тоже обрывает, а `EOTX` остаётся на случай сырого режима, где Ctrl-C —
        просто байт.
        """
        self.send(b"\x03")
        time.sleep(0.6)
        self.send("\nEOTX\n")
        time.sleep(0.6)
        self.send("stty sane\n")
        time.sleep(0.6)
        self.buf = b""
        try:
            self.run("true", timeout=30)
            return True
        except Exception:
            return False

    # ------------------------------------------------------------------
    # Передача
    # ------------------------------------------------------------------

    def push(self, local, remote, progress=None):
        with open(local, "rb") as handle:
            raw = handle.read()

        out, status = self.run("rm -f %s %s %s; : > %s; echo ok"
                               % (shell_quote(remote), STAGE_B64, STAGE_BIN, shell_quote(remote)))
        if status != 0:
            raise IOError("не удалось создать %s: %s" % (remote, out.strip()))

        done = 0
        for offset in range(0, len(raw), CHUNK):
            piece = raw[offset:offset + CHUNK]
            self.push_chunk(piece, remote)
            done += len(piece)
            if progress:
                progress(done, len(raw))

        got = self.number("cksum < %s | cut -d' ' -f1" % shell_quote(remote))
        want = posix_cksum(raw)
        if got != want:
            raise IOError("файл собрался неверно: cksum %d вместо %d" % (got, want))
        return len(raw)

    def push_chunk(self, piece, remote):
        encoded = base64.b64encode(piece).decode()
        lines = [encoded[i:i + WIDTH] + "\n" for i in range(0, len(encoded), WIDTH)]

        for attempt in range(TRIES):
          try:
            tag = self.nonce()
            # Данные — в дескриптор 3, подтверждения — в консоль: если
            # перенаправить весь цикл, подтверждения лягут в файл вместе с
            # данными и получатель молча соберёт мусор.
            self.send(
                'r=RDY; d=FIN; a=ACK; t=%s; exec 3> %s; echo "$r$t"; '
                'while IFS= read -r l; do '
                'if [ "$l" = "EOT$t" ] || [ "$l" = "EOTX" ]; then break; '
                'elif [ "$l" = "GO$t" ]; then echo "$a$t"; '
                'else printf "%%s\\n" "$l" >&3; fi; done; exec 3>&-; '
                '/usr/bin/base64 %s < %s > %s; '
                'echo "$d$t $(wc -c < %s) $(cksum < %s | cut -d" " -f1)"\n'
                % (tag, STAGE_B64, self.b64, STAGE_B64, STAGE_BIN, STAGE_BIN, STAGE_BIN))
            self.expect("RDY" + tag)

            pending = ""
            for line in lines:
                pending += line
                if len(pending) >= PAGE:
                    self.send(pending + "GO%s\n" % tag)
                    self.expect("ACK" + tag, timeout=60)
                    pending = ""
            self.send(pending + "EOT%s\n" % tag)

            _, marker = self.expect("FIN" + tag, timeout=300)
            fields = marker.split()
            if len(fields) >= 3 and int(fields[-2]) == len(piece) and int(fields[-1]) == posix_cksum(piece):
                out, status = self.run("cat %s >> %s" % (STAGE_BIN, shell_quote(remote)))
                if status != 0:
                    raise IOError("не удалось дописать кусок: %s" % out.strip())
                return
            reason = " ".join(fields[1:]) or "нет ответа"
          except (TimeoutError, ValueError, IOError) as exc:
            # Гость иногда занят настолько, что не успевает подтвердить вовремя.
            # Это не повод бросать передачу: приёмный цикл обрывается своим
            # признаком конца, и кусок просто посылается заново.
            reason = str(exc)
            self.recover()
          sys.stderr.write("\nкусок не дошёл (%s), повтор %d\n" % (reason, attempt + 1))
        raise IOError("кусок не удалось передать целым за %d попытки" % TRIES)

    def pull(self, remote, local, progress=None):
        _, status = self.run("test -f %s" % shell_quote(remote))
        if status != 0:
            raise IOError("нет файла %s" % remote)
        total = self.number("wc -c < %s" % shell_quote(remote))

        pieces, got, index = [], 0, 0
        while got < total:
            piece = self.pull_chunk(remote, index)
            pieces.append(piece)
            got += len(piece)
            index += 1
            if progress:
                progress(min(got, total), total)

        data = b"".join(pieces)[:total]
        with open(local, "wb") as handle:
            handle.write(data)
        return len(data)

    def pull_chunk(self, remote, index):
        """Один кусок из гостя. В консоль в любой момент влезает ядро, поэтому
        строки не из алфавита base64 отбрасываются, а результат сверяется с
        контрольной суммой, которую гость печатает рядом."""
        for attempt in range(TRIES):
            tag = self.nonce()
            self.send('s=SOF; d=FIN; t=%s; '
                      'dd if=%s bs=%d skip=%d count=1 2>/dev/null > %s; '
                      'echo "$s$t"; /usr/bin/base64 < %s; '
                      'echo "$d$t $(wc -c < %s) $(cksum < %s | cut -d" " -f1)"\n'
                      % (tag, shell_quote(remote), CHUNK, index, STAGE_BIN, STAGE_BIN,
                         STAGE_BIN, STAGE_BIN))
            self.expect("SOF" + tag)
            body, marker = self.expect("FIN" + tag, timeout=300)
            fields = marker.split()
            if len(fields) < 3:
                continue
            size, want = int(fields[-2]), int(fields[-1])

            text = body.decode("utf-8", "replace").replace("\r", "")
            clean = [line for line in text.split("\n")
                     if line and all(char in BASE64_ALPHABET for char in line)]
            try:
                data = base64.b64decode("".join(clean))
            except Exception:
                data = b""
            if len(data) == size and posix_cksum(data) == want:
                return data
            sys.stderr.write("\nкусок %d пришёл побитым, повтор %d\n" % (index, attempt + 1))
        raise IOError("кусок %d не удалось получить целым" % index)


class NetChannel:
    """Быстрый путь: данные идут по USB-сети, консоль несёт только команду.

    Гость дотягивается до хоста по адресу 10.0.2.2 — slirp переводит его в
    127.0.0.1 (`libslirp/src/socket.c`), так что хосту достаточно слушать на
    петле, а гостю — `cat` через `/dev/tcp` bash. `cat` копирует байты как есть,
    так что ни base64, ни окон с подтверждениями здесь не нужно: на стенде
    мегабайт ушёл за 2,4 с, против минут через консоль.

    Команды короткие намеренно. Консоль теряет байты и внутри одной строки,
    если гость занят, — длинная команда приходит покалеченной и оставляет bash в
    незакрытой кавычке. Короткую и проверенную контрольной суммой проще
    повторить.
    """

    HOST = "10.0.2.2"

    def __init__(self, guest):
        self.guest = guest

    def _listen(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        server.settimeout(60)
        return server, server.getsockname()[1]

    def push(self, local, remote, progress=None):
        with open(local, "rb") as handle:
            data = handle.read()
        server, port = self._listen()
        try:
            self.guest.send("exec 3<>/dev/tcp/%s/%d;cat<&3>%s;exec 3<&-\n"
                            % (self.HOST, port, shell_quote(remote)))
            conn, _ = server.accept()
        finally:
            server.close()
        with conn:
            sent = 0
            view = memoryview(data)
            while sent < len(data):
                sent += conn.send(view[sent:sent + 65536])
                if progress:
                    progress(sent, len(data))
            conn.shutdown(socket.SHUT_WR)
            conn.settimeout(120)
            while conn.recv(4096):      # гость закрывает, когда дочитал
                pass
        self._verify(remote, data)
        return len(data)

    def pull(self, remote, local, progress=None):
        _, status = self.guest.run("test -f %s" % shell_quote(remote))
        if status != 0:
            raise IOError("нет файла %s" % remote)
        total = self.guest.number("wc -c < %s" % shell_quote(remote))
        server, port = self._listen()
        try:
            self.guest.send("cat %s>/dev/tcp/%s/%d\n" % (shell_quote(remote), self.HOST, port))
            conn, _ = server.accept()
        finally:
            server.close()
        chunks, got = [], 0
        with conn:
            conn.settimeout(120)
            while True:
                piece = conn.recv(1 << 16)
                if not piece:
                    break
                chunks.append(piece)
                got += len(piece)
                if progress:
                    progress(got, total)
        data = b"".join(chunks)
        self._verify(remote, data)
        with open(local, "wb") as handle:
            handle.write(data)
        return len(data)

    def _verify(self, remote, data):
        size = self.guest.number("wc -c < %s" % shell_quote(remote))
        crc = self.guest.number("cksum < %s | cut -d' ' -f1" % shell_quote(remote))
        if size != len(data) or crc != posix_cksum(data):
            raise IOError("не сошлось: в госте %d Б, cksum %d; у нас %d Б, cksum %d"
                          % (size, crc, len(data), posix_cksum(data)))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=CONSOLE_PORT)
    sub = parser.add_subparsers(dest="action", required=True)
    p = sub.add_parser("push"); p.add_argument("local"); p.add_argument("remote")
    p = sub.add_parser("pull"); p.add_argument("remote"); p.add_argument("local")
    p = sub.add_parser("netpush"); p.add_argument("local"); p.add_argument("remote")
    p = sub.add_parser("netpull"); p.add_argument("remote"); p.add_argument("local")
    p = sub.add_parser("run"); p.add_argument("command")
    sub.add_parser("recover")
    args = parser.parse_args()

    guest = Guest(port=args.port) if args.action != "recover" else None
    if args.action == "recover":
        raw = Guest.__new__(Guest)
        raw.sock = socket.create_connection(("127.0.0.1", args.port), timeout=10)
        raw.sock.setblocking(False)
        raw.buf = b""
        raw.timeout = 60
        raw.seq = 1
        ok = raw.recover()
        raw.close()
        print("консоль в порядке" if ok else "консоль не отвечает")
        return 0 if ok else 1

    start = time.time()

    def show(done, total):
        took = max(time.time() - start, 0.001)
        sys.stderr.write("\r%s из %s, %.1f КБ/с   " % (human(done), human(total), done / took / 1024))
        sys.stderr.flush()

    try:
        if args.action == "run":
            out, status = guest.run(args.command)
            sys.stdout.write(out)
            return status
        if args.action == "push":
            size = guest.push(args.local, args.remote, show)
        elif args.action == "pull":
            size = guest.pull(args.remote, args.local, show)
        elif args.action == "netpush":
            size = NetChannel(guest).push(args.local, args.remote, show)
        else:
            size = NetChannel(guest).pull(args.remote, args.local, show)
        sys.stderr.write("\n")
        print("%s за %.1f с" % (human(size), time.time() - start))
        return 0
    except Exception as exc:
        sys.stderr.write("\nне вышло: %s\n" % exc)
        guest.recover()
        return 1
    finally:
        guest.close()


if __name__ == "__main__":
    sys.exit(main())
