#!/bin/bash
# Поднимает подопытного гостя на Маке с экспортом USB в сокет.
#
#   lab-up.sh [fresh]   fresh — начать с чистого состояния
#
# GUI=sdl — открыть окно с экраном гостя (по умолчанию окна нет).
#
# DISP задаёт панель: disp-scale — это пиксели на точку. scale=1 отдаёт вчетверо
# меньше пикселей, но iOS рисует не-Retina и берёт @1x-ресурсы — интерфейс
# «плывёт». Чтобы снять нагрузку и сохранить чёткость, лучше оставить scale=2 и
# уменьшить панель: 750x1334 — как iPhone 8, 640x1136 — как SE.
#
# Звук хоста не трогаем: машина создаёт apple-mca, тот открывает выход 48 кГц,
# а бэкенд coreaudio задаёт формат и размер буфера НА САМОМ УСТРОЙСТВЕ вывода
# (`AudioObjectSetPropertyData`, `hw/../audio/coreaudio.m`). На Bluetooth-
# наушниках это слышно сразу: звук всей системы садится до «рации», пока ВМ
# жива. Гостевого звука всё равно нет — aop-audio в t8030.c закомментирован, —
# поэтому по умолчанию отдаём машине пустой звуковой бэкенд. SOUND=1 вернёт
# прежнее поведение.
#
# Состояние живёт в netlab/state и переживает перезапуски: оверлей поверх
# неприкосновенного stage/InfernoData/root плюс копии мелких файлов. Базовый
# образ не меняется, так что рассогласование диска и SEP невозможно.
set -uo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$LAB/.." && pwd)"
SRC="$P/inferno-src"
STAGE="$P/stage"
QEMU="$SRC/build-macos/qemu-system-aarch64"
STATE="${STATE:-$LAB/state}"
SOCK="${SOCK:-/tmp/iusb.sock}"
QMP="${QMP:-/tmp/inf-lab.qmp}"

pgrep -f "build-macos/qemu-system-aarch64" >/dev/null && { echo "Уже запущена."; exit 0; }

if [ "${1:-}" = fresh ] || [ ! -d "$STATE" ]; then
    rm -rf "$STATE"; mkdir -p "$STATE"
    for f in ctrl_bits effaceable firmware nvram panic_log syscfg sep_nvram sep_ssc; do
        cp "$STAGE/InfernoData/$f" "$STATE/$f"
    done
    qemu-img create -q -f qcow2 -F raw -b "$STAGE/InfernoData/root" "$STATE/root.qcow2"
fi

mkdir -p "$LAB/L/icons"
cp -f "$SRC/ui/icons/CKQEMUBootSplash_512x512@2x.png" "$LAB/L/icons/CKQEMUBootSplash@2x.png"

# Окно SDL растягивает кадр ближайшим соседом — на нестандартном разрешении
# это видно сразу. SDL2 читает хинты из окружения, так что пересборка не нужна;
# linear сглаживает при любом масштабе.
export SDL_RENDER_SCALE_QUALITY="${SDL_RENDER_SCALE_QUALITY:-linear}"

# The window keeps the pointer visible: the guest is driven by touches, and a
# hidden cursor leaves you aiming blind.
case "${GUI:-none}" in
    sdl) DISPLAY_ARG="sdl,show-cursor=on" ;;
    *)   DISPLAY_ARG="${GUI:-none}" ;;
esac

# What the machine's sound card is wired to. Named with -global, because the MCA
# is created by the machine and cannot be given the property any other way — and
# in the long form, because the short one (`-global driver=apple.mca,property=audiodev,value=snd`)
# splits the name at its FIRST dot and looks for a type called `apple`. That
# misses silently: the card is never registered, the guest plays into nothing,
# and the only sign is `invalid class name` in the log.
#
#   (unset)    nothing on the other end — the host's own audio is untouched
#   SOUND=wav  what the guest plays is written to a file, host still untouched
#   SOUND=1    the host's own output, which on a Mac means coreaudio; see header
case "${SOUND:-}" in
    wav) AUDIO="-audiodev wav,id=snd,path=${WAV:-$LAB/guest-audio.wav} -global driver=apple.mca,property=audiodev,value=snd" ;;
    "")  AUDIO="-audiodev none,id=quiet -global driver=apple.mca,property=audiodev,value=quiet" ;;
    *)   AUDIO="" ;;
