#!/bin/bash
# Собирает и подписывает nsio — помощника, который читает и пишет namespace
# NVMe внутри гостя.
#
# Зачем он вообще нужен: шеллу гостя блочные устройства закрыты. `dd
# if=/dev/rdisk2` отвечает `Operation not permitted` даже от root, хотя
# `/dev/urandom` читается, а `/sbin/fsck_hfs` то же устройство спокойно читает.
# Дело в правах бинарника, и с ними устройство открывается.
#
# Подпись обязательна, и именно с правами: без них AMFI убивает процесс до
# main() — в консоли видно только `Killed: 9`.
#
# Класть готовый файл в гостя надо ПОД НОВЫМ ИМЕНЕМ. Перезапись поверх старого
# по тому же пути даёт тот же `Killed: 9`: ядро помнит подпись, выданную этому
# файлу раньше, и новое содержимое ей не соответствует.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/nsio-ent}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

command -v ldid >/dev/null || { echo "нужен ldid: brew install ldid" >&2; exit 1; }

xcrun --sdk iphoneos clang -target arm64-apple-ios14.0 -isysroot "$SDK" -O2 \
    -o "$OUT" "$HERE/nsio.c"
ldid "-S$HERE/nsio.entitlements.plist" "$OUT"
echo "готово: $OUT"
ldid -e "$OUT" | grep -c disk-device-access >/dev/null && echo "права на месте"
