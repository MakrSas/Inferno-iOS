import Foundation

func L(_ s: String) -> String { s }
func L(_ s: String, _ a: CVarArg...) -> String { String(format: s, arguments: a) }

enum VMConfig {
    static var documents: URL { FileManager.default.temporaryDirectory }
    static var guestConsoleLog: URL { URL(fileURLWithPath: "/tmp/harness-console.log") }
    static var transferImage: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["XFER"] ?? "/nonexistent")
    }
    static let transferBytes: Int64 = 16 * 1024 * 1024
}

func crc(_ url: URL) -> String {
    var s = PosixChecksum()
    let d = try! Data(contentsOf: url)
    d.withUnsafeBytes { s.update($0) }
    return "\(s.value) \(s.length)"
}

let serial = SerialConsole()
serial.attachInput(port: 4555)
Thread.sleep(forTimeInterval: 2)
let files = GuestFiles(serial: serial, linkUp: { true }, bringNetworkUp: { })

let mode = CommandLine.arguments[1]
do {
    if mode == "install" {
        let ipa = URL(fileURLWithPath: CommandLine.arguments[2])
        let t0 = Date()
        let target = try GuestInstaller(serial: serial, files: files)
            .install(ipa: ipa, progress: { _, _ in }, note: { print("   \($0)") })
        print(String(format: "УСТАНОВЛЕНО: %@ за %.1f с", target, Date().timeIntervalSince(t0)))
    } else {
        // Туда и обратно, со сверкой.
        let size = 5 * 1024 * 1024
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-test.bin")
        try Data((0..<size).map { _ in UInt8.random(in: 0...255) }).write(to: local)
        let want = crc(local)
        let remote = "/var/mobile/.inferno/test.bin"

        var t0 = Date()
        try serial.exclusive {
            let shell = GuestShell(serial: serial)
            try files.carry(local, to: GuestFiles.quote(remote), shell: shell,
                            progress: { _, _ in }, note: { print("   отправка — \($0)") })
        }
        let up = Date().timeIntervalSince(t0)
        print(String(format: "В ГОСТЯ: %d Б за %.1f с — %.2f МБ/с", size, up, Double(size)/up/1048576))

        t0 = Date()
        let back = try files.receive(remote, progress: { _, _ in })
        let down = Date().timeIntervalSince(t0)
        print(String(format: "ИЗ ГОСТЯ: за %.1f с — %.2f МБ/с", down, Double(size)/down/1048576))
        print("сверка: наш \(want) / вернулось \(crc(back))")
        print(want == crc(back) ? "СОВПАЛО" : "РАЗОШЛОСЬ")
        try? FileManager.default.removeItem(at: back)
    }
} catch {
    print("НЕ ВЫШЛО: \(error.localizedDescription)"); exit(1)
}
