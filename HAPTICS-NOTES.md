# Вибрация: план и что положить в JB-образ

## Решение

Не эмулировать LEAP, а перехватывать вибрацию **внутри гостя** — как сделано в
vphone (`~/Documents/vphone/vphone-cli-source/scripts/haptic-forwarder/`).

Шаги 1–2 из `HAPTICS-PROMPT.md` (вернуть узлы device tree, реверсить LEAP)
при этом не нужны. Они остаются актуальными только если однажды понадобится
настоящая форма волны, а не факт «сыграй».

Причина: в комментарии к твику vphone зафиксирован результат живого теста —
`AOPHaptics.framework` в виртуалке не загружается ни в одном процессе, iOS
обрывает цепочку раньше, когда физического актуатора нет. Рабочая точка хука
нашлась слоем выше, в UIKit, и от железа она не зависит.

## Путь события

    твик в госте → маркер в /dev/console → приложение читает поток serial → CHHapticEngine

Правок в QEMU нет. Сети не требует: bash-демон из бутстрапа ChefKiss уже сидит
на `/dev/console`, а приложение и так читает serial (`app/Sources/SerialConsole.swift`,
`LogCapture.swift`).

## Что положить в JB-образ

1. **Бутстрап ChefKiss** — https://chefkiss.dev/guides/inferno-post-setup/jailbreak-bootstrap/
   Даёт root-bash на serial плюс `ls`, `ioreg`, `apt`.
2. **Загрузочный аргумент** `launchd_unsecure_cache=1` в `-append`.
   Без него правленый `launchd.plist` не подхватится.
3. **Dylib твика** на rootfs.
4. **`DYLD_INSERT_LIBRARIES`** в записи SpringBoard в том же
   `/System/Library/xpc/launchd.plist`, который правится на шаге fs-patches.
   Загрузчик твиков (ellekit) **не нужен**: в ядре уже пропатчены обход
   проверки подписи и trustcache (см. `TODO.md` §2), а `apt` потребовал бы сети.

## Не проверено (проверить до сборки образа)

**Есть ли в UIKitCore от iOS 14 селекторы `_playFeedback:`.** vphone хукал
свежую iOS из PCC research VM, там их три перегрузки:

    -[UIFeedbackGenerator _playFeedback:]
    -[UIFeedbackGenerator _playFeedback:atLocation:]
    -[UIFeedbackGenerator _playFeedback:withMinimumIntervalPassed:since:prefersRegularPace:atLocation:]

Проверяется офлайн, без загрузки ВМ и без записи на диск: примонтировать `root`
только на чтение, вытащить UIKitCore из `dyld_shared_cache_arm64e`, посмотреть
таблицу символов. Если селекторов нет — точку хука искать выше (CoreHaptics,
`AudioServicesPlaySystemSound`) или ниже, и это надо знать **до** сборки образа.

## Улучшение против vphone

Хук первым аргументом получает тип фидбэка (`NSInteger`): light/medium/heavy,
success/warning/error. vphone его выбрасывает — трекпад Мака умеет только один
щелчок `.generic`. На айфоне через `CHHapticEngine` этот тип отображается в
интенсивность и резкость, то есть отклики будут различимыми.

## Осторожно

Правка rootfs двигает поколение диска. По `FINDINGS.md` рассинхрон диска и
`sep_ssc` даёт панику `sks`. Патчить базу, затем пересоздавать overlay и
пересинхронизировать копию на телефоне целиком.
