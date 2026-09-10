import Combine
import Darwin
import Foundation
import UIKit

/// The guest's shell, separated from the kernel's chatter.
///
/// One console shared by the kernel and the shell means every answer comes back
/// interleaved with driver messages, and no amount of pattern matching makes
/// that separation honest — a message in an unfamiliar shape gets through, and
/// one that lands in the middle of a line takes the line with it.
///
/// There are two ways out, and the channel takes whichever is available.
///
/// **Over the network.** Slirp runs inside this very process and turns 10.0.2.2
/// into its own loopback, and bash opens TCP sockets by itself through
/// `/dev/tcp`. The console is used once, to ask the guest to call back, and from
/// then on the shell has a socket to itself. This is the better channel — real
/// interactivity, no per-line cost — and the same path already carries files.
///
/// **Over the console.** When the guest has no working link, the console is all
/// there is, so the shell marks where its answer begins and ends. Between those
/// two marks is the command's output; outside them nothing is shown at all, so
/// the kernel's endless chatter never reaches the pane.
///
/// Tagging every line was tried first and was too slow to use: it put a bash
/// `read` loop in front of the output, and `read` takes one byte per system
/// call, which an emulated processor feels. The marks cost two `echo`s per
/// command and let the output travel straight from the command to the console.
/// What the kernel manages to squeeze into the window between them is still
/// sifted by the pattern filter — that part remains a guess.
///
/// Like the console, this is a main-thread object: reading happens on threads of
/// its own, but everything it changes is changed after hopping back.
final class ShellChannel: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case up(Transport)
        case failed(String)
    }

    enum Transport: Equatable {
        case network
        case console
    }

    @Published private(set) var state: State = .idle

    /// The terminal this channel draws into. Its changes are republished here so
    /// that a view watching the channel sees them without watching both.
    let screen = GuestScreen()

    private let serial: SerialConsole
    private let linkUp: () -> Bool

    private var sock: Sock?
    private var forward: AnyCancellable?
    /// Tells a reader whose channel has been replaced to stop talking.
    private var generation = 0

    // The console transport's state.
    private var ear: UUID?
    private var marker = ""
    private var inside = false
    private var pending = Data()
    private let filter = KernelFilter()

    /// The guest's name for this app, as slirp presents it.
    private static let host = "10.0.2.2"

    init(serial: SerialConsole, linkUp: @escaping () -> Bool) {
        self.serial = serial
        self.linkUp = linkUp
        forward = screen.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var isUp: Bool { if case .up = state { return true }; return false }

    var transport: Transport? { if case .up(let t) = state { return t }; return nil }

    func use(fontSize: CGFloat) { screen.use(fontSize: fontSize) }

    /// Opens the best channel the guest can manage right now.
    ///
    /// The network is not waited for and the guest is not asked to bring it up:
    /// something else in the app already watches the link and does the asking,
    /// and a second voice only produced a screenful of `ipconfig` lines.
    func connect() {
        guard state != .connecting, !isUp else { return }
        guard serial.interactive else {
            state = .failed(L("Шелл гостя не отвечает: на консоли должен сидеть bash из бутстрапа."))
            return
        }

        state = .connecting
        generation += 1
        let mine = generation
        release()
        screen.reset()

        guard linkUp() else {
            openConsole(mine, note: L("Сети у гостя нет — шелл идёт по консоли."))
            return
        }
        openNetwork(mine)
    }

    /// Opens the channel over the console explicitly, whatever the link says.
    func connectOverConsole() {
        guard serial.interactive else {
            state = .failed(L("Шелл гостя не отвечает: на консоли должен сидеть bash из бутстрапа."))
            return
        }
        state = .connecting
        generation += 1
        release()
        screen.reset()
        openConsole(generation, note: nil)
    }

    // MARK: - Over the network

    private func openNetwork(_ mine: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let listener: LoopbackListener
            do {
                listener = try LoopbackListener()
            } catch {
                self.report(mine, error.localizedDescription)
                return
            }

            // What the console says while we wait is worth listening to: bash
            // reports a refusal at once, and hearing it beats sitting out the
            // whole timeout.
            let complaint = Complaint()
            let listening = self.serial.tap { data in complaint.consider(data) }

            // `exec` on the inner bash so the subshell does not linger; the whole
            // thing in the background so the console gets its prompt back. Kept
            // short on purpose: the console has no flow control, and a busy guest
            // drops bytes inside a single line.
            self.serial.send("(exec 3<>/dev/tcp/\(Self.host)/\(listener.port);exec bash -i<&3>&3 2>&3)&\n")

            var accepted: Int32?
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let fd = listener.accept(timeout: 0.5) { accepted = fd; break }
                if complaint.heard != nil { break }
                if self.generation != mine { self.serial.untap(listening); return }
            }
            self.serial.untap(listening)

            guard let descriptor = accepted else {
                // The console is still there, and it can carry a shell too.
                let why = complaint.heard ?? L("Гость не позвонил обратно.")
                DispatchQueue.main.async {
                    guard self.generation == mine else { return }
                    self.openConsole(mine, note: why + " " + L("Перехожу на консоль."))
                }
                return
            }

            let sock = Sock(adopting: descriptor)
            // The shell may say nothing for minutes on end; a receive timeout
            // would take the first quiet spell for the end of the stream.
            sock.waitIndefinitely()

            DispatchQueue.main.async {
                guard self.generation == mine else { sock.close(); return }
                self.sock = sock
                self.state = .up(.network)
            }

            while let data = sock.readSome() {
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    guard self.generation == mine else { return }
                    self.screen.append(text)
                }
            }

            DispatchQueue.main.async {
                guard self.generation == mine else { return }
                self.sock = nil
                self.state = .failed(L("Гость закрыл канал."))
            }
        }
    }

    // MARK: - Over the console

    /// Teaches the guest two marks, then checks that it learned them.
    ///
    /// The marks are assembled out of shell variables on purpose. The console
    /// shell echoes back everything typed at it, so a command carrying the mark
    /// literally would announce the mark twice — once in the echo, once for
    /// real — and the echo would open a window that was never meant to open.
    /// Written as `$s` and `$e`, the echo shows the names and only the shell's
    /// own output ever shows the values.
    private func openConsole(_ mine: Int, note: String?) {
        let tag = String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
        marker = "Q\(tag)"
        inside = false
        pending = Data()
        filter.reset()

        ear = serial.tap { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }
                self.absorb(data)
            }
        }

        // One conversation: the two lines only mean anything together.
        let mark = marker
        DispatchQueue.global(qos: .userInitiated).async {
            self.serial.exclusive {
                self.serial.send("m=\(mark);s=S$m;e=E$m\n")
                self.serial.send("echo \"$s\";echo ok;echo \"$e\"\n")
            }
        }

        if let note { LogCapture.shared.note("Шелл: " + note) }

        // If the guest never answers the probe, the console is not carrying a
        // shell that understands us.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.generation == mine, self.state == .connecting else { return }
            self.release()
            self.state = .failed(L("Шелл не отозвался на проверку. Похоже, на консоли не bash."))
        }
    }

    /// Shows what lies between the marks, and nothing else.
    private func absorb(_ data: Data) {
        pending.append(data)
        if pending.count > 1 << 20 { pending.removeFirst(pending.count - (1 << 19)) }

        while let end = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<end]
            pending.removeSubrange(pending.startIndex...end)

            let text = String(decoding: line, as: UTF8.self)
            if text.contains("S" + marker) { inside = true; continue }
            if text.contains("E" + marker) { inside = false; finished(); continue }
            guard inside else { continue }
            // The kernel can still write into the window; that much is filtered
            // the old way, by the shape of what it writes.
            screen.append(filter.process(text + "\r\n"))
        }
    }

    private func finished() {
        if state == .connecting {
            state = .up(.console)
            screen.append("\u{1B}[32m" + L("Канал по консоли открыт: показывается только вывод команд.")
                          + "\u{1B}[0m\r\n")
        }
    }

    // MARK: - Talking

    /// Sends a command, and shows it.
    ///
    /// Over the network nothing comes back on its own: bash turns off line
    /// editing when its input is not a terminal, and with it the echo. Over the
    /// console the shell's echo is not marked, so it is dropped along with the
    /// kernel's lines. Either way the app has to print what was typed.
    func send(_ command: String) {
        switch transport {
        case .network:
            guard let sock else { return }
            screen.append(command + "\r\n")
            DispatchQueue.global(qos: .userInitiated).async {
                _ = sock.write(Array((command + "\n").utf8))
            }
        case .console:
            screen.append("\u{1B}[36m# \u{1B}[0m" + command + "\r\n")
            serial.send("echo \"$s\";{ \(command) ;} 2>&1;echo \"$e\"\n")
        case nil:
            break
        }
    }

    /// Ctrl-C — over the console it goes to whatever the console shell is doing,
    /// which is the same command.
    func sendControl(_ byte: UInt8) {
        switch transport {
        case .network:
            guard let sock else { return }
            DispatchQueue.global(qos: .userInitiated).async { _ = sock.write([byte]) }
        case .console:
            serial.send(String(UnicodeScalar(byte)))
        case nil:
            break
        }
    }

    func disconnect() {
        generation += 1
        release()
        state = .idle
    }

    private func release() {
        sock?.close()
        sock = nil
        if let ear { serial.untap(ear) }
        ear = nil
        pending = Data()
    }

    private func report(_ mine: Int, _ reason: String) {
        DispatchQueue.main.async {
            guard self.generation == mine else { return }
            self.state = .failed(reason)
        }
    }
}

/// Listens to the console for the reasons a call back cannot be made.
private final class Complaint {
    private let lock = NSLock()
    private var found: String?

    /// Whatever bash said, translated, or nil while it has said nothing.
    var heard: String? {
        lock.lock()
        defer { lock.unlock() }
        return found
    }

    func consider(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let reason: String
        if text.contains("Network is unreachable") || text.contains("No route to host") {
            reason = L("Сети в госте нет: bash ответил «Network is unreachable».")
        } else if text.contains("Connection refused") {
            reason = L("Гость дозвонился, но соединение отвергнуто.")
        } else if text.contains("/dev/tcp") && text.contains("No such file") {
            reason = L("В этом bash нет поддержки /dev/tcp.")
        } else {
            return
        }
        lock.lock()
        if found == nil { found = reason }
        lock.unlock()
    }
}
