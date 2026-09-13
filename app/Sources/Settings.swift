import Foundation
import SwiftUI

/// Everything the user can change without a rebuild.
///
/// These are exactly the knobs that matter when something refuses to boot: how
/// many cores, how much memory, how big the translation buffer is.
/// Being able to bisect them on the device saves a build round-trip for every
/// guess. The presentation knobs live here too, so that one screen holds
/// everything and nothing has to be hunted for in a toolbar.
final class Settings: ObservableObject {
    static let shared = Settings()

    private init() {
        // A count saved while 2 and 3 were still on offer would otherwise
        // reach the command line, and leave the picker with nothing selected.
        if cores < Settings.coreChoices[0] { cores = Settings.coreChoices[0] }
    }

    // The machine
    @AppStorage("cores") var cores: Int = 4 {
        willSet { objectWillChange.send() }
    }
    /// Nothing below 4: one core goes to the SEP, and with fewer than three
    /// left beside it the SEP panics initialising its key store, so the guest
    /// never boots. 2 and 3 used to be offered and only ever caught people out.
    static let coreChoices = [4, 5, 7]
    @AppStorage("memory") var memory: String = "3G" {
        willSet { objectWillChange.send() }
    }
    /// Left at the middle of the range on purpose. Bigger is faster — measured
    /// on the phone, 64 MB gave 8–11 frames a second and 256 gave 21–25 — but
    /// this buffer shares the process's three gigabytes with the guest's own
    /// memory, and a default that wins frames by courting the memory limit is
    /// not a default. Raising it is one tap away, in Settings → Translator.
    /// The biggest buffer known to work on a phone. With 512 MB two users'
    /// phones stopped at the emulator's first instruction, and 256 got both
    /// going; bigger sizes stay on offer, behind a warning.
    static let safeTBSize = 256
    @AppStorage("tbSize") var tbSize: Int = 128 {
        willSet { objectWillChange.send() }
    }
    /// Use HVF when the kernel allows it. On by default: where it is not
    /// available it changes nothing, and the switch exists to compare the two.
    @AppStorage("virtualization") var virtualization: Bool = true {
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
    @AppStorage("autoRepairPackages") var autoRepairPackages: Bool = true {
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

    // What the guest is told about the battery
    @AppStorage("guestBatteryReal") var guestBatteryReal: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("guestBatteryPercent") var guestBatteryPercent: Double = 69 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("guestBatteryCharging") var guestBatteryCharging: Bool = false {
        willSet { objectWillChange.send() }
    }

    // The guest's time zone
    @AppStorage("guestTimeZone") var guestTimeZone: Bool = true {
        willSet { objectWillChange.send() }
    }

    // What the guest's status bar is made to show
    @AppStorage("statusBarMode") var statusBarMode: String = GuestStatusBar.Mode.phone.rawValue {
        willSet { objectWillChange.send() }
    }
    @AppStorage("statusBarCarrier") var statusBarCarrier: String = "vm_operator" {
        willSet { objectWillChange.send() }
    }
    @AppStorage("statusBarBars") var statusBarBars: Int = 4 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("statusBarNetwork") var statusBarNetwork: Int = GuestStatusBar.Network.lte.rawValue {
        willSet { objectWillChange.send() }
    }
    @AppStorage("statusBarWifi") var statusBarWifi: Bool = true {
        willSet { objectWillChange.send() }
    }
    @AppStorage("statusBarWifiBars") var statusBarWifiBars: Int = 3 {
        willSet { objectWillChange.send() }
    }
    @AppStorage("statusBarSecondSIM") var statusBarSecondSIM: Bool = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("statusBarVPN") var statusBarVPN: Bool = false {
        willSet { objectWillChange.send() }
    }
    @AppStorage("statusBarAirplane") var statusBarAirplane: Bool = false {
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
        // The audio hardware is described to the guest only when this is set: the drivers behind those
        // device tree nodes cost boot time and idle CPU, so a machine started without sound carries none
        // of them.
        if guestAudio { env["INFERNO_AUDIO"] = "1" }
        return env
    }

    var config: VMConfig {
        var c = VMConfig()
        c.cores = cores
        c.memory = memory
        c.tbSize = tbSize
        c.virtualization = virtualization && HVF.probe == .available
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
    /// Read nowhere on this screen, and kept all the same: the language is
    /// chosen a level down, and this is what redraws the labels here after it.
    @ObservedObject var settings = Settings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsRoot {
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
                    NavigationLink { BatterySettings() } label: {
                        Label(L("Батарея гостя"), systemImage: "battery.75percent")
                    }
                    NavigationLink { StatusBarSettings(model: model) } label: {
                        Label(L("Строка состояния гостя"), systemImage: "antenna.radiowaves.left.and.right")
                    }
                }

                Section {
                    NavigationLink { GeneralSettings(model: model) } label: {
                        Label(L("Основные"), systemImage: "gearshape")
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

                Section {
                    NavigationLink { CreditsView() } label: {
                        Label(L("Благодарности"), systemImage: "heart")
                    }
                }
            }
            .navigationTitle(L("Параметры"))
            .inlineNavigationTitle()
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Готово")) { dismiss() }
                }
            }
            #endif
        }
        #if os(macOS)
        // Every form below takes the grouped look of the Mac's own settings:
        // rounded sections, labels on the left, controls on the right. The
        // style is inherited by the screens the stack pushes.
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 520, idealHeight: 680)
        #endif
    }
}

