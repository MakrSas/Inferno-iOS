import SwiftUI
import CoreGraphics
import UniformTypeIdentifiers

@main
struct InfernoApp: App {
    init() {
        Bootstrap.prepareDocuments()
        // Start capturing before anything can fail, so the reason is on screen.
        LogCapture.shared.start()
        LogCapture.shared.note("Сборка приложения: \(BuildInfo.stamp)")
        // Must happen before the emulator asks for its translation buffer.
        JIT.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}

/// The real insets of the device, taken from the window.
///
/// A `GeometryProxy` inside a view that ignores the safe area reports nothing
/// useful about it — the area has already been given up by the time the reader
/// measures. The window still knows, and it keeps reporting the island's share
/// of the top even with the status bar hidden, which is the number that matters
/// for keeping the guest's picture out from under it.
enum DeviceInsets {
    static var current: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
    }
}

// MARK: - Model

/// The guest's picture, kept apart from everything else.
///
/// It arrives as fast as the guest draws, and anything watching the object that
/// holds it is rebuilt just as often. That was the control menu: opened, it was
/// thrown back to its first line dozens of times a second and could not be
/// scrolled at all. Only the screen needs the frames, so only the screen watches
/// them.
final class GuestFrame: ObservableObject {
    @Published var image: CGImage?
    /// How many of those arrived in the last second.
    @Published private(set) var fps: Double = 0

    private var counted = 0
    private var since = Date()

    func deliver(_ frame: CGImage) {
        image = frame
        counted += 1
        // Once a second, not once a frame: the number is for looking at, and
        // republishing it thirty times a second would redraw the label as often
        // as the picture.
        let elapsed = Date().timeIntervalSince(since)
        if elapsed >= 1 {
            fps = Double(counted) / elapsed
            counted = 0
            since = Date()
        }
    }
}

final class VMModel: ObservableObject {
    let picture = GuestFrame()
    @Published var displayStatus: GuestDisplayStatus = .disconnected
    @Published var qemuState: QemuBridge.State = .idle
    /// Whether the guest ever got itself an address over the USB link.
    @Published var networkUp = false
    /// What the file transfer is doing, for the banner at the bottom.
    @Published var transfer: TransferState?
    @Published var missing: [String] = VMConfig.missingFiles()
    @Published var jit: JIT.Availability = JIT.status
    /// QEMU is not re-entrant, and it lives inside this process. Once a machine
    /// has been started, a second one in the same process would take the app
    /// down with it, so starting again means relaunching.
    @Published var hasRun = false

    let serial = SerialConsole()
    /// The shell on a socket of its own, away from the kernel's chatter. It
    /// needs the same working link the file transfer does, and asks for it the
    /// same way.
    private(set) lazy var shell = ShellChannel(
        serial: serial,
        linkUp: { [weak self] in self?.linkIsUp ?? false })
    private lazy var qmp = QMPClient(port: config.qmpPort)
    var config: VMConfig { Settings.shared.config }

    /// Chosen when the machine starts and kept for its lifetime: the built-in
    /// path needs the emulator library to be loaded before it can exist at all.
    private var display: GuestDisplay?

    /// Returns nil when the built-in path was asked for and the library does
    /// not have it. Falling back to VNC would be worse than saying so: the
    /// machine was started without a VNC server, so the client would sit there
    /// retrying a port nobody is listening on.
    private func makeDisplay() -> GuestDisplay? {
        var chosen: GuestDisplay
        if config.builtInDisplay {
            guard let embedded = EmbeddedDisplay() else { return nil }
            chosen = embedded
        }
        else {
            chosen = VNCClient(port: config.vncPort)
        }
        chosen.onFrame = { [weak self] image in self?.picture.deliver(image) }
        chosen.onStatus = { [weak self] status in self?.displayStatus = status }
        return chosen
    }

    var framebufferSize: (width: Int, height: Int)? { displayStatus.size }

    var isRunning: Bool { qemuState == .running }

    func refreshFiles() {
        missing = VMConfig.missingFiles()
    }

    /// StikDebug attaches after launch, so the answer changes over time.
    func refreshJIT() {
        jit = JIT.prepare()
        if !jit.isAvailable {
            // Record which allocation strategies the kernel does allow, so the
            // reason is in the log instead of a guess.
            _ = JIT.diagnose()
        }
    }

