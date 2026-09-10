#!/bin/bash
# Готовит каталог состояния для прогона, не трогая эталон.
#
#   lab-seed.sh <куда> <эталон>
#
# Мелкие файлы копируются, диск подкладывается оверлеем поверх эталонного
# qcow2 — эталон открывается только на чтение. Набор остаётся согласованным:
# и диск, и SEP-состояние берутся из одной точки. Откатывать их по отдельности
# нельзя, см. FINDINGS.md.
set -euo pipefail

DST="${1:?куда}"
SRC="${2:?эталон}"

[ -f "$SRC/root.qcow2" ] || { echo "Нет $SRC/root.qcow2" >&2; exit 1; }

rm -rf "$DST"
mkdir -p "$DST"
for f in ctrl_bits effaceable firmware nvram panic_log syscfg sep_nvram sep_ssc; do
    cp "$SRC/$f" "$DST/$f"
done
qemu-img create -q -f qcow2 -F qcow2 -b "$(cd "$SRC" && pwd)/root.qcow2" "$DST/root.qcow2"
echo "Готово: $DST (диск — оверлей поверх $SRC/root.qcow2)"
