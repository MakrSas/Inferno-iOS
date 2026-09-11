#!/bin/bash
# Поднимает подопытного гостя на Маке с экспортом USB в сокет.
#
#   lab-up.sh [fresh]   fresh — начать с чистого состояния
#
# GUI=sdl opens a window with the guest's screen; there is none by default.
#
# DISP sets the panel. disp-scale is pixels per point: scale=1 gives four times
# fewer pixels, but iOS then draws non-Retina and falls back to @1x artwork,
# which makes the interface look wrong rather than small. To cut the work and
# keep it sharp, leave scale=2 and shrink the panel instead: 752x1336 is an
# iPhone 8, 640x1136 an SE. Widths must be a multiple of four, so that a row of
# the frame is a multiple of sixteen bytes — at 750 the guest does not finish
# booting.
#
# The host's audio is left alone. The machine creates apple-mca, which opens a
# 48 kHz output, and QEMU's coreaudio backend sets the format and the buffer
# size ON THE OUTPUT DEVICE ITSELF (AudioObjectSetPropertyData, in
# audio/coreaudio.m). On Bluetooth headphones that is heard at once: everything
# on the system drops to walkie-talkie quality for as long as the VM runs. The
# guest has no sound anyway — aop-audio is commented out in t8030.c — so the
# machine is given an empty audio backend by default. SOUND=1 restores the old
# behaviour.
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

# The SDL window scales the frame with nearest-neighbour, which shows at once
# on a non-native size. SDL2 reads hints from the environment, so no rebuild is
# needed; linear smooths at any scale.
export SDL_RENDER_SCALE_QUALITY="${SDL_RENDER_SCALE_QUALITY:-linear}"

# An empty audio backend unless asked otherwise — see the header.
QUIET_AUDIO="-audiodev none,id=quiet"
[ -n "${SOUND:-}" ] && QUIET_AUDIO=""

rm -f "$QMP"
D="$STAGE/InfernoData"
"$QEMU" \
  -L "$LAB/L" -L /opt/homebrew/share/qemu -L "$SRC/build-macos/qemu-bundle/opt/homebrew/share/qemu" \
  -accel "tcg,thread=multi,tb-size=${TB:-128}${SPLITWX:+,split-wx=$SPLITWX}" \
  -M "t8030${DISP:+,$DISP}${USBCONN:+,usb-conn-type=unix,usb-conn-addr=$SOCK},trustcache=$D/Restore/Firmware/038-44135-124.dmg.trustcache,ticket=$D/root_ticket.der,sep-fw=$D/sep-firmware.n104.RELEASE.new.img4,sep-rom=$STAGE/AppleSEPROM-Cebu-B1,kaslr-off=true" \
  -kernel "$D/Restore/kernelcache.release.iphone12b" \
  -dtb "$D/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p" \
  -append 'tlto_us=-1 mtxspin=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=3 wdt=-1 launchd_unsecure_cache=1 -vm_compressor_wk_sw' \
  -smp 4 -m "${MEM:-4G}" \
  -chardev "socket,id=serial0,host=127.0.0.1,port=4555,server=on,wait=off,logfile=${GLOG:-$LAB/guest.log},logappend=off" \
  -serial chardev:serial0 \
  -qmp "unix:$QMP,server,nowait" \
  -display "${GUI:-none}" \
  $QUIET_AUDIO \
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