    func start() {
        refreshFiles()
        refreshJIT()
        guard missing.isEmpty else { return }
        // Starting without executable memory does not fail — it wedges the
        // vCPU on the first generated instruction, which is far harder to read
        // than a refusal.
        guard jit.isAvailable else {
            LogCapture.shared.note(L("Запуск отменён: JIT недоступен."))
            return
        }

        // The built-in display registers itself with the machine at the one
        // moment that is safe: after qemu_init, before the main loop.
        if config.builtInDisplay, !config.headless {
            QemuBridge.shared.afterInit = {
                guard let attach = QemuBridge.shared.symbol("inferno_display_attach") else { return }
                unsafeBitCast(attach, to: (@convention(c) () -> Void).self)()
            }
        }

        QemuBridge.shared.onStateChange = { [weak self] state in
            guard let self else { return }
            self.qemuState = state
            if state == .running {
                // Give qemu_init time to open its sockets.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if !self.config.headless {
                        if let display = self.makeDisplay() {
                            self.display = display
                            display.connect()
                        }
                        else {
                            let why = L("в этой сборке библиотеки нет встроенного вывода")
                            LogCapture.shared.note("Экран: \(why). Переключитесь на VNC в параметрах.")
                            self.displayStatus = .failed(why)
                        }
                    }
                    self.serial.follow()
                    self.serial.attachInput(port: self.config.serialPort)
                }
                if self.config.network { self.watchNetwork() }
                // Report what the machine is doing once it has had time to boot.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    self.inspectMachine()
                }
                // And where the busy thread actually is — the decisive datum.
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                    Sampler.report { LogCapture.shared.note($0) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    Sampler.report { LogCapture.shared.note($0) }
                }
            }
        }
        hasRun = true
        QemuBridge.shared.environment = Settings.shared.emulatorEnvironment
        QemuBridge.shared.start(arguments: config.arguments())
    }

    /// Stops the machine the only safe way there is.
    ///
    /// Swiping the app away kills the process mid-write; QMP `quit` lets QEMU
    /// unwind its main loop and flush the disks first.
    func shutdown() {
        guard isRunning else { return }
        LogCapture.shared.note(L("Выключение: отправляю QMP quit…"))
        qmp.quit { report in LogCapture.shared.note(report) }
        display?.disconnect()
        shell.disconnect()
        serial.stop()
    }

    // MARK: Network

    /// Asks the emulator whether the guest ever configured its end of the link.
    var linkIsUp: Bool {
        guard let fn = QemuBridge.shared.symbol("inferno_net_link_up") else { return false }
        return unsafeBitCast(fn, to: (@convention(c) () -> Bool).self)()
    }

    /// Tells the guest to configure the USB interface itself.
    ///
    /// The emulator can replug the device, reset the bus and re-enumerate it,
    /// and on an image that has been used for a while none of that helps: iOS
    /// reports the link connected, starts a DHCP request, then announces
    /// `NETWORK_CONNECTION 0` and disables the controller. What does help is
    /// saying so from inside, which is what the stock guide has always told
    /// people to do by hand.
    func fixNetwork() {
        // Never in the middle of somebody else's conversation with the console:
        // a command landing between two lines of a file transfer breaks it, and
        // the poke can always wait for the next round.
        let sent = serial.ifFree {
            LogCapture.shared.note(L("Сеть: прошу гостя поднять en0…"))
            serial.send("/usr/sbin/ipconfig set en0 DHCP\n")
        }
        if !sent { LogCapture.shared.note(L("Сеть: консоль занята, попрошу позже.")) }
    }

    /// Watches the link and, if it never comes up, uses the guest's own shell.
    ///
    /// Spread out on purpose: on a phone the guest can be four minutes from
    /// power-on to a shell, and a command sent before that shell exists lands
    /// nowhere. Five tries covers the slow case; if the link is still down
    /// after that, it is not going to come up by itself.
    private func watchNetwork() {
        let tries = 5
        var attempts = 0

        func check() {
            guard isRunning else { return }
            if linkIsUp {
                if !networkUp {
                    networkUp = true
                    LogCapture.shared.note(L("Сеть: гость получил адрес."))
                }
                // Keep watching. iOS takes an address, uses it, and then
                // announces the link down and stops receiving — and a watcher
                // that stopped at the good news never saw that happen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: check)
                return
            }
            if networkUp {
                networkUp = false
                attempts = 0
                LogCapture.shared.note(L("Сеть: гость погасил связь."))
            }
            if Settings.shared.netAutoFix, attempts < tries {
                attempts += 1
                LogCapture.shared.note("Сеть: адреса всё ещё нет, попытка \(attempts) из \(tries).")
                fixNetwork()
                DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: check)
                return
            }
            // Keep looking, quietly: the guest may still sort itself out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: check)
        }

        // Long enough for an unhurried boot to have got there by itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: check)
    }

    // MARK: Files

    private lazy var files = GuestFiles(
        serial: serial,
        linkUp: { [weak self] in self?.linkIsUp ?? false },
        bringNetworkUp: { [weak self] in DispatchQueue.main.async { self?.fixNetwork() } })

    /// Checks what can be checked on the spot, so a transfer that cannot work
    /// says why at once instead of after a minute of waiting.
    private func transferBlocker() -> String? {
        if !config.network { return GuestFiles.Failure.networkOff.localizedDescription }
        if !serial.interactive { return GuestFiles.Failure.noShell.localizedDescription }
        return nil
    }

    func sendToGuest(_ url: URL) {
        guard transfer?.isRunning != true else { return }
        if let why = transferBlocker() { transfer = .failed(why); return }
        let name = url.lastPathComponent
        transfer = .running(title: "→ \(name)", done: 0, total: 0)
        LogCapture.shared.note("Файлы: отправляю \(name) в гостя")
        let files = self.files
        DispatchQueue.global(qos: .userInitiated).async {
            // Files picked from the Files app are lent, not given.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let started = Date()
            do {
                var last = Date.distantPast
                let remote = try files.send(url) { done, total in
                    // A progress bar redrawn a hundred times a second helps nobody.
                    guard Date().timeIntervalSince(last) > 0.1 || done == total else { return }
                    last = Date()
                    DispatchQueue.main.async { self.transfer = .running(title: "→ \(name)", done: done, total: total) }
                }
                let summary = TransferState.summary(url: url, seconds: Date().timeIntervalSince(started))
                DispatchQueue.main.async {
                    self.transfer = .finished("\(name) → \(remote)\n\(summary)")
                    LogCapture.shared.note("Файлы: \(name) → \(remote), \(summary)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.transfer = .failed(error.localizedDescription)
                    LogCapture.shared.note("Файлы: \(name) не отправлен — \(error.localizedDescription)")
                }
            }
        }
    }

    /// One button: unpack the `.ipa` here, carry it in by whichever channel is
    /// available, and put it in `/Applications`. The first run also leaves the
    /// helper in the guest, so every later install finds it already there.
    func installIPA(_ url: URL) {
        guard transfer?.isRunning != true else { return }
        if let why = transferBlocker() { transfer = .failed(why); return }
        guard url.pathExtension.lowercased() == "ipa" else {
            transfer = .failed(L("Нужен файл .ipa.")); return
        }
        let name = url.lastPathComponent
        transfer = .running(title: L("→ установка %@", name), done: 0, total: 0)
        LogCapture.shared.note("Установка: \(name)")
        let installer = GuestInstaller(serial: serial, files: files)
        DispatchQueue.global(qos: .userInitiated).async {
            // Files picked from the Files app are lent, not given.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let started = Date()
            // Which step is running, so the progress bar keeps saying it while
            // the bytes move. Both closures are called from this thread, one
            // after another, so the plain variable is enough.
            var phase = L("→ установка %@", name)
            do {
                var last = Date.distantPast
                let target = try installer.install(ipa: url, progress: { done, total in
                    guard Date().timeIntervalSince(last) > 0.1 || done == total else { return }
                    last = Date()
                    DispatchQueue.main.async {
                        self.transfer = .running(title: phase, done: done, total: total)
                    }
                }, note: { line in
                    phase = line
                    DispatchQueue.main.async {
                        self.transfer = .running(title: line, done: 0, total: 0)
                    }
                })
                let summary = TransferState.summary(url: url, seconds: Date().timeIntervalSince(started))
                // A warning is not a failure: the app is installed either way,
                // and saying why it will not start beats letting it look broken.
                let caveat = installer.warning.map { "\n" + $0 } ?? ""
                DispatchQueue.main.async {
                    self.transfer = .finished(L("Установлено: %@", target) + "\n" + summary + caveat)
                    LogCapture.shared.note("Установка: \(name) → \(target), \(summary)\(caveat)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.transfer = .failed(error.localizedDescription)
                    LogCapture.shared.note("Установка: \(name) — \(error.localizedDescription)")
                }
            }
        }
    }

    func receiveFromGuest(_ path: String) {
        let remote = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty, transfer?.isRunning != true else { return }
        if let why = transferBlocker() { transfer = .failed(why); return }
        let name = (remote as NSString).lastPathComponent
        transfer = .running(title: "← \(name)", done: 0, total: 0)
        LogCapture.shared.note("Файлы: забираю \(remote) из гостя")
        let files = self.files
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            do {
                var last = Date.distantPast
                let saved = try files.receive(remote) { done, total in
                    guard Date().timeIntervalSince(last) > 0.1 || done == total else { return }
                    last = Date()
                    DispatchQueue.main.async { self.transfer = .running(title: "← \(name)", done: done, total: total) }
                }
                let summary = TransferState.summary(url: saved, seconds: Date().timeIntervalSince(started))
                DispatchQueue.main.async {
                    self.transfer = .finished("\(remote) → Guest/\(saved.lastPathComponent)\n\(summary)")
                    LogCapture.shared.note("Файлы: \(remote) → \(saved.path), \(summary)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.transfer = .failed(error.localizedDescription)
                    LogCapture.shared.note("Файлы: \(remote) не получен — \(error.localizedDescription)")
                }
            }
        }
    }

    func inspectMachine() {
        Threads.report { report in LogCapture.shared.note(report) }
        qmp.inspect { report in LogCapture.shared.note(report) }
    }

    // MARK: Input

    /// Undoes the letterboxing of the aspect-fit picture, so a finger on the
    /// screen becomes the pixel underneath it whatever the guest's resolution.
    /// Where in the guest's own pixels a touch landed.
    ///
    /// Takes the rectangle the picture actually occupies rather than the whole
    /// view: it is centred on the screen with a margin around it, and the two
    /// are no longer the same box.
    private func guestPoint(from point: CGPoint, in box: CGRect) -> CGPoint? {
        guard let fb = framebufferSize, box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(fb.width) / box.width
        return CGPoint(x: (point.x - box.minX) * scale, y: (point.y - box.minY) * scale)
    }

    func tap(at point: CGPoint, in box: CGRect) {
        guard let fb = framebufferSize, let p = guestPoint(from: point, in: box) else { return }
        guard p.x >= 0, p.y >= 0, Int(p.x) < fb.width, Int(p.y) < fb.height else { return }
        display?.send(touch: p, pressed: true)
    }

    func release(at point: CGPoint, in box: CGRect) {
        guard let p = guestPoint(from: point, in: box) else { return }
        display?.send(touch: p, pressed: false)
    }

    /// Device buttons are wired to F1..F10 by the machine's button device.
    enum HardwareButton: String, CaseIterable {
        case power = "Питание"
        case volumeUp = "Громче"
        case volumeDown = "Тише"
        case home = "Home"

        var functionKey: UInt32 {
            switch self {
            case .power:      return 5   // Hold
            case .volumeDown: return 3
            case .volumeUp:   return 4
            case .home:       return 6   // Menu
            }
        }

        /// How long the guest needs to see it held.
        var hold: TimeInterval {
            switch self {
            case .power: return 2.5      // long enough for the power-off slider
            default:     return 0.2
            }
        }
    }

    /// Holds a device button down for as long as that button needs.
    ///
    /// All four used to be tapped for a tenth of a second, which is why they
    /// looked broken: the side button opens the power-off slider only after a
    /// long hold, and a tenth of a second of it does nothing at all.
    func press(_ button: HardwareButton) {
        guard let display else {
            LogCapture.shared.note(L("Кнопки: экран не подключён, нажатие некуда отправить."))
            return
        }
        LogCapture.shared.note(L("Кнопка %@ (F%d) на %.1f с", L(button.rawValue),
                                 Int(button.functionKey), button.hold))
        display.send(functionKey: button.functionKey, pressed: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + button.hold) {
            display.send(functionKey: button.functionKey, pressed: false)
        }
    }
}

// MARK: - Views

enum Pane: String, CaseIterable {
    case screen = "Экран"
    case terminal = "Терминал"
}

struct RootView: View {
    @StateObject private var model = VMModel()
    @State private var pane: Pane = .screen
    @State private var fullScreen = false
    @State private var pickFile = false
    @State private var pickIPA = false
    @State private var askPath = false
    @State private var guestPath = "/var/mobile/"
    /// Where the button sits, as a fraction of the view, so that it stays put
    /// across rotations and relaunches. Negative means it has never been moved.
    @AppStorage("menuX") private var menuX: Double = -1
    @AppStorage("menuY") private var menuY: Double = -1
    @State private var dragging: CGSize = .zero
    @Environment(\.scenePhase) private var scenePhase

    private static let buttonSize: CGFloat = 48

    /// Where the button sits. Kept clear of the island and the home indicator,
    /// which the screen behind it now runs underneath.
    private func menuPoint(in geo: GeometryProxy) -> CGPoint {
        let size = geo.size
        // Only far enough from the edge not to hang off it. Where the button is
        // allowed to go is the user's business; the island and the indicator are
        // taken into account for where it starts, not for where it may end up.
        let half = Self.buttonSize / 2 + 6
        let resting = CGPoint(x: menuX < 0 ? size.width - half - 10 : menuX * size.width,
                              y: menuY < 0 ? size.height - half - DeviceInsets.current.bottom - 10
                                           : menuY * size.height)
        return CGPoint(x: min(max(resting.x + dragging.width, half), size.width - half),
                       y: min(max(resting.y + dragging.height, half), size.height - half))
    }

    private func commitDrag(_ translation: CGSize, in geo: GeometryProxy) {
        let landed = menuPoint(in: geo)
        dragging = .zero
        guard geo.size.width > 0, geo.size.height > 0 else { return }
        menuX = landed.x / geo.size.width
        menuY = landed.y / geo.size.height
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.missing.isEmpty {
                    SetupView(model: model)
                        .navigationTitle("Inferno")
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    // No navigation bar: the guest's picture is nearly as tall
                    // as the phone's own screen, and a title bar was taking the
                    // room the corners need to be seen in. Everything that was
                    // in it now hangs off the one button below.
                    ZStack {
                        Color.black.ignoresSafeArea()
                        switch pane {
                        case .screen:   ScreenView(model: model, picture: model.picture, serial: model.serial,
                                                   fullScreen: $fullScreen)
                        case .terminal: TerminalView(model: model)
                        }
                    }
                    .overlay {
                        if !fullScreen {
                            GeometryReader { geo in
                                ControlMenu(model: model, pane: $pane, fullScreen: $fullScreen,
                                            pickFile: $pickFile, pickIPA: $pickIPA, askPath: $askPath)
                                    .position(menuPoint(in: geo))
                                    // Simultaneous, so a tap still opens the
                                    // menu and only a real drag moves it.
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 12)
                                            .onChanged { value in dragging = value.translation }
                                            .onEnded { value in commitDrag(value.translation, in: geo) }
                                    )
                                    .animation(.interactiveSpring(response: 0.3), value: dragging)
                            }
                        }
                    }
                    .toolbar(.hidden, for: .navigationBar)
                }
            }
            // Kept here rather than on the menu: the menu already presents the
            // settings sheet, and two sheet-like presentations on one view fight.
            .fileImporter(isPresented: $pickFile, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { model.sendToGuest(url) }
            }
            // A second importer, not a second sheet: only one of the two is ever
            // presented, so they do not fight the way two sheets would.
            .fileImporter(isPresented: $pickIPA, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { model.installIPA(url) }
            }
            .alert(L("Забрать файл из гостя"), isPresented: $askPath) {
                TextField(L("Путь в госте"), text: $guestPath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(L("Забрать")) { model.receiveFromGuest(guestPath) }
                Button(L("Отмена"), role: .cancel) {}
            } message: {
                Text(L("Файл появится в папке Guest приложения — её видно в «Файлах»."))
            }
            .overlay(alignment: .bottom) {
                if let transfer = model.transfer {
                    TransferBanner(state: transfer) { model.transfer = nil }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            // Coming back from StikDebug is exactly when the answer changes.
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    model.refreshJIT()
                    model.refreshFiles()
                }
            }
        }
        // The home indicator sits on top of the guest's own gesture area.
        .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
        // Only while the guest is there to receive the swipes: the rest of the
        // time the host's own gestures should behave normally.
        .onAppear { SystemGestures.apply(deferEdges: model.isRunning) }
        .onChange(of: model.isRunning) { running in
            SystemGestures.apply(deferEdges: running)
        }
    }
}

