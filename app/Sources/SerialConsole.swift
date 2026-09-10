import Foundation

/// Shows the guest's serial console — the boot log, and the first place to look
/// when the screen stays black.
///
/// The emulator writes it to a file rather than only offering a socket: a socket
/// throws away everything printed before a client attaches, and the guest starts
/// talking long before the interface can connect. Reading the file means the log
/// always starts at the first byte, and survives reconnects.
final class SerialConsole: ObservableObject {
    @Published private(set) var text: String = ""
    @Published private(set) var connected = false

    /// The bytes that arrived last, and a number that counts them.
    ///
    /// The terminal is fed as the console speaks rather than rebuilt from the
    /// whole log every half second: escape codes only mean anything in order,
    /// and replaying a quarter of a megabyte four times a second to learn that
    /// would be silly. The counter lets the view tell a chunk it has already
    /// seen from a new one.
    @Published private(set) var chunk: String = ""
    @Published private(set) var sequence: Int = 0
    /// Whether the console has already been reported as silent, so that it is
    /// said once rather than twice a second forever.
    private var quiet = false

    private var handle: FileHandle?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "inferno.serial")
    /// A long boot produces a lot; keep the tail.
    private let limit = 256 * 1024

    private var url: URL { VMConfig.guestConsoleLog }

    /// The console is a socket as well as a file: the file keeps the history
    /// from the very first byte, the socket carries what we type back. With the
    /// jailbreak bootstrap installed a bash daemon sits on /dev/console, so this
    /// is a real shell rather than a log.
    private var input: Sock?
    private var attached = false
    private var stopping = false
    @Published private(set) var interactive = false
    /// Commands arrive from the terminal and from the file transfer at once;
    /// two writes interleaved byte by byte would be a command neither meant.
    private let sendLock = NSLock()

    /// Held for a whole conversation, not for a single write.
    ///
    /// Locking each write was not enough. A file transfer is a sequence — set a
    /// variable, make a directory, ask whether it is there — and the network
    /// watchdog put `ipconfig set en0 DHCP` between two of those lines. Nothing
    /// was garbled, and the sequence still fell apart, because the guest ran
    /// somebody else's command in the middle of ours.
    private let conversation = NSLock()

    /// Runs a sequence of commands with the console to itself. Blocks; never
    /// call it from the main thread.
    func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        conversation.lock()
        defer { conversation.unlock() }
        return try body()
    }

    /// The same, for a caller with nothing to say if the console is busy —
    /// the watchdog would rather skip a poke than break a transfer.
    @discardableResult
    func ifFree(_ body: () -> Void) -> Bool {
        guard conversation.try() else { return false }
        defer { conversation.unlock() }
        body()
        return true
    }

    /// Everyone who wants the console's output as it arrives. The file transfer
    /// picks its answers out of it.
    private let tapsLock = NSLock()
    private var taps: [UUID: (Data) -> Void] = [:]

    func tap(_ handler: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        tapsLock.lock()
        taps[id] = handler
        tapsLock.unlock()
        return id
    }

    func untap(_ id: UUID) {
        tapsLock.lock()
        taps[id] = nil
        tapsLock.unlock()
    }

    private func deliver(_ data: Data) {
        tapsLock.lock()
        let handlers = Array(taps.values)
        tapsLock.unlock()
        handlers.forEach { $0(data) }
    }

    /// Keeps a reader on the console socket for as long as the machine runs.
    ///
    /// Reconnecting matters more than it looks. Somebody has to take what the
    /// emulator writes; when this loop ended — a read error, a socket timeout —
    /// nothing did, the emulator's buffer filled, and everything behind it
    /// stopped with it. So the loop is a loop: if the read ends and the machine
    /// has not been asked to stop, it connects again.
    func attachInput(port: UInt16) {
        guard !attached else { return }
        attached = true
        Thread.detachNewThread { [weak self] in
            while self?.stopping == false { self?.drain(port: port) }
        }
    }

    private func drain(port: UInt16) {
        autoreleasepool {
            let sock = Sock()
            if sock.connect(port: port) != nil {
                Thread.sleep(forTimeInterval: 2)
                return
            }
            // The console can stay silent for minutes. With the socket's usual
            // twenty-second receive timeout this took the first quiet spell for
            // the end of the stream and stopped for good — after which nobody
            // saw the guest's answers, and the file transfer reported a dead
            // shell while the shell was answering on screen.
            sock.waitIndefinitely()
            input = sock
            DispatchQueue.main.async { self.interactive = true }
            // What is drained goes to anyone waiting for an answer.
            while input != nil, let data = sock.readSome() { deliver(data) }

            sock.close()
            if input === sock { input = nil }
            DispatchQueue.main.async { self.interactive = false }
            if !stopping { Thread.sleep(forTimeInterval: 1) }
        }
    }

    func send(_ text: String) {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard let input else { return }
        _ = input.write(Array(text.utf8))
    }

    /// Starts following the log, waiting for the file to appear if necessary.
    func follow() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Often enough that output does not arrive in visible steps. A read that
        // finds nothing costs one syscall, and the work behind a read that finds
        // something is the same however it is divided up.
        timer.schedule(deadline: .now(), repeating: .milliseconds(120))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        stopping = true
        input?.close()
        input = nil
        DispatchQueue.main.async { self.interactive = false }
        timer?.cancel()
        timer = nil
        try? handle?.close()
        handle = nil
        DispatchQueue.main.async { self.connected = false }
    }

    func clear() {
        text = ""
    }

    private func poll() {
        if handle == nil {
            guard FileManager.default.fileExists(atPath: url.path),
                  let opened = try? FileHandle(forReadingFrom: url)
            else { return }
            handle = opened
            DispatchQueue.main.async { self.connected = true }
        }

        guard let handle else { return }
        guard let bytes = try? handle.readToEnd(), !bytes.isEmpty else {
            // A shell prompt carries no newline after it, so whoever reads this
            // cannot tell a half-written line from a finished one until the
            // console goes quiet. Saying so once, when it does, is what makes
            // the prompt appear.
            if !quiet {
                quiet = true
                DispatchQueue.main.async {
                    self.chunk = ""
                    self.sequence += 1
                }
            }
            return
        }
        quiet = false

        let piece = String(decoding: bytes, as: UTF8.self)
        DispatchQueue.main.async {
            self.text += piece
            if self.text.count > self.limit {
                self.text = String(self.text.suffix(self.limit))
            }
            self.chunk = piece
            self.sequence += 1
        }
    }
}
