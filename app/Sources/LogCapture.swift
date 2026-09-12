import Foundation

/// Captures the emulator's stdout/stderr.
///
/// QEMU reports fatal configuration problems to stderr and then calls exit(),
/// which inside an app looks like a crash with no explanation. Redirecting both
/// streams into a pipe means the reason is on screen — and, because it is also
/// written to a file, still readable after a restart.
final class LogCapture: ObservableObject {
    static let shared = LogCapture()

    @Published private(set) var text: String = ""

    private let pipe = Pipe()
    private var started = false
    private let limit = 128 * 1024
    private var fileHandle: FileHandle?

    var logFileURL: URL {
        VMConfig.documents.appendingPathComponent("emulator.log")
    }

    /// The log from the run before this one.
    ///
    /// The interesting run is almost always the one that just died, and the
    /// app is started again to find out why — which used to overwrite the only
    /// copy of the evidence. Every crash report we were sent was from a session
    /// where nothing had happened yet.
    var previousLogFileURL: URL {
        VMConfig.documents.appendingPathComponent("emulator.prev.log")
    }

    func start() {
        guard !started else { return }
        started = true

        try? FileManager.default.removeItem(at: previousLogFileURL)
        try? FileManager.default.moveItem(at: logFileURL, to: previousLogFileURL)
        // Keep a copy on disk: the process may die before the UI updates.
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)

        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            try? self.fileHandle?.write(contentsOf: data)
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self.text += chunk
                if self.text.count > self.limit {
                    self.text = String(self.text.suffix(self.limit))
                }
            }
        }
    }

    func note(_ line: String) {
        DispatchQueue.main.async { self.text += line + "\n" }
        try? fileHandle?.write(contentsOf: Data((line + "\n").utf8))
    }
}
