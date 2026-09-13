import Foundation
import Darwin

/// Reports what every thread in the process is doing.
///
/// When the emulator stops responding there are two very different causes —
/// vCPUs burning CPU with a stuck main loop, or nothing running at all — and
/// from the outside they look identical. Per-thread CPU time tells them apart.
enum Threads {
    struct Snapshot {
        var total: Int
        var running: Int
        var cpuSeconds: Double
    }

    static func snapshot() -> Snapshot {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
            return Snapshot(total: 0, running: 0, cpuSeconds: 0)
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
        }

        var running = 0
        var seconds = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            // THREAD_BASIC_INFO_COUNT is a macro the Swift importer drops.
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            guard rc == KERN_SUCCESS else { continue }
            if info.run_state == TH_STATE_RUNNING { running += 1 }
            seconds += Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            seconds += Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        }
        return Snapshot(total: Int(count), running: running, cpuSeconds: seconds)
    }

    /// Two samples a few seconds apart: the difference is what matters.
    static func report(over interval: TimeInterval = 3, _ completion: @escaping (String) -> Void) {
        Thread.detachNewThread {
            let first = snapshot()
            Thread.sleep(forTimeInterval: interval)
            let second = snapshot()

            let burned = second.cpuSeconds - first.cpuSeconds
            let cores = burned / interval
            let console = consoleSize()

            let verdict: String
            if cores < 0.05 {
                verdict = L("процессор простаивает — гость не исполняется")
            } else {
                verdict = String(format: L("загружено ~%.1f ядра — гость исполняется"), cores)
            }

            completion("""
            Потоки: \(second.total), из них выполняются \(second.running)
              за \(Int(interval)) с сожжено \(String(format: "%.2f", burned)) с процессорного времени
              \(verdict)
              guest-console.log: \(console)
            """)
        }
    }

    private static func consoleSize() -> String {
        let path = VMConfig.guestConsoleLog.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int
        else { return L("файла нет") }
        return L("%d байт", size)
    }
}
