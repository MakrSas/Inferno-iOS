# Правила проекта

## Куда кладётся собранный `.ipa`

Готовый `.ipa` при ручной сборке лежит **в корне проекта** — `Inferno.ipa`,
рядом с `README.md`. Не в `app/`, не в `app/.build/`. Это то место, откуда его
забирают руками: открыть в Finder, скормить сайдлоадеру, отправить на телефон.

Собирается он так:

```bash
cd app && ./build.sh
```

`build.sh` сам кладёт результат куда надо; путь считать не нужно.

**В CI путь другой, и это намеренно.** Рабочий процесс
(`.github/workflows/build-ipa.yml`) забирает артефакт из `app/Inferno.ipa` и
падает, если файла там нет. Поэтому `build.sh` смотрит на `GITHUB_ACTIONS`:
внутри CI пишет по-старому, снаружи — в корень. Меняя одно, проверяйте второе.

`*.ipa` целиком в `.gitignore`, так что в репозиторий сборка не попадает ни из
корня, ни из `app/`.

## Три сборки из одних исходников — проверять все

`app/Sources` — один набор исходников на три приложения. Всё, что есть только
на одной платформе, стоит за `#if os(iOS)` / `#if os(macOS)`; разные написания
одного и того же (картинки, модификаторы навигации) — в `Platform.swift`.

| Что | Команда (из `app/`) | Результат в корне | Библиотека эмулятора |
|---|---|---|---|
| iPhone / iPad | `./build.sh` | `Inferno.ipa` | `~/inferno-ios/build/inferno` (`-Dhvf=disabled`) |
| iPad M1/M2 с HVF, для TrollStore | `INFERNO_HVF=1 ./build.sh` | `Inferno-HVF.tipa` | `~/inferno-ios/build/inferno-hvf` + `~/inferno-ios/build/hypervisor` |
| Mac | `./build-mac.sh` | `Inferno-macOS.zip` (само приложение — `app/.build-mac/Inferno.app`) | `~/inferno-ios/build/inferno-macos` (нативная, `-Dhvf=enabled`) |

**Перед каждым коммитом в `app/`** собираются все три. Минимум, если сборка
долгая или библиотеки нет под рукой, — проверка типов под обе платформы, и
полная сборка той, которую правили:

```bash
xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios16.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" -parse-as-library app/Sources/*.swift
xcrun --sdk macosx swiftc -typecheck -target arm64-apple-macos15.0 -sdk "$(xcrun --sdk macosx --show-sdk-path)" -parse-as-library app/Sources/*.swift
```

Правка «только для мака» или «только для iOS» в общем файле — всё равно
проверка обеих: именно так ломается соседняя платформа.

**Правка в эмуляторе** (`inferno-src`) — пересобрать все три библиотеки:
`build.sh` и `build-mac.sh` берут готовый дылиб и сами его не собирают.

```bash
ninja -C ~/inferno-ios/build/inferno libqemu-aarch64-softmmu.dylib
ninja -C ~/inferno-ios/build/inferno-hvf libqemu-aarch64-softmmu.dylib
ninja -C ~/inferno-ios/build/inferno-macos libqemu-aarch64-softmmu.dylib
```

## Ветки держатся вместе

- Приложение: `dev` — рабочая, `main` — то, из чего выходят релизы (теги
  `vX.Y`), `hvf` и `macos` — на том же коммите, что `dev`. Любая из веток
  собирает все три варианта; отдельной «ветки для мака» с другим кодом нет.
- Форк эмулятора: `ios` — основная, `ios-hvf` — на том же коммите.

После работы: коммит в `dev` → `main` (перемоткой, либо PR) → `hvf` и `macos`
перемотать до того же коммита → всё запушить. Если в `main` пришло что-то мимо
`dev`, сначала влить `main` в `dev`: однажды ветки так уже разошлись, и PR
получил конфликт.

## Проверка мак-приложения без мыши

- `open app/.build-mac/Inferno.app --args -autostart YES` — машина стартует сама;
  `-forceChrome YES` — рамка с панелью видна без наведения; `-openSettings YES`
  — окно параметров открыто. Аргументы живут только в процессе.
- Окно снимается `screencapture -x -o -l <id окна>`, id — через
  `CGWindowListCopyWindowInfo`.
- Закрывать — `osascript -e 'tell application id "com.makr.inferno.mac" to quit'`:
  машина получает QMP `quit` и дописывает диски.
- После каждой пересборки macOS заново спрашивает доступ к «Документам»
  (ad-hoc подпись каждый раз новая) — до ответа приложение висит на старте.
- Стенд `netlab/lab-up.sh` и приложение не запускать одновременно: оба на
  портах 4555/4556.