#if os(macOS)
/// The settings on a Mac, laid out the way System Settings is: the sections in
/// a sidebar, the chosen one beside it. The pages are the phone's own screens —
/// only the way between them differs, since drilling in and back out of a list
/// is how a phone saves room, and a Mac window has room.
struct MacSettingsView: View {
    @ObservedObject var model: VMModel
    /// Not read here either, and there for the same reason as on the phone:
    /// the sidebar's labels have to follow the language.
    @ObservedObject var settings = Settings.shared
    @State private var page: Page? = .screen

    enum Page: Hashable {
        case screen, terminal, network, battery, statusBar
        case general, machine, translator, diagnostics, credits
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    row(.screen, L("Экран"), "iphone.gen3")
                    row(.terminal, L("Терминал"), "terminal")
                    row(.network, L("Сеть"), "network")
                    row(.battery, L("Батарея гостя"), "battery.75percent")
                    row(.statusBar, L("Строка состояния гостя"), "antenna.radiowaves.left.and.right")
                }
                Section {
                    row(.general, L("Основные"), "gearshape")
                    row(.machine, L("Машина"), "cpu")
                    row(.translator, L("Транслятор"), "arrow.triangle.2.circlepath")
                    row(.diagnostics, L("Диагностика"), "stethoscope")
                }
                Section {
                    row(.credits, L("Благодарности"), "heart")
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .formStyle(.grouped)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 600)
    }

    private func row(_ page: Page, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).tag(page)
    }

    @ViewBuilder
    private var detail: some View {
        switch page ?? .screen {
        case .screen:      ScreenSettings()
        case .terminal:    TerminalSettings()
        case .network:     NetworkSettings()
        case .battery:     BatterySettings()
        case .statusBar:   StatusBarSettings(model: model)
        case .general:     GeneralSettings(model: model)
        case .machine:     MachineSettings()
        case .translator:  TranslatorSettings()
        case .diagnostics: DiagnosticsSettings(model: model)
        case .credits:     CreditsView()
        }
    }
}
#endif

/// The settings' first screen: the grouped list iOS draws for a List, and on a
/// Mac the grouped form that System Settings is made of — a List there is a
/// flat sidebar-like column, which is not what a settings window looks like.
private struct SettingsRoot<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS)
        Form { content() }
        #else
        List { content() }
        #endif
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
        .inlineNavigationTitle()
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
        .inlineNavigationTitle()
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
        .inlineNavigationTitle()
    }
}

/// What is not about any one part of the machine: the guest's time zone, the
/// language, the build. The same page on the phone and on the Mac; on the
/// phone these used to sit loose on the first screen, between the links.
private struct GeneralSettings: View {
    @ObservedObject var model: VMModel
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Часовой пояс как на телефоне"), isOn: $settings.guestTimeZone)
            } footer: {
                Text(L("Часы гостя идут верно, но часовой пояс у образа свой, обычно тихоокеанский, и время на экране гостя расходится с телефоном на несколько часов. Приложение ставит гостю пояс телефона, как только до гостя можно достучаться, и снова, если пояс телефона сменился. Выключите, если выбрали пояс в настройках самого гостя."))
            }
            .onChange(of: settings.guestTimeZone) { _ in model.syncTimeZone(force: true) }

            Section {
                Picker(L("Язык"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { lang in
                        Text(lang.title).tag(lang.rawValue)
                    }
                }
            }

            Section {
                LabeledContent(L("Сборка"), value: BuildInfo.stamp)
                #if os(macOS)
                Button(L("Показать папку в Finder"), systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([VMConfig.documents])
                }
                #endif
            }
        }
        .navigationTitle(L("Основные"))
        .inlineNavigationTitle()
    }
}

