import Foundation
import SwiftUI

/// Everything the user can change without a rebuild.
///
/// These are exactly the knobs that matter when something refuses to boot: how
/// many cores, how much memory, whether TCG runs its vCPUs on separate threads.
/// Being able to bisect them on the device saves a build round-trip for every
/// guess. The presentation knobs live here too, so that one screen holds
/// everything and nothing has to be hunted for in a toolbar.
final class Settings: ObservableObject {
    static let shared = Settings()

    // The machine
    @AppStorage("cores") var cores: Int = 4 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("memory") var memory: String = "3G" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("tcgThreads") var tcgThreads: String = "multi" {
        willSet { objectWillChange.send() }
    }
    /// Left at the middle of the range on purpose. Bigger is faster — measured
    /// on the phone, 64 MB gave 8–11 frames a second and 256 gave 21–25 — but
    /// this buffer shares the process's three gigabytes with the guest's own
    /// memory, and a default that wins frames by courting the memory limit is
    /// not a default. Raising it is one tap away, in Settings → Translator.
    @AppStorage("tbSize") var tbSize: Int = 128 {
        willSet { objectWillChange.send() }
    }
    /// Whether the guest's cores ask the phone for the fast cores.
    @AppStorage("vcpuPriority") var vcpuPriority: Bool = true {
        willSet { objectWillChange.send() }
    }

    // The picture
    @AppStorage("headless") var headless: Bool = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("builtInDisplay") var builtInDisplay: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("panel") var panel: String = GuestPanel.iphone11.rawValue {
        willSet { objectWillChange.send() }
    }
    /// Whether the guest's sound reaches the phone's speaker. Off by default:
    /// the samples are prepared by the same emulated cores that draw the screen.
    @AppStorage("guestAudio") var guestAudio: Bool = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("smoothUpscale") var smoothUpscale: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("roundedScreen") var roundedScreen: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("showFPS") var showFPS: Bool = false {
        willSet { objectWillChange.send() }
    }

    // The terminal
    @AppStorage("hideKernel") var hideKernel: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("terminalFollow") var terminalFollow: Bool = true {
        willSet { objectWillChange.send() }
    }

    // The link
    @AppStorage("network") var network: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("netAutoFix") var netAutoFix: Bool = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage("language") var language: String = AppLanguage.system.rawValue {
        willSet { objectWillChange.send() }
    }

    /// What the emulator is told through the environment. Empty means the old
    /// behaviour in both cases, so an unknown build behaves as it always did.
    var emulatorEnvironment: [String: String] {
        var env: [String: String] = [:]
        if vcpuPriority { env["INFERNO_VCPU_QOS"] = "interactive" }
        return env
    }

    var config: VMConfig {
        var c = VMConfig()
        c.cores = cores
        c.memory = memory
        c.tcgThreads = tcgThreads
        c.tbSize = tbSize
        c.network = network
        c.headless = headless
        c.builtInDisplay = builtInDisplay
        c.audio = guestAudio
        let pixels = (GuestPanel(rawValue: panel) ?? .iphone11).pixels
        c.displayWidth = pixels.width
        c.displayHeight = pixels.height
        c.displayScale = pixels.scale
        return c
    }
}

/// The corner of an iPhone 11's display.
///
/// 41.5 pt on a screen 414 pt wide — almost exactly a tenth of the width. Kept
/// as that fraction rather than as points, so the guest's corners stay right at
/// whatever size its picture is drawn, and stay right if the machine is ever
/// given a different panel.
enum GuestBezel {
    static let radiusOverWidth: CGFloat = 41.5 / 414
}

/// The panel the machine shows the guest.
///
/// Pixels are what the emulated cores pay for. There is no GPU in the guest, so
/// iOS composites every frame in software on those cores, and the same pixels
/// are then read out of the machine's memory and carried to the screen. A
/// smaller panel is less of all of it.
///
/// The scale stays at two throughout. It is tempting to drop it to one and take
/// four times fewer pixels, but then iOS is no longer drawing Retina: it falls
/// back to @1x artwork, which modern iOS barely ships, and the interface comes
/// out wrong rather than small. A smaller panel at scale two is a smaller
/// phone, drawn exactly as sharply as before.
/// Every width here is a multiple of four, so that a row of the frame is a
/// multiple of sixteen bytes. It is not a preference: at 750 pixels wide the
/// guest does not finish booting at all.
enum GuestPanel: String, CaseIterable {
    case iphone11
    case iphone8
    case iphoneSE

