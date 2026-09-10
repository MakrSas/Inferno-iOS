#!/bin/bash
# run2.sh <имя> <fresh|reuse:<имя>> <on|off> <маркер-остановки> [секунды]
set -uo pipefail
NAME="$1"; STATE="$2"; SPLITWX="$3"; MARK="$4"; SECS="${5:-900}"
SP="$(cd "$(dirname "$0")" && pwd)"
# Рядом с репозиторием, если не сказано иное: форк эмулятора и разложенный
# комплект гостя. Ни то, ни другое в репозитории не лежит — см. README.
SRC="${INFERNO_SRC:-$SP/inferno-src}"
STAGE="${INFERNO_STAGE:-$SP/stage}"
[ -x "$SRC/build-macos/qemu-system-aarch64" ] || {
    echo "Нет сборки под macOS: $SRC/build-macos/qemu-system-aarch64" >&2
    echo "Соберите её или укажите INFERNO_SRC=" >&2
    exit 1
}
[ -d "$STAGE/InfernoData" ] || {
    echo "Нет комплекта гостя: $STAGE/InfernoData (укажите INFERNO_STAGE=)" >&2
    exit 1
}
mkdir -p "$SP/run" "$SP/logs"
QEMU="$SRC/build-macos/qemu-system-aarch64"
RUN="$SP/run/$NAME"; LOG="$SP/logs/$NAME"; QMP="/tmp/inf-$NAME.qmp"
rm -rf "$RUN"; mkdir -p "$RUN"; rm -f "$QMP" "$LOG.serial"
if [ "$STATE" = fresh ]; then
    for f in ctrl_bits effaceable firmware nvram panic_log syscfg sep_nvram sep_ssc; do cp "$STAGE/InfernoData/$f" "$RUN/$f"; done
    qemu-img create -q -f qcow2 -F raw -b "$STAGE/InfernoData/root" "$RUN/root.qcow2"
else
    cp -c "$SP/run/${STATE#reuse:}"/* "$RUN"/ 2>/dev/null || cp "$SP/run/${STATE#reuse:}"/* "$RUN"/
fi
ACCEL="tcg,thread=multi,tb-size=128,split-wx=$SPLITWX"
D="$STAGE/InfernoData"
"$QEMU" -L "$SP/L" -L "$SRC/build-macos/qemu-bundle/opt/homebrew/share/qemu" -accel "$ACCEL" \
  -M "t8030,trustcache=$D/Restore/Firmware/038-44135-124.dmg.trustcache,ticket=$D/root_ticket.der,sep-fw=$D/sep-firmware.n104.RELEASE.new.img4,sep-rom=$STAGE/AppleSEPROM-Cebu-B1,kaslr-off=true" \
  -kernel "$D/Restore/kernelcache.release.iphone12b" -dtb "$D/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p" \
  -append 'tlto_us=-1 mtxspin=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=3 wdt=-1 -vm_compressor_wk_sw' \
  -smp 4 -m "${MEM:-4G}" -serial "file:$LOG.serial" -qmp "unix:$QMP,server,nowait" -display none \
  -drive "file=$RUN/sep_nvram,if=pflash,format=raw" -drive "file=$RUN/sep_ssc,if=pflash,format=raw" \
  -drive "file=$RUN/root.qcow2,format=qcow2,if=none,id=root" -device 'nvme-ns,drive=root,bus=nvme-bus.0,nsid=1,nstype=1,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$RUN/firmware,format=raw,if=none,id=firmware" -device 'nvme-ns,drive=firmware,bus=nvme-bus.0,nsid=2,nstype=2,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$RUN/syscfg,format=raw,if=none,id=syscfg" -device 'nvme-ns,drive=syscfg,bus=nvme-bus.0,nsid=3,nstype=3,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$RUN/ctrl_bits,format=raw,if=none,id=ctrl_bits" -device 'nvme-ns,drive=ctrl_bits,bus=nvme-bus.0,nsid=4,nstype=4,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$RUN/nvram,if=none,format=raw,id=nvram" -device 'apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$RUN/effaceable,format=raw,if=none,id=effaceable" -device 'nvme-ns,drive=effaceable,bus=nvme-bus.0,nsid=6,nstype=6,logical_block_size=4096,physical_block_size=4096' \
  -drive "file=$RUN/panic_log,format=raw,if=none,id=panic_log" -device 'nvme-ns,drive=panic_log,bus=nvme-bus.0,nsid=7,nstype=8,logical_block_size=4096,physical_block_size=4096' \
  > "$LOG.stdout" 2>&1 &
PID=$!; echo "[$NAME] pid=$PID splitwx=$SPLITWX state=$STATE"
RES=timeout
for i in $(seq 1 "$SECS"); do
    kill -0 "$PID" 2>/dev/null || { RES="процесс умер на ${i}с"; break; }
    grep -q "SEP Panic" "$LOG.serial" 2>/dev/null && { RES="SEP PANIC на ${i}с"; break; }
    grep -q "$MARK" "$LOG.serial" 2>/dev/null && { RES="маркер достигнут на ${i}с"; break; }
    sleep 1
done
echo "[$NAME] $RES"
# корректное выключение, чтобы записи на диск дошли
python3 - "$QMP" <<'PY' 2>/dev/null
import socket,sys,json,time
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.recv(65536)
s.sendall(b'{"execute":"qmp_capabilities"}\n'); time.sleep(0.3); s.recv(65536)
s.sendall(b'{"execute":"quit"}\n'); time.sleep(1)
PY
for _ in $(seq 1 30); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -9 "$PID" 2>/dev/null
echo "[$NAME] завершено, serial=$(wc -c < "$LOG.serial") б"
