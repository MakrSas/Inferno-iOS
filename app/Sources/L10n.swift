import Foundation
import SwiftUI

/// Interface language.
///
/// The strings are written in Russian in the source and translated on the way
/// out. That keeps the diff small and lets an untranslated string fall back to
/// the original rather than showing a key.
enum AppLanguage: String, CaseIterable {
    case system, ru, en

    var title: String {
        switch self {
        case .system: return "Auto"
        case .ru:     return "Русский"
        case .en:     return "English"
        }
    }
}

enum L10n {
    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .system
    }

    static var showEnglish: Bool {
        switch language {
        case .ru:     return false
        case .en:     return true
        case .system: return !(Locale.preferredLanguages.first ?? "en").hasPrefix("ru")
        }
    }

    static let table: [String: String] = [
        // Missing until the audit found them
        "файла нет": "no such file",
        "соединение закрыто": "the connection was closed",
        "сервер отклонил рукопожатие": "the server refused the handshake",
        "сервер требует пароль VNC": "the server wants a VNC password",
        "процессор простаивает — гость не исполняется":
            "the processor is idle — the guest is not running",
        "загружено ~%.1f ядра — гость исполняется":
            "about %.1f cores busy — the guest is running",
        "0x%llx — вне загруженных образов (код, сгенерированный транслятором)":
            "0x%llx — outside every loaded image (code the translator generated)",
        "КУДА КЛАСТЬ ФАЙЛЫ.txt": "WHERE TO PUT FILES.txt",
        "Папки уже созданы, файлы можно класть прямо в них. Подробности — в файле «КУДА КЛАСТЬ ФАЙЛЫ.txt» там же.":
            "The folders are already there; the files go straight into them. The details are in “WHERE TO PUT FILES.txt” beside them.",
        "Для Secure Enclave нужны 4 ядра И multi одновременно. При 2 ядрах или при single он паникует на инициализации хранилища ключей — проверено на обоих устройствах.":
            "The Secure Enclave needs 4 cores AND multi together. With 2 cores, or with single, it panics initialising the key store — seen on both devices.",

        // Interpolated, so held as format strings
        "Параметры: %d vCPU, %@, tcg %@": "Settings: %d vCPU, %@, tcg %@",
        "JIT: есть (%@)": "JIT: yes (%@)",
        "JIT: нет — %@": "JIT: no — %@",
        "Работает · %d×%d": "Running · %d×%d",
        "Остановлена (код %d)": "Stopped (code %d)",
        "Ошибка: %@": "Error: %@",
        "JIT недоступен — %@.\nБез него транслятор не сможет выделить буфер, и машина не запустится.":
            "No JIT — %@.\nWithout it the translator cannot get its buffer and the machine will not start.",
        "Экран %d×%d подключён, ждём первый кадр": "Screen %d×%d attached, waiting for the first frame",
        "Экран недоступен: %@": "No screen: %@",
        "%.0f КБ": "%.0f KB",
        "%.1f МБ": "%.1f MB",
        "%@ за %.1f с · %.0f КБ/с": "%@ in %.1f s · %.0f KB/s",
        "%.1f МБ/с": "%.1f MB/s",
        "%.0f КБ/с": "%.0f KB/s",
        "%.0f Б/с": "%.0f B/s",
        "%@ из %@": "%@ of %@",
        "%d МБ": "%d MB",
        "Нет такого файла в госте: %@": "No such file in the guest: %@",
        "Файл не сошёлся по контрольной сумме (%@).": "The file did not match its checksum (%@).",
        "Ошибка ввода-вывода: %@": "Input/output error: %@",

        "Гость не подключился к приложению: команда не дошла или сеть не работает.": "The guest never connected to the app: the command did not arrive or the network is down.",
        "Шелл гостя не отвечает. Передача файлов работает только с бутстрапом, где на консоли сидит bash.": "The guest's shell is not answering. File transfer needs the bootstrap with bash on the console.",
        "Не удалось подготовить папку для файлов в госте: он слишком занят. Попробуйте ещё раз.":
            "The folder for files could not be made ready in the guest: it is too busy. Try again.",
        "Сеть в госте не поднялась. Нажмите «Поднять сеть в госте» и попробуйте снова.": "The guest's network did not come up. Tap “Bring the network up in the guest” and try again.",
        "Включите «Интернет через USB» в параметрах: файлы идут по той же сети.": "Turn on “Internet over USB” in the settings: files travel over the same network.",
        "Файл появится в папке Guest приложения — её видно в «Файлах».": "The file will appear in the app's Guest folder, visible in the Files app.",
        "Забрать": "Fetch",
        "Путь в госте": "Path in the guest",
        "Забрать файл из гостя": "Fetch a file from the guest",
        "Забрать файл из гостя…": "Fetch a file from the guest…",
        "Отправить файл в гостя…": "Send a file to the guest…",
        "Файлы": "Files",
        // Screen and network, added with the built-in display
        "Встроенный вывод": "Built-in output",
        "Приложение читает кадры прямо из памяти эмулятора и берёт только перерисованные строки. Ни сокета, ни кодирования.":
            "The app reads frames straight out of the emulator's memory and takes only the rows that were redrawn. No socket, no encoding.",
        "Картинка идёт через VNC-сервер эмулятора по локальной петле кодировкой Raw: весь кадр сравнивается, кодируется, пересылается и разбирается заново. Медленнее, зато этот путь давно обкатан.":
            "The picture goes through the emulator's VNC server over the loopback in the Raw encoding: the whole frame is compared, encoded, sent and taken apart again. Slower, but this path has years of use behind it.",
        "Картинка не готовится вовсе: ничего не копируется и не кодируется. Остаётся только консоль гостя.":
            "No picture is prepared at all: nothing is copied or encoded. Only the guest's console is left.",
        "Сглаживать при растягивании": "Smooth when stretching",
        "Экран гостя всегда растягивается на весь экран телефона. Без сглаживания видны квадратные пиксели, со сглаживанием картинка мягче. На скорость гостя не влияет ни то, ни другое.":
            "The guest's screen is always stretched to fill the phone's. Without smoothing the pixels show as squares; with it the picture is softer. Neither changes how fast the guest runs.",
        "Поднимать интерфейс в госте": "Bring the interface up in the guest",
        "iOS не всегда включает свой конец связи: интерфейс появляется и тут же гасится. Если через минуту адрес так и не получен, приложение само выполнит в консоли гостя «ipconfig set en0 DHCP». Нужен бутстрап с шеллом на консоли.":
            "iOS does not always switch its own end of the link on: the interface appears and is put straight back down. If there is still no address after a minute, the app runs `ipconfig set en0 DHCP` in the guest's console itself. Needs the bootstrap with a shell on the console.",
        "Поднять сеть в госте": "Bring the network up in the guest",
        "Сеть: прошу гостя поднять en0…": "Network: asking the guest to bring en0 up…",
        "Сеть: гость получил адрес.": "Network: the guest has an address.",
        " · сеть есть": " · network up",
        "в этой сборке библиотеки нет встроенного вывода":
            "this build of the library has no built-in output",
        // The redesign: one menu, one settings screen
        "Вид": "View",
        "Сеть: консоль занята, попрошу позже.": "Network: the console is busy, will ask later.",
        "Счётчик кадров": "Frame counter",
        "Панель": "Panel",
        "Звук": "Sound",
        "Звук гостя (опыт)": "The guest's sound (experimental)",
        "Вывод звука на телефоне: своя дорожка через AudioUnit, чужую музыку не глушит и профиль Bluetooth-наушников не портит. Тумблер описывает машине звуковое железо — динамик, шину I2S и сопроцессор, — а без него гостю о звуке не сообщается вовсе. Пока опыт: гость собирает звуковое устройство, но маршрут вывода у него ещё не встаёт, и машина от этих драйверов заметно тяжелеет. Применяется при запуске машины.":
            "Sound output on the phone: its own path through an audio unit, which neither silences whatever else is playing nor spoils the Bluetooth headset profile. The switch describes the audio hardware to the machine — the speaker, the I2S bus and the coprocessor — and without it the guest is told nothing about sound at all. Still an experiment: the guest builds an audio device, but its output route does not come up yet, and those drivers make the machine noticeably heavier. Applied when the machine starts.",
        "Здесь лежит весь код гостя, переведённый в код телефона. Когда он не помещается, буфер сбрасывается целиком и ядра переводят всё заново вместо того, чтобы исполнять. Замерено на телефоне: при 64 МБ гость выдавал 8–11 кадров в секунду, при 256 — 21–25, причём на большей панели. Большее не бесплатно: буфер живёт в тех же трёх гигабайтах, что и память гостя. Если приложение перестанет запускаться — верните шаг назад.":
            "This holds all of the guest's code, translated into the phone's. When it does not fit, the buffer is thrown away whole and the cores translate everything again instead of running it. Measured on the phone: at 64 MB the guest managed 8–11 frames a second, at 256 it managed 21–25, and on a larger panel at that. More is not free: the buffer lives in the same three gigabytes as the guest's memory. If the app stops starting, step back down.",
        "Размер": "Size",
        "%d×%d, точек %d×%d": "%d×%d, %d×%d points",
        "Экран гостя рисуется без графического ускорителя — каждый кадр собирают эмулируемые ядра, и платят они за каждый пиксель. Панель поменьше — меньше работы: у iPhone 8 пикселей на треть меньше, чем у iPhone 11, у SE — вдвое. Чёткость при этом не страдает: масштаб везде двукратный, ресурсы iOS берёт те же, интерфейс просто становится интерфейсом телефона поменьше. Применяется при запуске машины.":
            "The guest's screen is drawn with no graphics accelerator — the emulated cores assemble every frame, and they pay for every pixel. A smaller panel is less work: the iPhone 8 has a third fewer pixels than the iPhone 11, the SE half as many. Sharpness does not suffer: the scale stays at two everywhere, iOS uses the same artwork, and the interface simply becomes that of a smaller phone. Applied when the machine starts.",
        "Ядрам гостя — быстрые ядра телефона": "Fast phone cores for the guest's cores",
        "Потоки эмулируемых ядер просят у iOS высший класс обслуживания. Без этого они получают обычный, и телефон вправе увести их на энергоэффективные ядра. Применяется при запуске машины.":
            "The threads running the emulated cores ask iOS for the highest quality of service. Without it they get the default one, and the phone is free to move them to the efficiency cores. Applied when the machine starts.",
        "Под экраном гостя: сколько кадров он успел нарисовать за секунду — считаются дошедшие до приложения, — и сколько он льёт в консоль. Второе число важнее, чем кажется: пока гость печатает мегабайты в секунду, его ядра заняты этим, а не картинкой.":
            "Under the guest's screen: how many frames it managed in the last second, counted as they reach the app, and how much it is pouring into the console. The second number matters more than it looks: while the guest prints megabytes a second, its cores are busy with that rather than with the picture.",
        "Сеть: гость погасил связь.": "Network: the guest took the link down.",
        "Кнопки: экран не подключён, нажатие некуда отправить.":
            "Buttons: no screen attached, nowhere to send the press.",
        "Кнопка %@ (F%d) на %.1f с": "Button %@ (F%d) for %.1f s",
        "Диагностика": "Diagnostics",
        "Ответы появятся в терминале, на вкладке «Эмулятор».":
            "The answers appear in the terminal, on the Emulator tab.",
        "Источник": "Source",
        "Сборка": "Build",
        "Скруглять углы": "Round the corners",
        "Как у настоящего iPhone 11: 41,5 pt при ширине экрана 414 pt — десятая часть ширины. Доля, а не число в пикселях, поэтому углы остаются верными при любом масштабе. Выключите, чтобы видеть кадр целиком, до последней точки.":
            "Exactly an iPhone 11's: 41.5 pt on a screen 414 pt wide — a tenth of the width. Kept as that fraction rather than as pixels, so the corners stay right at any size. Turn it off to see the whole frame, down to the last dot.",
        "Без сглаживания видны квадратные пиксели, со сглаживанием картинка мягче. На скорость гостя не влияет ни то, ни другое.":
            "Without smoothing the pixels show as squares; with it the picture is softer. Neither changes how fast the guest runs.",
        "Прокручивать к последней строке, как только приходит новая.":
            "Scroll to the last line as soon as a new one arrives.",
        "Потолок процесса на iPhone — ровно 3 ГиБ, и в него входит всё остальное, что держит приложение.":
            "The process ceiling on an iPhone is exactly 3 GiB, and everything else the app holds counts towards it.",

        // Panes and controls
        "Экран": "Screen",
        "Терминал": "Terminal",
        "Эмулятор": "Emulator",
        "Консоль гостя": "Guest console",
        "Шелл": "Shell",
        "Лог ядра": "Kernel log",
        "Подключить": "Connect",
        "Попробовать снова": "Try again",
        "Прошу гостя подключиться…": "Asking the guest to connect…",
        "Отдельный канал: гость сам звонит приложению по сети, и сюда не попадает ничего, кроме написанного шеллом. Нужны включённая сеть и bash на консоли.":
            "A channel of its own: the guest calls the app over the network, so nothing reaches this pane but what the shell wrote. Needs the network on and bash on the console.",
        "Шелл гостя не отвечает: на консоли должен сидеть bash из бутстрапа.":
            "The guest's shell is not answering: the bootstrap's bash has to be on the console.",
        "Гость не подключился. Проверьте, что сеть в госте поднялась.":
            "The guest did not call back. Check that its network came up.",
        "Гость закрыл канал.": "The guest closed the channel.",
        "Через консоль": "Over the console",
        "Через сеть": "Over the network",
        "— готово, код %d": "— done, status %d",
        "Гость не позвонил обратно.": "The guest never called back.",
        "Перехожу на консоль.": "Falling back to the console.",
        "Сети у гостя нет — шелл идёт по консоли.":
            "The guest has no network — the shell goes over the console.",
        "Шелл не отозвался на проверку. Похоже, на консоли не bash.":
            "The shell did not answer the probe. There is probably no bash on the console.",
        "Канал по консоли открыт: показывается только вывод команд.":
            "Console channel open: only what commands print is shown.",
        "Сети в госте нет: bash ответил «Network is unreachable».":
            "The guest has no network: bash answered “Network is unreachable”.",
        "В этом bash нет поддержки /dev/tcp.": "This bash was built without /dev/tcp.",
        "Сеть в госте не поднялась, а без неё позвонить он не может.":
            "The guest's network never came up, and without it there is no call to make.",
        "Сеть в госте не работает: bash ответил «Network is unreachable».":
            "The guest has no working network: bash answered “Network is unreachable”.",
        "Гость дозвонился, но соединение отвергнуто.":
            "The guest got through, but the connection was refused.",
        "В этом bash нет поддержки /dev/tcp, а без неё канал не открыть.":
            "This bash was built without /dev/tcp, and the channel needs it.",
        "Машина": "Machine",
        "Параметры": "Settings",
        "Параметры…": "Settings…",
        "Запустить": "Start",
        "Запущена": "Running",
        "Остановлена — перезапустите приложение": "Stopped — relaunch the app",
        "Во весь экран": "Full screen",
        "Выключить машину…": "Shut the machine down…",
        "Выключить машину?": "Shut the machine down?",
        "Выключить": "Shut down",
        "Отмена": "Cancel",
        "Готово": "Done",
        "Ввод": "Send",
        "Команда гостю": "Command for the guest",
        "Следить за концом": "Follow the tail",
        "Без лога ядра": "Hide kernel log",
        "Только шелл": "Shell only",
        "У гостя одна консоль на всех: ядро сыплет в неё сообщения драйверов, bash пишет туда же. Сообщения ядра узнаются по виду и вырезаются — в том числе воткнутые в середину чужой строки. Это распознавание по признакам, а не настоящее разделение: что-то незнакомое может проскочить.":
            "The guest has one console for everything: the kernel pours driver messages into it and bash writes to it too. Kernel messages are recognised by their shape and cut out, including ones landing in the middle of somebody else's line. This is recognition by pattern, not a real separation: something unfamiliar can still get through.",
        "Кнопки устройства": "Device buttons",
        "Питание": "Power",
        "Громче": "Volume up",
        "Тише": "Volume down",
        "Состояние": "Status",
        "Сборка: ": "Build: ",
        "Проверить JIT заново": "Re-check JIT",
        "Диагностика памяти": "Memory diagnostics",
        "Состояние машины (QMP)": "Machine status (QMP)",
        "Потоки и загрузка": "Threads and load",
        "Где крутится (PC)": "Where it spins (PC)",
        "Проверить снова": "Check again",
        "Не хватает": "Missing",

        // Settings
        "Ядра": "Cores",
        "Всего vCPU": "vCPUs in total",
        "Память": "Memory",
        "Гостю": "To the guest",
        "Сеть": "Network",
        "Интернет через USB": "Internet over USB",
        "Без экрана": "No screen",
        "Транслятор": "Translator",
        "Потоки TCG": "TCG threads",
        "Буфер трансляций": "Translation buffer",
        "Язык": "Language",
        "Одно ядро уходит под SEP: при 4 гостю достаётся 3.":
            "One core goes to the SEP: with 4, the guest gets 3.",
        "При 7 инициализация машины тратит ~1.4 ГБ только на служебные структуры.":
            "With 7, machine setup spends about 1.4 GB on bookkeeping structures alone.",
        "Для Secure Enclave нужны 4 ядра И multi одновременно. При 2 ядрах или при single он паникует на sks.":
            "The Secure Enclave needs 4 cores AND multi together. With 2 cores, or with single, it panics in sks.",
        "single оставлен для диагностики. Гость на нём не грузится: SEP и ядра AP должны двигаться одновременно.":
            "single is kept for diagnostics. The guest will not boot on it: the SEP and the AP cores have to move together.",
        "VNC-сервер не запускается вовсе: ничего не кодируется и не копируется. Остаётся только консоль гостя.":
            "No VNC server at all: nothing to encode, nothing to copy. Only the guest console is left.",
        "Эмулятор сам работает USB-хостом: переводит устройство в режим CDC-NCM и выпускает трафик наружу через slirp. Отдельная виртуалка не нужна.":
            "The emulator acts as the USB host itself: it switches the device into CDC-NCM mode and lets the traffic out through slirp. No companion VM needed.",
        "Изменения применяются при следующем запуске машины. Перезапустите приложение, чтобы запустить её заново.":
            "Changes apply the next time the machine starts. Relaunch the app to start it again.",
        "QEMU допишет диски на файлы и завершится. Чтобы запустить машину заново, перезапустите приложение.":
            "QEMU will flush the disks to their files and exit. To start the machine again, relaunch the app.",

        // States and messages
        "Не запущена": "Not running",
        "Машина остановлена": "The machine is stopped",
        "Машина работает, подключаемся к экрану…": "Machine running, connecting to the screen…",
        "Машина работает, экран ещё не слушает": "Machine running, the screen is not listening yet",
        "Работает · экран подключается": "Running · screen connecting",
        "Откройте меню и запустите машину": "Open the menu and start the machine",
        "Ожидание вывода консоли…": "Waiting for console output…",
        "Пока пусто. Здесь появятся сообщения эмулятора, включая причину отказа запуска.":
            "Empty for now. Emulator messages appear here, including why a start was refused.",
        "подключено": "connected",
        "нет связи": "no link",
        "Запуск отменён: JIT недоступен.": "Start cancelled: no JIT.",
        "Выключение: отправляю QMP quit…": "Shutdown: sending QMP quit…",
        "Выключение: команда отправлена, машина сбрасывает диски на файлы":
            "Shutdown: command sent, the machine is flushing its disks",
        "Выключение: команда не ушла": "Shutdown: the command did not go out",
        "Выключение: приветствия от QMP нет": "Shutdown: no greeting from QMP",
        "Диск устройства (root.qcow2 или root)": "Device disk (root.qcow2 or root)",
        "Прошивка NVMe": "NVMe firmware",
        "Прошивка SEP": "SEP firmware",
        "Тикет": "Ticket",
        "Откройте «Файлы» → «На iPhone» → «Inferno» и скопируйте туда InfernoData и AppleSEPROM-Cebu-B1.":
            "Open Files → On My iPhone → Inferno and copy InfernoData and AppleSEPROM-Cebu-B1 there.",

        // JIT
        "не проверялось": "not checked",
        "MAP_JIT, отладчик": "MAP_JIT, debugger",
        "зеркальное отображение (split-wx)": "mirrored mapping (split-wx)",
        "ptrace + зеркальное отображение": "ptrace + mirrored mapping",
        "включите JIT (StikDebug) и вернитесь в приложение":
            "enable JIT (StikDebug) and come back to the app",
        "самотрассировка прошла, но исполняемой памяти всё равно нет":
            "self-tracing worked, but there is still no executable memory",
        "RWX без MAP_JIT": "RWX without MAP_JIT",
        "исполнение RWX": "executing RWX",
        "исполнение RW→RX": "executing RW→RX",
        "Проверка исполняемой памяти:\n  ": "Executable memory check:\n  ",

        // VNC and probes
        "VNC: сокет открыт, рукопожатие": "VNC: socket open, handshaking",
        "сервер не прислал версию протокола": "the server sent no protocol version",
        "сервер отказал в соединении": "the server refused the connection",
        "оборвано имя сервера": "the server name was cut short",
        "непонятное сообщение сервера": "unintelligible message from the server",
        "нет параметров экрана": "no screen parameters",
        "QMP: сокет открыт, но приветствия нет": "QMP: socket open, but no greeting",
        "Пробник: не удалось определить занятый поток": "Probe: could not tell which thread is busy",
        "  адрес меняется — поток исполняет цикл": "  the address moves — the thread is running a loop",
        "  адрес не меняется — поток стоит на одной инструкции":
            "  the address does not move — the thread is stuck on one instruction",
        "Аргументы:\n  ": "Arguments:\n  ",

        // Installing an .ipa into the guest
        "Установить .ipa в гостя…": "Install an .ipa in the guest…",
        "Это не .ipa: внутри нет оглавления zip.": "That is not an .ipa: there is no zip directory inside.",
        "В архиве есть то, что я не умею разбирать: %@":
            "The archive holds something I cannot read: %@",
        "Архив повреждён: %@": "The archive is damaged: %@",
        "способ сжатия %d": "compression method %d",
        "В .ipa нет папки Payload — это не приложение.":
            "The .ipa has no Payload folder — that is not an app.",
        "В Payload нет ни одного .app.": "There is no .app inside Payload.",
        "Шелл гостя не отвечает. Установка работает только с бутстрапом, где на консоли сидит bash.":
            "The guest's shell does not answer. Installing needs the bootstrap, with bash on the console.",
        "Шаг «%@» в госте вернул %d.": "The step “%@” returned %d in the guest.",
        "Не удалось занести помощника в гостя: %@":
            "Could not put the helper into the guest: %@",
        "в приложении его нет": "it is not in the app",
        "не удалось сделать исполняемым": "it could not be made executable",
        "Распаковываю .ipa…": "Unpacking the .ipa…",
        "Канал: USB-сеть.": "Channel: the USB network.",
        "Канал: NVMe, %@.": "Channel: NVMe, %@.",
        "Ставлю помощника в гостя — это один раз…":
            "Putting the helper into the guest — this happens once…",
        "перемонтирую корень": "remounting the root",
        "убираю прежнюю копию": "removing the previous copy",
        "распаковываю": "unpacking",
        "права": "permissions",
        "показываю SpringBoard": "telling SpringBoard",
        "прибираю": "tidying up",
        "проверка": "the check",
        "чтение носителя": "reading the namespace",
        "Нужен файл .ipa.": "An .ipa file is needed.",
        "Установлено: %@": "Installed: %@",
        "→ установка %@": "→ installing %@",
        "помощника нет в приложении": "the helper is not in the app",
        "помощника не удалось сделать исполняемым": "the helper could not be made executable",
        "гость не прочитал носитель (%d)": "the guest did not read the namespace (%d)",
        "гость не записал носитель (%d)": "the guest did not write the namespace (%d)",
        "в госте %@ Б, у нас %d Б": "%@ bytes in the guest, %d here",
        "Приложению нужна iOS %d, а в госте iOS %d — оно встало, но не запустится.":
            "The app needs iOS %d and the guest is iOS %d — it is installed, but will not launch.",

        "Починить менеджер пакетов": "Repair the package manager",
        "Патчи": "Patches",
        "Установить .deb в гостя…": "Install a .deb into the guest…",
        "Менеджер пакетов": "Package manager",
        "Перезапустить SpringBoard": "Restart SpringBoard",
        "Только установленные": "Installed only",
        "Источники…": "Sources…",
        "Перечитать установленное": "Re-read what is installed",
        "Установить": "Install",
        "Переустановить": "Reinstall",
        "Удалить": "Remove",
        "Установлен %@, в источнике %@": "%@ installed, %@ in the source",
        "Версия %@": "Version %@",
        "Удаляю %@…": "Removing %@…",
        "Пакет удалён.": "The package is removed.",
        "Пакеты: %@ удалён.": "Packages: %@ is removed.",
        "Читаю установленное": "Reading what is installed",
        "Удаляю пакет": "Removing the package",
        "Перезапускаю SpringBoard…": "Restarting SpringBoard…",
        "SpringBoard: %@": "SpringBoard: %@",
        "Показываю приложение SpringBoard…": "Showing the app to SpringBoard…",
        "Источники": "Sources",
        "Поиск пакета": "Search for a package",
        "Читаю %@…": "Reading %@…",
        "Качаю %@…": "Downloading %@…",
        "%@ — %d%%": "%@ — %d%%",
        "%@ — %d КБ": "%@ — %d KB",
        "Пусто. Потяните вниз, чтобы прочитать источники.": "Empty. Pull down to read the sources.",
        "Репозиторий не отдал файл (%d).": "The repository did not give the file (%d).",
        "https://адрес.репозитория/": "https://repository.address/",
        "Добавить": "Add",
        "Читаются указатели `Packages` и `Packages.gz`. Источники на `.bz2` или `.zst` не поддерживаются: распаковщиков для них в iOS нет.":
            "`Packages` and `Packages.gz` indexes are read. Sources that only publish `.bz2` or `.zst` are not supported: iOS has no decompressor for either.",
        "нет читаемого указателя пакетов (Packages, Packages.gz, Packages.bz2)":
            "no readable package index (Packages, Packages.gz, Packages.bz2)",
        "Закрыть": "Close",
        "Готово": "Done",
        "Переношу пакет в гостя…": "Carrying the package into the guest…",
        "Ставлю пакет…": "Installing the package…",
        "Внедряется в launchd, а гость этого не умеет: launchd падает, ядро уходит в панику.":
            "It injects itself into launchd, which this guest cannot do: launchd dies and the kernel panics.",
        "Гость упал и перезагружается, команда не доведена до конца: %@":
            "The guest fell over and is rebooting; the command did not finish: %@",
        "Гостю нельзя: %@": "The guest cannot take it: %@",
        "Гость упал: %@": "The guest fell over: %@",
        "Запуск отменён: не хватает файлов — %@": "Start refused: these files are missing — %@",
        "Всё равно установить": "Install it anyway",
        "Гость упал в панику — поднимаю менеджер пакетов заново, когда вернётся.":
            "The guest panicked; the package manager will be set up again once it is back.",
        "Ставлю пакет": "Installing the package",
        "Настраиваю пакеты…": "Configuring the packages…",
        "→ пакет %@": "→ package %@",
        "Пакет установлен.": "The package is installed.",
        "Пакеты: ставлю %@": "Packages: installing %@",
        "Пакеты: качаю %@": "Packages: downloading %@",
        "↓ %@": "↓ %@",
        "репозиторий ответил %d": "the repository answered %d",
        "Пакеты: %@ установлен.": "Packages: %@ is installed.",
        "Пакеты: %@ — %@": "Packages: %@ — %@",
        "Чинить менеджер пакетов при запуске": "Repair the package manager at start",
        "Перезагрузка гостя возвращает корень в режим «только чтение» и уносит корневого помощника, без которого Cydia отвечает «cydo returned an error code (2)». Это чинится заново при каждом запуске машины — секунды. Долгие шаги, нужные один раз на образ, остались на кнопке в меню.":
            "A guest reboot puts the root back to read-only and takes the root helper with it, and without those Cydia answers `cydo returned an error code (2)`. That much is redone at every start and takes seconds. The slow steps, needed once per image, stay on the button in the menu.",
        "Пакеты: гость подготовлен.": "Packages: the guest is prepared.",
        "Пакеты: подготовить не вышло — %@": "Packages: could not prepare — %@",
        "Чиню менеджер пакетов…": "Repairing the package manager…",
        "Менеджер пакетов починен. Попробуйте Cydia снова.":
            "The package manager is repaired. Try Cydia again.",
        "Пакеты: чиню dpkg в госте…": "Packages: repairing dpkg in the guest…",
        "Пакеты: готово.": "Packages: done.",
        "Пакеты: не вышло — %@": "Packages: failed — %@",
        "Гость не отвечает на консоли — дождитесь загрузки и повторите.":
            "The guest is not answering on the console — wait for it to boot and try again.",
        "Шаг «%@» не ответил вовремя.": "The step “%@” did not answer in time.",
        "Корень гостя остался только для чтения — пакеты писать некуда.":
            "The guest's root is still read-only — there is nowhere for packages to be written.",
        "Перемонтирую корень на запись": "Remounting the root writable",
        "Перемонтирую корень на запись…": "Remounting the root writable…",
        "Готовлю папки apt": "Making apt's folders",
        "Ставлю ссылку на базу dpkg": "Linking dpkg's database",
        "Регистрирую прошивку": "Registering the firmware",
        "Настраиваю пакеты": "Configuring the packages",
        "«%@» не ответил вовремя.": "“%@” did not answer in time.",
        "«%@» вернул %d.": "“%@” returned %d.",
        "Проверяю…": "Checking…",
        "Проверяю базу": "Auditing the database",
        "Ставлю помощника для Cydia…": "Installing Cydia's helper…",
        "Помощника не удалось разложить.": "The helper could not be put in place.",
        "Помощник не запустился — Cydia останется без прав.":
            "The helper did not start — Cydia will stay without privileges.",
        "dpkg сказал: %@": "dpkg said: %@",
        "База dpkg на месте не найдена — Cydia может всё ещё ругаться.":
            "dpkg's database was not found where it belongs — Cydia may still complain.",
    ]

    static func string(_ russian: String) -> String {
        guard showEnglish else { return russian }
        return table[russian] ?? russian
    }
}

/// Shorthand used at every call site.
func L(_ russian: String) -> String { L10n.string(russian) }

/// The same, for a line with something substituted into it.
///
/// The Russian is written as a format string and translated as one, so the
/// substitutions land in whichever order the other language wants them.
func L(_ russian: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.string(russian), arguments: arguments)
}