    var pixels: (width: Int, height: Int, scale: Int) {
        switch self {
        case .iphone11: return (828, 1792, 2)
        // Not the iPhone 8's own 750×1334: a frame row has to be a multiple of
        // sixteen bytes, and 750×4 is 3000, which is not. Two pixels wider and
        // the row is 3008, which is. The guest hangs on boot otherwise — the
        // machine wedges with the main loop never getting a redraw in.
        case .iphone8: return (752, 1336, 2)
        case .iphoneSE: return (640, 1136, 2)
        }
    }

    var title: String {
        switch self {
        case .iphone11: return L("iPhone 11")
        case .iphone8: return L("iPhone 8")
        case .iphoneSE: return L("iPhone SE")
        }
    }

    /// What it costs, for the line under the picker.
    var detail: String {
        let p = pixels
        return L("%d×%d, точек %d×%d", p.width, p.height, p.width / p.scale, p.height / p.scale)
    }
}

struct SettingsView: View {
    @ObservedObject var model: VMModel
    @ObservedObject var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ScreenSettings() } label: {
                        Label(L("Экран"), systemImage: "iphone.gen3")
                    }
                    NavigationLink { TerminalSettings() } label: {
                        Label(L("Терминал"), systemImage: "terminal")
                    }
                    NavigationLink { NetworkSettings() } label: {
                        Label(L("Сеть"), systemImage: "network")
                    }
                }

                Section {
                    NavigationLink { MachineSettings() } label: {
                        Label(L("Машина"), systemImage: "cpu")
                    }
                    NavigationLink { TranslatorSettings() } label: {
                        Label(L("Транслятор"), systemImage: "arrow.triangle.2.circlepath")
                    }
                } footer: {
                    Text(L("Изменения применяются при следующем запуске машины. Перезапустите приложение, чтобы запустить её заново."))
                }

                Section {
                    NavigationLink { DiagnosticsSettings(model: model) } label: {
                        Label(L("Диагностика"), systemImage: "stethoscope")
                    }
                }

                Section(L("Язык")) {
                    Picker(L("Язык"), selection: $settings.language) {
                        ForEach(AppLanguage.allCases, id: \.rawValue) { lang in
                            Text(lang.title).tag(lang.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    LabeledContent(L("Сборка"), value: BuildInfo.stamp)
                        .font(.footnote)
                }
            }
            .navigationTitle(L("Параметры"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Готово")) { dismiss() }
                }
            }
        }
    }
}