esac

rm -f "$QMP"
D="$STAGE/InfernoData"
"$QEMU" \
  -L "$LAB/L" -L /opt/homebrew/share/qemu -L "$SRC/build-macos/qemu-bundle/opt/homebrew/share/qemu" \
  -accel "tcg,thread=multi,tb-size=${TB:-128}${SPLITWX:+,split-wx=$SPLITWX}" \
  -M "t8030${DISP:+,$DISP}${USBCONN:+,usb-conn-type=unix,usb-conn-addr=$SOCK},trustcache=$D/Restore/Firmware/038-44135-124.dmg.trustcache,ticket=$D/root_ticket.der,sep-fw=$D/sep-firmware.n104.RELEASE.new.img4,sep-rom=$STAGE/AppleSEPROM-Cebu-B1,kaslr-off=true" \
  -kernel "$D/Restore/kernelcache.release.iphone12b" \
  -dtb "$D/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p" \
  -append "tlto_us=-1 mtxspin=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=${SERIAL:-3} wdt=-1 launchd_unsecure_cache=1 -vm_compressor_wk_sw${AUDIO_BOOTARGS:-}" \
  -smp 4 -m "${MEM:-4G}" \
  -chardev "socket,id=serial0,host=127.0.0.1,port=4555,server=on,wait=off,logfile=${GLOG:-$LAB/guest.log},logappend=off" \
  -serial chardev:serial0 \
  -qmp "unix:$QMP,server,nowait" \
  -display "$DISPLAY_ARG" \
  $AUDIO \
  ${VNC:+-vnc 127.0.0.1:0,password=on} \
  ${NET:+-netdev user,id=n0} \
  ${NET:+-device apple-ncm-host,netdev=n0,conn-addr=$SOCK} \
  ${EXTRA:+$EXTRA} \
  -drive "file=$STATE/sep_nvram,if=pflash,format=raw" \
  -drive "file=$STATE/sep_ssc,if=pflash,format=raw" \
  -drive "file=$STATE/root.qcow2,format=qcow2,if=none,id=root" \
  -device 'nvme-ns,drive=root,bus=nvme-bus.0,nsid=1,nstype=1,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$STATE/firmware,format=raw,if=none,id=firmware" \
  -device 'nvme-ns,drive=firmware,bus=nvme-bus.0,nsid=2,nstype=2,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$STATE/syscfg,format=raw,if=none,id=syscfg" \
  -device 'nvme-ns,drive=syscfg,bus=nvme-bus.0,nsid=3,nstype=3,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$STATE/ctrl_bits,format=raw,if=none,id=ctrl_bits" \
  -device 'nvme-ns,drive=ctrl_bits,bus=nvme-bus.0,nsid=4,nstype=4,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$STATE/nvram,if=none,format=raw,id=nvram" \
  -device 'apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$STATE/effaceable,format=raw,if=none,id=effaceable" \
  -device 'nvme-ns,drive=effaceable,bus=nvme-bus.0,nsid=6,nstype=6,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$STATE/panic_log,format=raw,if=none,id=panic_log" \
  -device 'nvme-ns,drive=panic_log,bus=nvme-bus.0,nsid=7,nstype=8,logical_block_size=4096,physical_block_size=4096' \
  > "${QLOG:-$LAB/qemu.log}" 2>&1 &

echo "Запущена, pid=$!. Гостевой лог: ${GLOG:-$LAB/guest.log}, USB-сокет: $SOCK"
