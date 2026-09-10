#!/data/data/com.termux/files/usr/bin/bash
# ChefKiss Inferno on Android (Termux) — TCG/MTTCG, вывод по VNC.
set -euo pipefail

BASE="$HOME"
DATA="$BASE/InfernoData"
QEMU="$BASE/inferno-src/build/qemu-system-aarch64"
SEPROM="$BASE/AppleSEPROM-Cebu-B1"
SOCK="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/InfernoUSBRemote"

# multi (по умолчанию) | single — для сравнения
THREADS="${INFERNO_THREADS:-multi}"
TBSIZE="${INFERNO_TB_SIZE:-128}"
SMP="${INFERNO_SMP:-4}"   # 3 ядра AP + SEP; при 7 machine init съедает ~1.4 ГБ на subpage-структуры
MEM="${INFERNO_MEM:-4G}"
VNCDISP="${INFERNO_VNC:-127.0.0.1:0}"
# Разрешение гостя. 828x1792 при масштабе 2 — панель iPhone 11 целиком;
# 414x896 при масштабе 1 даёт ту же раскладку интерфейса вчетверо дешевле,
# а VNC-клиент растягивает картинку обратно.
DISPW="${INFERNO_DISP_WIDTH:-828}"
DISPH="${INFERNO_DISP_HEIGHT:-1792}"
DISPS="${INFERNO_DISP_SCALE:-2}"

for f in "$QEMU" "$DATA/root" "$SEPROM"; do
    [ -e "$f" ] || { echo "Нет файла: $f" >&2; exit 1; }
done

rm -f "$SOCK"
: > "$BASE/inferno-serial.log"

set -- \
    -accel "tcg,thread=$THREADS,tb-size=$TBSIZE" \
    -M "t8030,usb-conn-type=unix,usb-conn-addr=$SOCK,trustcache=$DATA/Restore/Firmware/038-44135-124.dmg.trustcache,ticket=$DATA/root_ticket.der,sep-fw=$DATA/sep-firmware.n104.RELEASE.new.img4,sep-rom=$SEPROM,kaslr-off=true,disp-width=$DISPW,disp-height=$DISPH,disp-scale=$DISPS" \
    -kernel "$DATA/Restore/kernelcache.release.iphone12b" \
    -dtb "$DATA/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p" \
    -append 'tlto_us=-1 mtxspin=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=3 wdt=-1 -vm_compressor_wk_sw' \
    -smp "$SMP" -m "$MEM" \
    -serial "file:$BASE/inferno-serial.log" \
    -qmp "unix:$BASE/inferno-qmp.sock,server,nowait" \
    -L "$BASE/inferno-src/build/qemu-bundle/usr/local/share/qemu" \
    -vnc "$VNCDISP" \
    -drive "file=$DATA/sep_nvram,if=pflash,format=raw" \
    -drive "file=$DATA/sep_ssc,if=pflash,format=raw" \
    -drive "file=$DATA/root,format=raw,if=none,id=root" \
    -device 'nvme-ns,drive=root,bus=nvme-bus.0,nsid=1,nstype=1,logical_block_size=4096,physical_block_size=4096' \
    -drive "file=$DATA/firmware,format=raw,if=none,id=firmware" \
    -device 'nvme-ns,drive=firmware,bus=nvme-bus.0,nsid=2,nstype=2,logical_block_size=4096,physical_block_size=4096' \
    -drive "file=$DATA/syscfg,format=raw,if=none,id=syscfg" \
    -device 'nvme-ns,drive=syscfg,bus=nvme-bus.0,nsid=3,nstype=3,logical_block_size=4096,physical_block_size=4096' \
    -drive "file=$DATA/ctrl_bits,format=raw,if=none,id=ctrl_bits" \
    -device 'nvme-ns,drive=ctrl_bits,bus=nvme-bus.0,nsid=4,nstype=4,logical_block_size=4096,physical_block_size=4096' \
    -drive "file=$DATA/nvram,if=none,format=raw,id=nvram" \
    -device 'apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram,logical_block_size=4096,physical_block_size=4096' \
    -drive "file=$DATA/effaceable,format=raw,if=none,id=effaceable" \
    -device 'nvme-ns,drive=effaceable,bus=nvme-bus.0,nsid=6,nstype=6,logical_block_size=4096,physical_block_size=4096' \
    -drive "file=$DATA/panic_log,format=raw,if=none,id=panic_log" \
    -device 'nvme-ns,drive=panic_log,bus=nvme-bus.0,nsid=7,nstype=8,logical_block_size=4096,physical_block_size=4096'

if [ -n "${INFERNO_GDB:-}" ]; then
    exec gdb -q -batch -ex "set confirm off" -ex "handle SIGUSR1 SIGUSR2 SIGPIPE nostop noprint pass" -ex run -ex "bt 30" --args "$QEMU" "$@"
fi
exec "$QEMU" "$@"