private struct ScreenSettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Панель"), selection: $settings.panel) {
                    ForEach(GuestPanel.allCases, id: \.rawValue) { panel in
                        Text(panel.title).tag(panel.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent(L("Размер"),
                               value: (GuestPanel(rawValue: settings.panel) ?? .iphone11).detail)
                    .font(.footnote)
            } footer: {
                Text(L("Экран гостя рисуется без графического ускорителя — каждый кадр собирают эмулируемые ядра, и платят они за каждый пиксель. Панель поменьше — меньше работы: у iPhone 8 пикселей на треть меньше, чем у iPhone 11, у SE — вдвое. Чёткость при этом не страдает: масштаб везде двукратный, ресурсы iOS берёт те же, интерфейс просто становится интерфейсом телефона поменьше. Применяется при запуске машины."))
            }

            Section {
                Toggle(L("Без экрана"), isOn: $settings.headless)
            } footer: {
                Text(L("Картинка не готовится вовсе: ничего не копируется и не кодируется. Остаётся только консоль гостя."))
            }

            if !settings.headless {
                Section {
                    Toggle(L("Встроенный вывод"), isOn: $settings.builtInDisplay)
                } footer: {
                    Text(settings.builtInDisplay
                         ? L("Приложение читает кадры прямо из памяти эмулятора и берёт только перерисованные строки. Ни сокета, ни кодирования.")
                         : L("Картинка идёт через VNC-сервер эмулятора по локальной петле кодировкой Raw: весь кадр сравнивается, кодируется, пересылается и разбирается заново. Медленнее, зато этот путь давно обкатан."))
                }

                Section {
                    Toggle(L("Скруглять углы"), isOn: $settings.roundedScreen)
                } footer: {
                    Text(L("Как у настоящего iPhone 11: 41,5 pt при ширине экрана 414 pt — десятая часть ширины. Доля, а не число в пикселях, поэтому углы остаются верными при любом масштабе. Выключите, чтобы видеть кадр целиком, до последней точки."))
                }

                Section {
                    Toggle(L("Ядрам гостя — быстрые ядра телефона"), isOn: $settings.vcpuPriority)
                } footer: {
                    Text(L("Потоки эмулируемых ядер просят у iOS высший класс обслуживания. Без этого они получают обычный, и телефон вправе увести их на энергоэффективные ядра. Применяется при запуске машины."))
                }

                Section {
                    Toggle(L("Счётчик кадров"), isOn: $settings.showFPS)
                } footer: {
                    Text(L("Под экраном гостя: сколько кадров он успел нарисовать за секунду — считаются дошедшие до приложения, — и сколько он льёт в консоль. Второе число важнее, чем кажется: пока гость печатает мегабайты в секунду, его ядра заняты этим, а не картинкой."))
                }

                Section {
                    Toggle(L("Сглаживать при растягивании"), isOn: $settings.smoothUpscale)
                } footer: {
                    Text(L("Без сглаживания видны квадратные пиксели, со сглаживанием картинка мягче. На скорость гостя не влияет ни то, ни другое."))
                }
            }
        }
        .navigationTitle(L("Экран"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TerminalSettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Только шелл"), isOn: $settings.hideKernel)
            } footer: {
                Text(L("У гостя одна консоль на всех: ядро сыплет в неё сообщения драйверов, bash пишет туда же. Сообщения ядра узнаются по виду и вырезаются — в том числе воткнутые в середину чужой строки. Это распознавание по признакам, а не настоящее разделение: что-то незнакомое может проскочить."))
            }

            Section {
                Toggle(L("Следить за концом"), isOn: $settings.terminalFollow)
            } footer: {
                Text(L("Прокручивать к последней строке, как только приходит новая."))
            }
        }
        .navigationTitle(L("Терминал"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NetworkSettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Интернет через USB"), isOn: $settings.network)
            } footer: {
                Text(L("Эмулятор сам работает USB-хостом: переводит устройство в режим CDC-NCM и выпускает трафик наружу через slirp. Отдельная виртуалка не нужна."))
            }

            if settings.network {
                Section {
                    Toggle(L("Поднимать интерфейс в госте"), isOn: $settings.netAutoFix)
                } footer: {
                    Text(L("iOS не всегда включает свой конец связи: интерфейс появляется и тут же гасится. Если через минуту адрес так и не получен, приложение само выполнит в консоли гостя «ipconfig set en0 DHCP». Нужен бутстрап с шеллом на консоли."))
                }
            }
        }
        .navigationTitle(L("Сеть"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MachineSettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Всего vCPU"), selection: $settings.cores) {
                    ForEach([2, 3, 4, 5, 7], id: \.self) { Text("\($0)").tag($0) }
                }
                if settings.cores < 4 || settings.tcgThreads != "multi" {
                    Label(L("Для Secure Enclave нужны 4 ядра И multi одновременно. При 2 ядрах или при single он паникует на инициализации хранилища ключей — проверено на обоих устройствах."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if settings.cores > 4 {
                    Label(L("При 7 инициализация машины тратит ~1.4 ГБ только на служебные структуры."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text(L("Ядра"))
            } footer: {
                Text(L("Одно ядро уходит под SEP: при 4 гостю достаётся 3."))
            }

            Section {
                Picker(L("Гостю"), selection: $settings.memory) {
                    ForEach(["1G", "2G", "3G", "4G"], id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text(L("Память"))
            } footer: {
                Text(L("Потолок процесса на iPhone — ровно 3 ГиБ, и в него входит всё остальное, что держит приложение."))
            }

            Section {
                Toggle(L("Звук гостя (опыт)"), isOn: $settings.guestAudio)
            } header: {
                Text(L("Звук"))
            } footer: {
                Text(L("Вывод звука на телефоне: своя дорожка через AudioUnit, чужую музыку не глушит и профиль Bluetooth-наушников не портит. Услышать пока нечего: в эмулируемой машине не хватает звукового сопроцессора, через который iOS выводит на динамик, — поэтому гость в эту дорожку ничего не шлёт. Тумблер есть, чтобы проверять сторону телефона, пока делается сторона машины. Применяется при запуске машины."))
            }
        }
        .navigationTitle(L("Машина"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TranslatorSettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Потоки TCG"), selection: $settings.tcgThreads) {
                    Text("multi").tag("multi")
                    Text("single").tag("single")
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(L("single оставлен для диагностики. Гость на нём не грузится: SEP и ядра AP должны двигаться одновременно."))
            }

            Section {
                Picker(L("Буфер трансляций"), selection: $settings.tbSize) {
                    ForEach([32, 64, 128, 256, 384, 512], id: \.self) { Text(L("%d МБ", $0)).tag($0) }
                }
            } footer: {
                Text(L("Здесь лежит весь код гостя, переведённый в код телефона. Когда он не помещается, буфер сбрасывается целиком и ядра переводят всё заново вместо того, чтобы исполнять. Замерено на телефоне: при 64 МБ гость выдавал 8–11 кадров в секунду, при 256 — 21–25, причём на большей панели. Большее не бесплатно: буфер живёт в тех же трёх гигабайтах, что и память гостя. Если приложение перестанет запускаться — верните шаг назад."))
            }
        }
        .navigationTitle(L("Транслятор"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What the machine is doing, and the tools for finding out why it is not.
///
/// This used to hang off the control menu, which made the menu long and put
/// diagnostics one tap from everything else. They belong here: rarely wanted,
/// and worth reading rather than glancing at.
private struct DiagnosticsSettings: View {
    @ObservedObject var model: VMModel

    var body: some View {
        Form {
            Section(L("Состояние")) {
                Text(statusLine)
                Text(jitLine)
                Text(L("Параметры: %d vCPU, %@, tcg %@",
                       Settings.shared.cores, Settings.shared.memory, Settings.shared.tcgThreads))
            }
            .font(.footnote)

            Section {
                Button(L("Проверить JIT заново"), systemImage: "arrow.clockwise") {
                    model.refreshJIT()
                }
                Button(L("Диагностика памяти"), systemImage: "stethoscope") {
                    _ = JIT.diagnose(includeExecution: true)
                }
                Button(L("Состояние машины (QMP)"), systemImage: "waveform.path.ecg") {
                    model.inspectMachine()
                }
                Button(L("Потоки и загрузка"), systemImage: "gauge") {
                    Threads.report { LogCapture.shared.note($0) }
                }
                Button(L("Где крутится (PC)"), systemImage: "scope") {
                    Sampler.report { LogCapture.shared.note($0) }
                }
            } footer: {
                Text(L("Ответы появятся в терминале, на вкладке «Эмулятор»."))
            }
        }
        .navigationTitle(L("Диагностика"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var jitLine: String {
        switch model.jit {
        case .available(let how):   return L("JIT: есть (%@)", how)
        case .unavailable(let why): return L("JIT: нет — %@", why)
        }
    }

    private var statusLine: String {
        switch model.qemuState {
        case .idle:              return L("Не запущена")
        case .running:
            if case .connected(let w, let h) = model.displayStatus {
                return L("Работает · %d×%d", w, h) + (model.networkUp ? L(" · сеть есть") : "")
            }
            return L("Работает · экран подключается")
        case .stopped(let code): return L("Остановлена (код %d)", code)
        case .failed(let text):  return L("Ошибка: %@", text)
        }
    }
}