struct ControlMenu: View {
    @ObservedObject var model: VMModel
    @Binding var pane: Pane
    @Binding var fullScreen: Bool
    @Binding var pickFile: Bool
    @Binding var pickIPA: Bool
    @Binding var askPath: Bool
    @State private var showSettings = false
    @State private var confirmQuit = false

    /// The terminal's own choice of what to show. Held by the same key the
    /// terminal holds it under, so the two stay in step.
    @AppStorage("terminalSource") private var sourceName = TerminalView.Source.emulator.rawValue

    var body: some View {
        Menu {
            Section(L("Вид")) {
                Picker(L("Вид"), selection: $pane) {
                    ForEach(Pane.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                }
                if pane == .terminal {
                    Picker(L("Источник"), selection: $sourceName) {
                        ForEach(TerminalView.Source.allCases, id: \.self) {
                            Text(L($0.rawValue)).tag($0.rawValue)
                        }
                    }
                }
            }

            Section(L("Машина")) {
                Button(L("Параметры…"), systemImage: "gearshape") { showSettings = true }
                Button(startTitle, systemImage: "play.fill") {
                    model.start()
                }
                .disabled(model.isRunning || model.hasRun || !model.missing.isEmpty)
                Button(L("Во весь экран"), systemImage: "arrow.up.left.and.arrow.down.right") {
                    fullScreen = true
                }
                Button(L("Поднять сеть в госте"), systemImage: "network") {
                    model.fixNetwork()
                }
                .disabled(!model.isRunning)
                Button(role: .destructive) {
                    confirmQuit = true
                } label: {
                    Label(L("Выключить машину…"), systemImage: "power")
                }
                .disabled(!model.isRunning)
            }

            Section(L("Файлы")) {
                Button(L("Отправить файл в гостя…"), systemImage: "square.and.arrow.up") {
                    pickFile = true
                }
                Button(L("Забрать файл из гостя…"), systemImage: "square.and.arrow.down") {
                    askPath = true
                }
                Button(L("Установить .ipa в гостя…"), systemImage: "arrow.down.app") {
                    pickIPA = true
                }
            }
            .disabled(!model.isRunning || model.transfer?.isRunning == true)

            Section(L("Кнопки устройства")) {
                ForEach(VMModel.HardwareButton.allCases, id: \.self) { button in
                    Button(L(button.rawValue)) { model.press(button) }
                }
            }
            .disabled(!model.isRunning)

        } label: {
            // The one control on screen, so it is given some presence: a glass
            // disc that stays legible over both the guest's picture and the
            // terminal's black.
            glassDisc
        }
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .confirmationDialog(L("Выключить машину?"), isPresented: $confirmQuit, titleVisibility: .visible) {
            Button(L("Выключить"), role: .destructive) { model.shutdown() }
            Button(L("Отмена"), role: .cancel) {}
        } message: {
            Text(L("QEMU допишет диски на файлы и завершится. Чтобы запустить машину заново, перезапустите приложение."))
        }
    }

    /// Liquid glass proper where the system provides it, and a material disc
    /// that reads much the same on anything older.
    @ViewBuilder
    private var glassDisc: some View {
        let face = Image(systemName: "slider.horizontal.3")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
        // glassEffect itself is only declared in the iOS 26 SDK — #available
        // guards it at runtime, but a toolchain built against an older SDK
        // (Xcode below 26, as CI's still is) can't even see the symbol to
        // compile this file. Gate it on the compiler too, so the same source
        // builds on both: real glass with Xcode 26, the material fallback
        // everywhere else.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Clipped as well as shaped. While the menu opens, the glass is
            // handed to the presentation animation, and for a frame or two it
            // draws as the square it really is before the shape catches up.
            face.glassEffect(.regular.interactive(), in: Circle())
                .clipShape(Circle())
                .contentShape(Circle())
        } else {
            face.background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                .clipShape(Circle())
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        }
        #else
        face.background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .clipShape(Circle())
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        #endif
    }

