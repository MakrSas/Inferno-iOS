# Итог расследования SEP-паники (9 сентября 2026)

## Вывод

`split-wx` не виноват. Паника `SEP Panic: :sks /sks : ... [nvilv]` вызвана тем,
что диск гостя и состояние SEP на iPhone относятся к разным поколениям.

## Доказательство

Нативная сборка под macOS, состояние каждый раз одинаковое по построению
(qcow2-overlay поверх неприкосновенного `stage/InfernoData/root` + свежие копии
мелких файлов). Логи — в `repro-logs/`.

| прогон | split-wx | -m | состояние | итог |
|---|---|---|---|---|
| A | off | 4G | чистое | прошёл SEP |
| B | on  | 4G | чистое | прошёл SEP |
| C1| on  | 4G | чистое | прошёл SEP, сохранил новый xART |
| C3| on  | 4G | результат C1 целиком | прошёл SEP |
| C2| on  | 4G | диск из C1 + `sep_ssc` откачен | **паника** |
| D | on  | 3G | чистое | прошёл SEP |

C2 воспроизводит сигнатуру побайтно, включая адреса и тег. Достаточно откатить
один `sep_ssc` при ушедшем вперёд диске. Заодно оправданы `-m 3G`, qcow2 и
многопоточный транслятор.

## Улики на телефоне

Состояние вытащено через `xcrun devicectl device copy from --domain-type
appDataContainer --domain-identifier com.makr.inferno.U7ZXSZ37CD`.

- `sep_ssc`, `sep_nvram`, `effaceable`, `ctrl_bits`, `syscfg` побайтно равны
  `stage/` — нетронутые;
- диск другого поколения: первое `Fetched SEP-xART with CRC:` даёт `0x984a`,
  тогда как чистый `stage/root` детерминированно даёт `0xfcc9`;
- между `Fetched USER-xART` и `D-key effaceable locker` на здоровой загрузке
  идёт 11 строк `Fetched SEP-xART Locker with CRC:`; в логе с телефона их 0 —
  ровно как в C2;
- в контейнере лежат `sep_nvram 2` и `sep_ssc 2` (06:27), а `nvram` уехал в
  `.Trash` (06:23): Files.app не заменил файлы, а создал дубликаты, и половина
  набора осталась старой.

`transfer/` эталоном быть не может: там нет `root`, а `nvram` и `sep_ssc`
отличаются от `stage`.

## Что сделать на телефоне

1. Удалить `InfernoData/sep_nvram 2` и `InfernoData/sep_ssc 2`.
2. Залить согласованный набор целиком: `root.qcow2`, полученный из
   `stage/InfernoData/root`, **и** `sep_nvram sep_ssc nvram effaceable
   ctrl_bits syscfg` из того же `stage`.
3. Дальше не откатывать состояние, а держать на телефоне неизменяемую базу и
   подкладывать overlay: `qemu-img create -f qcow2 -u -F qcow2 -b <путь-базы-на-телефоне> root.qcow2`
   собирается локально, весит килобайты, база не открывается.
4. Выключать только через QMP `quit`. При `kill` записи не доходят до файлов и
   следующий запуск стартует уже рассогласованным.

За одну загрузку меняются только `sep_ssc`, `nvram` и диск; `sep_nvram` и
`effaceable` остаются нетронутыми.

## Стенд под macOS

    meson setup build-macos -Dtools=enabled -Dfuse=disabled -Dfuse_lseek=disabled -Dcocoa=disabled
    ninja -C build-macos

`fuse` не собирается с macFUSE-заголовками; в `ui/console.c:950` потеряна
запятая после `DISPLAY_TYPE_COCOA`, поэтому без GTK нужен `-Dcocoa=disabled`.

Прогон: `./macos-repro.sh <имя> fresh|reuse:<имя> on|off <маркер> [секунд]`,
`MEM=3G` меняет объём памяти. Загрузка до SEP занимает секунды.