private struct MachineSettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Всего vCPU"), selection: $settings.cores) {
                    ForEach(Settings.coreChoices, id: \.self) { Text("\($0)").tag($0) }
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
                Toggle(L("Чинить менеджер пакетов при запуске"), isOn: $settings.autoRepairPackages)
            } header: {
                Text(L("Патчи"))
            } footer: {
                Text(L("Перезагрузка гостя возвращает корень в режим «только чтение» и уносит корневого помощника, без которого Cydia отвечает «cydo returned an error code (2)». Это чинится заново при каждом запуске машины — секунды. Долгие шаги, нужные один раз на образ, остались на кнопке в меню."))
            }

            Section {
                Toggle(L("Звук гостя (опыт)"), isOn: $settings.guestAudio)
            } header: {
                Text(L("Звук"))
            } footer: {
                Text(L("Вывод звука на телефоне: своя дорожка через AudioUnit, чужую музыку не глушит и профиль Bluetooth-наушников не портит. Тумблер описывает машине звуковое железо — динамик, шину I2S и сопроцессор, — а без него гостю о звуке не сообщается вовсе. Пока опыт: гость собирает звуковое устройство, но маршрут вывода у него ещё не встаёт, и машина от этих драйверов заметно тяжелеет. Применяется при запуске машины."))
            }
        }
        .navigationTitle(L("Машина"))
        .inlineNavigationTitle()
    }
}

/// What the guest's battery shows.
///
/// The machine's SMC answers from whatever is set here, so the figure reaches
/// everything in the guest — the status bar, its settings, its apps — rather
/// than being painted over one of them.
private struct BatterySettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Заряд"), selection: $settings.guestBatteryReal) {
                    Text(L("Как на телефоне")).tag(true)
                    Text(L("Свой")).tag(false)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(L("Телефон отдаёт приложениям заряд с шагом 5 %, точнее iOS не говорит никому. Гость получает это число через SMC машины и показывает его как свой собственный."))
            }

            if !settings.guestBatteryReal {
                Section {
                    LabeledContent(L("Заряд"), value: L("%d %%", Int(settings.guestBatteryPercent)))
                    Slider(value: $settings.guestBatteryPercent, in: 0...100, step: 1)
                    Toggle(L("Заряжается"), isOn: $settings.guestBatteryCharging)
                } footer: {
                    Text(L("Гость узнаёт о смене сразу же: машина будит его драйвер батареи, а не ждёт, пока он спросит сам. Молния в строке состояния появляется за пару секунд."))
                }
            }
        }
        .onChange(of: settings.guestBatteryReal) { _ in HostBattery.shared.start() }
        .onChange(of: settings.guestBatteryPercent) { _ in HostBattery.shared.start() }
        .onChange(of: settings.guestBatteryCharging) { _ in HostBattery.shared.start() }
        .navigationTitle(L("Батарея гостя"))
        .inlineNavigationTitle()
    }
}

/// What the guest's status bar shows of a network it does not have.
private struct StatusBarSettings: View {
    @ObservedObject var model: VMModel
    @ObservedObject var settings = Settings.shared

    private var mode: GuestStatusBar.Mode { GuestStatusBar.Mode(rawValue: settings.statusBarMode) ?? .off }

