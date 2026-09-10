#!/bin/bash
# Ставит jailbreak-бутстрап ChefKiss в смонтированный том System гостя.
#
#   sudo ./install-bootstrap.sh
#
# Единственный шаг, которому нужен root: файлы в образе принадлежат root, и
# распаковка обязана сохранить владельца и права, иначе бутстрап не заработает.
#
# Что делает:
#   1. распаковывает strap.tar.lzma в том System;
#   2. добавляет в кэш служб launchd демон bash, привязанный к /dev/console —
#      именно это превращает серийную консоль гостя в интерактивный шелл.
#
# Повторный запуск безопасен: демон добавляется только если его ещё нет.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
VOL=/Volumes/System
STRAP="$LAB/strap.tar.lzma"
FULL="$LAB/cydia.tar.lzma"
CACHE="$VOL/System/Library/xpc/launchd.plist"

[ "$(id -u)" -eq 0 ] || { echo "Нужен root: sudo $0" >&2; exit 1; }
[ -f "$STRAP" ] || { echo "Нет архива: $STRAP" >&2; exit 1; }
[ -f "$CACHE" ] || { echo "Том System не смонтирован или это не он: нет $CACHE" >&2; exit 1; }

# Убеждаемся, что это гость, а не системный том Мака.
grep -q "com.apple.mobile" "$CACHE" 2>/dev/null || { echo "$CACHE не похож на кэш служб iOS" >&2; exit 1; }

echo "==> Резервная копия кэша служб"
[ -f "$LAB/launchd.plist.orig" ] || cp "$CACHE" "$LAB/launchd.plist.orig"

echo "==> Распаковка core-бутстрапа в $VOL"
tar xf "$STRAP" -C "$VOL"

if [ -f "$FULL" ]; then
    echo "==> Распаковка полного бутстрапа (Cydia, база dpkg, apt)"
    tar xf "$FULL" -C "$VOL"
    # Репозиторий, из которого этот бутстрап собран; без него apt пуст.
    mkdir -p "$VOL/etc/apt/sources.list.d"
    printf 'deb https://apt.bingner.com/ ./\n' > "$VOL/etc/apt/sources.list.d/bingner.list"
    chown 0:0 "$VOL/etc/apt/sources.list.d/bingner.list"
fi

echo "==> Добавляю демон bash на /dev/console"
python3 - "$CACHE" <<'PY'
import plistlib, sys

path = sys.argv[1]
with open(path, "rb") as f:
    root = plistlib.load(f)

daemons = root["LaunchDaemons"]
key = "/System/Library/LaunchDaemons/bash.plist"
if key in daemons:
    print("   уже был, ничего не меняю")
else:
    daemons[key] = {
        "EnablePressuredExit": False,
        # Без этого консоль одноразовая: любой `exit` или Ctrl-D закрывает шелл
        # навсегда, и до перезагрузки в гостя больше не попасть.
        "KeepAlive": True,
        "Label": "com.apple.bash",
        "POSIXSpawnType": "Interactive",
        "ProgramArguments": ["/bin/bash"],
        "RunAtLoad": True,
        "StandardErrorPath": "/dev/console",
        "StandardInPath": "/dev/console",
        "StandardOutPath": "/dev/console",
        "Umask": 0,
        "UserName": "root",
    }
    with open(path, "wb") as f:
        plistlib.dump(root, f, fmt=plistlib.FMT_XML)
    print(f"   добавлено, всего демонов: {len(daemons)}")
PY

echo "==> Сбрасываю кэши на диск"
sync

echo
echo "Готово. Проверка:"
ls -l "$VOL/bin/bash" 2>/dev/null || echo "  ВНИМАНИЕ: /bin/bash не появился"
ls -d "$VOL/Library/dpkg" 2>/dev/null && echo "  база dpkg на месте" || echo "  ВНИМАНИЕ: базы dpkg нет"
ls -d "$VOL/Applications/Cydia.app" 2>/dev/null >/dev/null && echo "  Cydia установлена"
echo
echo "Дальше — уже внутри гостя, через терминал в приложении:"
echo "  /usr/libexec/cydia/firmware.sh    # регистрирует системные пакеты"
echo "  apt update && apt install fastfetch"
