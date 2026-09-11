#!/bin/bash
# Стенд, который гоняет НАСТОЯЩИЙ Swift-код приложения против живого гостя.
#
# Зачем он есть. Питоновские двойники (`guestfs.py`, `nvmefs.py`) проверяют
# протокол, но не ту половину, которая реально поедет на телефон. Однажды это
# уже стоило дня: передача падала только в приложении, потому что у сокета
# консоли стоял `SO_RCVTIMEO`, а на стенде гоняли Python. Здесь нативно под
# macOS собираются те же файлы из `app/Sources`, с заглушками вместо iOS-частей
# (`L()` и `VMConfig` — в main.swift), и говорят с гостем по TCP 4555.
#
#   ./build.sh           собрать
#   ./swifttest install App.ipa    поставить .ipa в гостя
#   ./swifttest files              файл туда-обратно со сверкой
#   ./swifttest send [МБ]          файл в «Файлы» гостя — тем же путём, что и
#                                  «Отправить файл в гостя…» на телефоне
#
# Носитель указывается переменной XFER — это тот же файл, что отдан машине как
# namespace (`-drive file=…,id=xfer,cache=none`):
#
#   XFER=/tmp/xfer.img ./swifttest install App.ipa
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../app/Sources"

# Помощник должен лежать рядом с бинарником: приложение ищет его в бандле по
# тому же относительному пути.
mkdir -p "$HERE/guest-tools"
"$HERE/../build-nsio.sh" "$HERE/guest-tools/nsio" >/dev/null

xcrun swiftc -O \
    "$SRC/Archive.swift" "$SRC/Sock.swift" "$SRC/SerialConsole.swift" \
    "$SRC/GuestFiles.swift" "$SRC/GuestChannel.swift" "$SRC/GuestInstaller.swift" \
    "$HERE/main.swift" -o "$HERE/swifttest"

echo "готово: $HERE/swifttest"
