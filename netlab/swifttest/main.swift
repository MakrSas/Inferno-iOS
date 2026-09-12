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
    } else if mode == "pull" {
        let remote = CommandLine.arguments[2]
        let local = URL(fileURLWithPath: CommandLine.arguments[3])
        print("== забираю \(remote)")
        let started = Date()
        let got = try files.receive(remote, progress: { done, total in
            if total > 0 { print("   \(done * 100 / total)%") }
        })
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: got, to: local)
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int) ?? 0
        print("== \(size ?? 0) Б за \(String(format: "%.1f", Date().timeIntervalSince(started))) с")
    } else if mode == "packages" {
        print("== чиню менеджер пакетов")
        let complaints = try GuestPackages.repair(serial: serial, note: { print("   \($0)") })
        print(complaints.isEmpty ? "== готово, замечаний нет" : "== готово: " + complaints.joined(separator: "; "))
    } else if mode == "send" {
        // Тот самый путь, которым идёт «Отправить файл в гостя…» на телефоне:
        // через openDestination, то есть через поиск папки «Файлов» в госте.
        // Режим `files` его обходит — зовёт carry напрямую, — а ломалось
        // именно здесь.
        let megabytes = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 2 : 2
        let size = megabytes * 1024 * 1024
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("send-test.bin")
        let random = FileHandle(forReadingAtPath: "/dev/urandom")!
        try (random.read(upToCount: size) ?? Data()).write(to: local)
        try? random.close()

        let t0 = Date()
        let target = try files.send(local, progress: { _, _ in })
        let took = Date().timeIntervalSince(t0)
        print(String(format: "ОТПРАВЛЕНО: %@ — %d Б за %.1f с", target, size, took))
    } else {
        // Туда и обратно, со сверкой. Размер задаётся в мегабайтах: больше
        // окна носителя — значит передача пойдёт несколькими окнами, а это
        // отдельный путь в коде.
        let megabytes = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 5 : 5
        let size = megabytes * 1024 * 1024
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("xfer-test.bin")
        // Из /dev/urandom, а не поэлементно: на десятках мегабайт map по
        // одному байту мерил бы скорость Swift, а не канала.
        let random = FileHandle(forReadingAtPath: "/dev/urandom")!
        try (random.read(upToCount: size) ?? Data()).write(to: local)
        try? random.close()
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