    private var startTitle: String {
        if model.isRunning { return L("Запущена") }
        if model.hasRun { return L("Остановлена — перезапустите приложение") }
        return L("Запустить")
    }

}

/// The guest display. Taps become absolute pointer events, so a touch lands
/// exactly where the finger is instead of dragging a cursor around.
struct ScreenView: View {
    @ObservedObject var model: VMModel
    /// Watched here and nowhere else, so that a new frame redraws the picture
    /// and leaves the rest of the interface alone.
    @ObservedObject var picture: GuestFrame
    /// Watched for the console's flow rate, which sits beside the frame count.
    @ObservedObject var serial: SerialConsole
    @ObservedObject private var settings = Settings.shared
    @Binding var fullScreen: Bool

    /// How far the picture keeps from each edge.
    ///
    /// The same at top and bottom, and enough to clear whichever of the two
    /// system furnishings is larger — the island above, the home indicator
    /// below. Sideways it needs less, so it takes less.
    private func margins() -> (h: CGFloat, v: CGFloat) {
        guard !fullScreen else { return (0, 0) }
        let insets = DeviceInsets.current
        return (16, max(insets.top, insets.bottom, 16))
    }

    /// The rectangle the guest's picture occupies, centred on the whole screen.
    ///
    /// Worked out here rather than left to `aspectRatio` for two reasons: the
    /// corner radius is a fraction of the picture's own width, and a touch has
    /// to be mapped back into the guest's pixels. Nothing else knows either.
    private func drawn(in view: CGSize, _ m: (h: CGFloat, v: CGFloat)) -> CGRect? {
        guard let fb = model.framebufferSize, fb.width > 0, fb.height > 0,
              view.width > 0, view.height > 0
        else { return nil }
        let free = CGSize(width: max(view.width - m.h * 2, 1),
                          height: max(view.height - m.v * 2, 1))
        let scale = min(free.width / CGFloat(fb.width), free.height / CGFloat(fb.height))
        let size = CGSize(width: CGFloat(fb.width) * scale, height: CGFloat(fb.height) * scale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The console's flow, in whichever unit keeps it to three digits.
    static func rate(_ bytes: Double) -> String {
        if bytes >= 1024 * 1024 { return L("%.1f МБ/с", bytes / (1024 * 1024)) }
        if bytes >= 1024 { return L("%.0f КБ/с", bytes / 1024) }
        return L("%.0f Б/с", bytes)
    }

    var body: some View {
        GeometryReader { geo in
            let box = drawn(in: geo.size, margins())
            let radius = settings.roundedScreen ? (box?.width ?? 0) * GuestBezel.radiusOverWidth : 0
            ZStack {
                Color.black
                if let frame = picture.image {
                    // At the native resolution there is nothing to interpolate;
                    // below it the picture is stretched to cover the same area,
                    // and whether that is smoothed is a matter of taste.
                    Image(decorative: frame, scale: 1.0)
                        .resizable()
                        .interpolation(settings.smoothUpscale ? .high : .none)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: box?.width, height: box?.height)
                        // Continuous, not circular: Apple's corners are
                        // squircles, and a plain arc reads as the wrong shape
                        // next to the real device.
                        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                        .position(x: box?.midX ?? geo.size.width / 2,
                                  y: box?.midY ?? geo.size.height / 2)
                    if settings.showFPS, let box {
                        // The console rate belongs here too: when the guest is
                        // pouring kernel log into the UART, the emulated cores
                        // are formatting text instead of drawing, and the frame
                        // count on its own does not say so.
                        Text(String(format: "%.0f FPS · %@", picture.fps, Self.rate(serial.consoleRate)))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .position(x: box.midX, y: min(box.maxY + 16, geo.size.height - 8))
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(placeholder)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if let box { model.tap(at: value.location, in: box) }
                    }
                    .onEnded { value in
                        if let box { model.release(at: value.location, in: box) }
                    }
            )
            // Deliberately small and dim: it sits over the guest's picture, and
            // in full screen it is the only way back.
            .overlay(alignment: .topTrailing) {
                if fullScreen {
                    Button {
                        fullScreen = false
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    }
                    .opacity(0.75)
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
            }
        }
        // Always the whole screen. A reader that respects the safe area is
        // handed the box left over after the island and the home indicator have
        // taken their share — 59 pt off the top, 34 off the bottom on an iPhone
        // 15 — and centring in that is not centring on the screen. Measuring the
        // whole thing and keeping the margin ourselves is what puts the picture
        // in the actual middle.
        .ignoresSafeArea()
    }

    private var placeholder: String {
        switch model.qemuState {
        case .idle:
            if case .unavailable(let why) = model.jit {
                return L("JIT недоступен — %@.\nБез него транслятор не сможет выделить буфер, и машина не запустится.", why)
            }
            return L("Откройте меню и запустите машину")
        case .running:
            switch model.displayStatus {
            case .connected(let w, let h): return L("Экран %d×%d подключён, ждём первый кадр", w, h)
            case .connecting:              return L("Машина работает, подключаемся к экрану…")
            case .failed(let why):         return L("Экран недоступен: %@", why)
            case .disconnected:            return L("Машина работает, экран ещё не слушает")
            }
        case .stopped:          return L("Машина остановлена")
        case .failed(let text): return text
        }
    }
}

/// The guest's serial console — the boot log, which stays useful while the
/// screen is still black.
struct TerminalView: View {
    @ObservedObject var model: VMModel
    /// The shell channel is its own object, so watching the model alone would
    /// miss everything it does.
    @ObservedObject private var shell: ShellChannel
    @ObservedObject private var log = LogCapture.shared
    @ObservedObject private var settings = Settings.shared
    @StateObject private var screen = GuestScreen()
    /// Kept where the app keeps everything else it remembers, so that leaving
    /// for the screen and coming back does not throw the choice away.
    @AppStorage("terminalSource") private var sourceName = Source.emulator.rawValue
    @State private var command = ""
    /// Changed whenever the console should jump to its last line.
    @State private var pin = 0

    init(model: VMModel) {
        _model = ObservedObject(wrappedValue: model)
        _shell = ObservedObject(wrappedValue: model.shell)
    }

    private var source: Source { Source(rawValue: sourceName) ?? .emulator }

    private func sendCommand() {
        guard !command.isEmpty else { return }
        switch source {
        case .shell:  shell.send(command)
        default:      model.serial.send(command + "\n")
        }
        command = ""
    }

    /// Whether there is anywhere to type. The console takes commands as soon as
    /// the bootstrap's bash is on it; the shell only once the guest has called
    /// back.
    private var acceptsInput: Bool {
        switch source {
        case .shell:        return shell.isUp
        case .guestConsole: return model.serial.interactive
        case .emulator:     return false
        }
    }

    /// The indicator at the bottom belongs to whatever is on screen.
    private var linkIsGood: Bool {
        source == .shell ? shell.isUp : model.serial.connected
    }

    /// Opening the pane is the request to open the channel. A failure is not
    /// retried on its own — it would go on asking the guest forever.
    private func openShellIfNeeded() {
        guard source == .shell, shell.state == .idle else { return }
        shell.connect()
    }

    enum Source: String, CaseIterable {
        case emulator = "Эмулятор"
        case shell = "Шелл"
        case guestConsole = "Лог ядра"
    }

    private var emulatorText: String {
        log.text.isEmpty
            ? L("Пока пусто. Здесь появятся сообщения эмулятора, включая причину отказа запуска.")
            : log.text
    }

    @ViewBuilder
    private func shellPane(_ fitted: CGFloat) -> some View {
        switch shell.state {
        case .up:
            TerminalTextView(text: shell.screen.content, revision: shell.screen.revision,
                             follow: settings.terminalFollow, pin: pin)
                .onAppear { shell.use(fontSize: fitted) }
                .onChange(of: fitted) { shell.use(fontSize: $0) }
        case .connecting:
            notice(L("Прошу гостя подключиться…"), busy: true, action: nil)
        case .idle:
            notice(L("Отдельный канал: гость сам звонит приложению по сети, и сюда не попадает ничего, кроме написанного шеллом. Нужны включённая сеть и bash на консоли."),
                   busy: false, action: L("Подключить"))
        case .failed(let why):
            notice(why, busy: false, action: L("Попробовать снова"))
        }
    }

    @ViewBuilder
    private func consolePane(_ fitted: CGFloat) -> some View {
        if model.serial.text.isEmpty {
            Text(L("Ожидание вывода консоли…"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
        } else {
            TerminalTextView(text: screen.content, revision: screen.revision,
                             follow: settings.terminalFollow, pin: pin)
                .onAppear { screen.use(fontSize: fitted) }
                .onChange(of: fitted) { screen.use(fontSize: $0) }
        }
    }

    private func emulatorPane() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(emulatorText)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .id("log")
            }
            .onChange(of: log.text) { _ in
                if settings.terminalFollow { proxy.scrollTo("log", anchor: .bottom) }
            }
        }
    }

    private func notice(_ text: String, busy: Bool, action: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if busy { ProgressView() }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let action {
                HStack(spacing: 10) {
                    Button(action, systemImage: "bolt.horizontal") {
                        shell.connect()
                    }
                    .buttonStyle(.borderedProminent)
                    // The console path needs no network at all, so it stays
                    // offered even when the better one keeps failing.
                    Button(L("Через консоль"), systemImage: "terminal") {
                        shell.connectOverConsole()
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(!model.serial.interactive)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    var body: some View {
        ZStack(alignment: .top) {
            GeometryReader { geo in
                // The guest is certain the console is eighty columns wide — apt
                // truncates its progress line at seventy-nine and erases it with
                // a row of spaces exactly that long. So the type is sized to
                // make eighty columns fit rather than letting the grid wrap and
                // turn every drawing into nonsense.
                let fitted = min(max((geo.size.width - 16)
                                     / (CGFloat(TerminalEmulator.width) * 0.6), 5.5), 13)
                Group {
                    switch source {
                    case .shell:        shellPane(fitted)
                    case .guestConsole: consolePane(fitted)
                    case .emulator:     emulatorPane()
                    }
                }
                // Room for the two things floating over the text.
                .safeAreaInset(edge: .top) { Color.clear.frame(height: 36) }
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: acceptsInput ? 60 : 72) }
            }
            .onAppear {
                screen.rebuild(from: model.serial.text, hideKernel: settings.hideKernel,
                               sequence: model.serial.sequence)
                pin += 1
                openShellIfNeeded()
            }
            .onChange(of: sourceName) { _ in
                pin += 1
                openShellIfNeeded()
            }
            .onChange(of: model.serial.sequence) { seq in
                screen.feed(model.serial.chunk, sequence: seq)
            }
            .onChange(of: shell.state) { _ in pin += 1 }
            .onChange(of: settings.hideKernel) { on in
                screen.rebuild(from: model.serial.text, hideKernel: on,
                               sequence: model.serial.sequence)
                pin += 1
            }

            header
        }
        .overlay(alignment: .bottom) { if acceptsInput { prompt } }
    }

    /// What is being shown and whether it is alive, as one small glass pill.
    /// It replaces a whole bar of controls: the choice itself now lives in the
    /// menu, and the toggles in the settings.
    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(linkIsGood ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(L(source.rawValue))
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .padding(.top, 6)
    }

    /// The command line, floating clear of the text rather than boxed in under
    /// a divider.
    private var prompt: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
            TextField(L("Команда гостю"), text: $command)
                .font(.system(size: 14, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.send)
                .onSubmit(sendCommand)
            if source == .shell {
                Button {
                    shell.sendControl(0x03)
                } label: {
                    Text("^C")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button(action: sendCommand) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(command.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .disabled(command.isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        // Clear of the floating menu button in the corner.
        .padding(.leading, 12)
        .padding(.trailing, 84)
        .padding(.bottom, 14)
    }
}

/// Shown until the guest images are present in the app's Documents folder.
struct SetupView: View {
    @ObservedObject var model: VMModel

    var body: some View {
        List {
            Section {
                Text(L("Откройте «Файлы» → «На iPhone» → «Inferno» и скопируйте туда InfernoData и AppleSEPROM-Cebu-B1."))
                    .font(.callout)
                Text(L("Папки уже созданы, файлы можно класть прямо в них. Подробности — в файле «КУДА КЛАСТЬ ФАЙЛЫ.txt» там же."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(L("Не хватает")) {
                ForEach(model.missing, id: \.self) { item in
                    Label(item, systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button(L("Проверить снова"), systemImage: "arrow.clockwise") {
                    model.refreshFiles()
                }
            }
        }
    }
}

// MARK: - File transfer

enum TransferState: Equatable {
    case running(title: String, done: Int64, total: Int64)
    case finished(String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    static func size(_ bytes: Int64) -> String {
        bytes < 1 << 20
            ? L("%.0f КБ", Double(bytes) / 1024)
            : L("%.1f МБ", Double(bytes) / 1_048_576)
    }

    /// "5,0 МБ за 10,1 с · 507 КБ/с" — the rate is what tells whether the fast
    /// path was taken.
    static func summary(url: URL, seconds: TimeInterval) -> String {
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let rate = seconds > 0 ? Double(bytes) / seconds / 1024 : 0
        return L("%@ за %.1f с · %.0f КБ/с", size(bytes), seconds, rate)
    }
}

/// Sits at the bottom while a file moves, and stays with the outcome until
/// dismissed: a transfer that ended while the menu was closed should still say
/// how it ended.
struct TransferBanner: View {
    let state: TransferState
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            switch state {
            case .running(let title, let done, let total):
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.footnote).lineLimit(1)
                    if total > 0 {
                        ProgressView(value: Double(done), total: Double(total))
                        Text(L("%@ из %@", TransferState.size(done), TransferState.size(total)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            case .finished(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text).font(.footnote)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.footnote)
            }
            Spacer(minLength: 0)
            if !state.isRunning {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