    var body: some View {
        Form {
            Section {
                Picker(L("Сеть"), selection: $settings.statusBarMode) {
                    ForEach(GuestStatusBar.Mode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(L("Только картинка: у машины нет ни модема, ни Wi-Fi, интернет у гостя идёт по USB, и его приложения никакой сети не увидят. «Как на телефоне» повторяет, Wi-Fi это или сотовая сеть и какого поколения. Уровня сигнала iOS приложениям не сообщает, поэтому он показан полным."))
            }

            if mode != .off {
                Section {
                    TextField(L("Имя оператора"), text: $settings.statusBarCarrier)
                        .autocorrectionDisabled()
                        .noAutocapitalization()
                } header: {
                    Text(L("Оператор"))
                } footer: {
                    Text(L("В строке состояния iPhone с вырезом имени оператора нет, так что там его не видно."))
                }
            }

            if mode == .custom {
                Section(L("Сотовая сеть")) {
                    Stepper(L("Полоски: %d из 4", settings.statusBarBars), value: $settings.statusBarBars, in: 0...4)
                    Picker(L("Тип сети"), selection: $settings.statusBarNetwork) {
                        ForEach(GuestStatusBar.Network.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section {
                    Toggle(L("Wi-Fi"), isOn: $settings.statusBarWifi)
                    if settings.statusBarWifi {
                        Stepper(L("Уровень Wi-Fi: %d из 3", settings.statusBarWifiBars),
                                value: $settings.statusBarWifiBars, in: 0...3)
                    }
                } footer: {
                    Text(L("Значок Wi-Fi встаёт на место подписи типа сети: у iOS это одно и то же место."))
                }
                Section(L("Значки")) {
                    Toggle(L("Вторая SIM"), isOn: $settings.statusBarSecondSIM)
                    Toggle(L("VPN"), isOn: $settings.statusBarVPN)
                    Toggle(L("Авиарежим"), isOn: $settings.statusBarAirplane)
                }
            }

            Section {
                Button(L("Применить сейчас"), systemImage: "arrow.clockwise") { model.paintStatusBar(force: true) }
                    .disabled(!model.isRunning)
            } footer: {
                Text(L("Применяется и само: при запуске машины, после перезагрузки гостя и при каждом изменении здесь."))
            }
        }
        .onChange(of: settings.statusBarMode) { _ in model.paintStatusBar() }
        .onChange(of: settings.statusBarCarrier) { _ in model.paintStatusBar() }
        .onChange(of: settings.statusBarBars) { _ in model.paintStatusBar() }
        .onChange(of: settings.statusBarNetwork) { _ in model.paintStatusBar() }
        .onChange(of: settings.statusBarWifi) { _ in model.paintStatusBar() }
        .onChange(of: settings.statusBarWifiBars) { _ in model.paintStatusBar() }
        .onChange(of: settings.statusBarSecondSIM) { _ in model.paintStatusBar() }
        .onChange(of: settings.statusBarVPN) { _ in model.paintStatusBar() }
        .onChange(of: settings.statusBarAirplane) { _ in model.paintStatusBar() }
        .navigationTitle(L("Строка состояния гостя"))
        .inlineNavigationTitle()
    }
}

private struct TranslatorSettings: View {
    @ObservedObject var settings = Settings.shared
    /// A size over the safe one, just picked, while the warning about it is up.
    @State private var risky: Int?

    var body: some View {
        Form {
            if HVF.isInBuild {
                Section {
                    Toggle(L("Аппаратная виртуализация (HVF)"), isOn: $settings.virtualization)
                        .disabled(HVF.probe != .available)
                    Text(HVF.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } footer: {
                    #if os(macOS)
                    Text(L("Ядра гостя исполняются прямо на ядрах Mac через Hypervisor.framework, без перевода кода. Выключите, чтобы сравнить с транслятором. Применяется при запуске машины."))
                    #else
                    Text(L("Ядра гостя исполняются прямо на ядрах iPad, без перевода кода, и JIT не нужен. Только iPad на M1 или M2 с iPadOS до 16.3.1 включительно, установка через TrollStore или джейлбрейк. Где виртуализации нет, машина работает на трансляторе, как обычно. Применяется при запуске машины."))
                    #endif
                }
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
        .inlineNavigationTitle()
        #if os(iOS)
        // Only where the translator runs: under HVF the buffer is not used.
        .onChange(of: settings.tbSize) { size in
            let underHVF = settings.virtualization && HVF.probe == .available
            if size > Settings.safeTBSize, !underHVF { risky = size }
        }
        .alert(L("Буфер больше 256 МБ может повесить машину"),
               isPresented: Binding(get: { risky != nil }, set: { if !$0 { risky = nil } })) {
            Button(L("Вернуть 256 МБ"), role: .cancel) { settings.tbSize = Settings.safeTBSize }
            Button(L("Оставить %d МБ", risky ?? settings.tbSize), role: .destructive) {}
        } message: {
            Text(L("На iPhone с таким буфером эмулятор может встать на первой же инструкции: экран остаётся чёрным, консоль гостя пустая, машина не отвечает. Так уже было у пользователей, и с 256 МБ у них всё заработало. Применяется при запуске машины."))
        }
        #endif
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
                if HVF.isInBuild { Text(HVF.description) }
                Text(L("Параметры: %d vCPU, %@",
                       Settings.shared.cores, Settings.shared.memory))
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
        .inlineNavigationTitle()
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
