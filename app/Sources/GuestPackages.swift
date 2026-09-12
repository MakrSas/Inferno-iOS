import Foundation

/// Puts the guest's package manager back on its feet.
///
/// Cydia and apt fail on every operation with `Sub-process
/// /usr/libexec/cydia/cydo returned an error code (2)`, and the package being
/// installed has nothing to do with it — a plain refresh fails the same way.
/// Three things are wrong at once on a restored image, and each is quiet on its
/// own:
///
/// - the bootstrap keeps its database in `/Library/dpkg`, while dpkg and apt
///   look for `/var/lib/dpkg`; `/var` is a separate data volume the bootstrap
///   never unpacked into, so that path does not exist at all;
/// - the root volume is mounted read-only, and packages write to `/usr` and
///   `/Library`, so a symlink alone changes nothing;
/// - the bootstrap's own packages were unpacked from an archive and never
///   configured — a jailbreak does that on its first boot, and this image had
///   no first boot.
///
/// The remount is the one part that does not survive a guest reboot, which is
/// why this is written to be run again as often as needed: every step is
/// idempotent.
///
/// And dpkg's state was only half of it. Cydia is a user app: it asks for root
/// through `/usr/libexec/cydia/cydo`, a setuid helper. Nothing in this guest is
/// setuid — every volume is mounted `nosuid`, the root included once it is
/// remounted writable — and `/usr/lib/libjailbreak.dylib`, which is how a real
/// jailbreak hands out root instead, is not in this image. So cydo ran dpkg as
/// `mobile`, dpkg said `requested operation requires superuser privilege` and
/// exited 2 — the very code Cydia showed. Measured in the guest: the same
/// command is 0 as root and 2 as mobile.
///
/// What stands in for the missing library is a small root-side script that
/// launchd starts when a request appears in a queue directory, and a
/// replacement for cydo that puts the arguments there and plays back what came
/// out. The original is kept as `cydo.real`.
///
/// Everything here blocks; run it off the main thread.
enum GuestPackages {
    enum Failure: LocalizedError {
        case noShell
        case step(String, Int64)
        case silent(String)
        case stillReadOnly

        var errorDescription: String? {
            switch self {
            case .noShell:
                return L("Гость не отвечает на консоли — дождитесь загрузки и повторите.")
            case .step(let what, let code):
                return L("Шаг «%@» в госте вернул %d.", what, Int(code))
            case .silent(let what):
                return L("Шаг «%@» не ответил вовремя.", what)
            case .stillReadOnly:
                return L("Корень гостя остался только для чтения — пакеты писать некуда.")
            }
        }
    }

    /// Where the guest keeps what the long steps printed, so a failure can be
    /// read here instead of being guessed at from an exit status. Cydia shows
    /// only `cydo returned an error code (2)`, and that 2 is dpkg's own — cydo
    /// answers a refusal with 77 — so dpkg's words are the thing worth having.
    private static let log = "/var/mobile/.inferno/packages.log"

    private struct Step {
        let title: String
        let command: String
        let timeout: TimeInterval
        /// Whether a non-zero status stops everything. The two long steps at the
        /// end report rather than stop: on an image that is already half fixed
        /// they can grumble and still leave dpkg usable, and the check at the
        /// end is what actually decides.
        let fatal: Bool
    }

    private static let queue = "/var/tmp/inferno-cydo"

    /// Runs dpkg as root for whoever asks. Started by launchd, so it is root
    /// without needing to become it.
    private static let rootScript = [
        "#!/bin/bash",
        "# Runs dpkg as root on behalf of Cydia. Installed by Inferno, because",
        "# nothing in this guest is setuid and cydo cannot elevate itself.",
        "set -u",
        "queue=\(queue)",
        "for req in \"$queue\"/*.req; do",
        "    [ -e \"$req\" ] || continue",
        "    id=\"${req%.req}\"",
        "    mapfile -t args < \"$req\"",
        "    rm -f \"$req\"",
        "    /usr/bin/dpkg \"${args[@]}\" > \"$id.out\" 2>&1",
        "    echo $? > \"$id.rc\"",
        "done",
    ]

    /// Takes cydo's place: same arguments, same output, same exit status, only
    /// the work happens on the other side of the queue.
    private static let clientScript = [
        "#!/bin/bash",
        "# Stands in for Cydia's setuid helper. The real one is cydo.real.",
        "set -u",
        "queue=\(queue)",
        "mkdir -p \"$queue\" 2>/dev/null",
        "id=\"$queue/$$-$RANDOM\"",
        "printf %s\\\\n \"$@\" > \"$id.tmp\"",
        "touch \"$id.out\"",
        "mv \"$id.tmp\" \"$id.req\"",
        "tail -n +1 -f \"$id.out\" 2>/dev/null &",
        "tail_pid=$!",
        "for _ in $(seq 1 3600); do",
        "    [ -e \"$id.rc\" ] && break",
        "    sleep 1",
        "done",
        "sleep 1",
        "kill \"$tail_pid\" 2>/dev/null",
        "rc=$(cat \"$id.rc\" 2>/dev/null || echo 2)",
        "rm -f \"$id.out\" \"$id.rc\"",
        "exit \"$rc\"",
    ]

    private static let plist = [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
        "<plist version=\"1.0\">",
        "<dict>",
        "  <key>Label</key><string>com.inferno.cydo</string>",
        "  <key>ProgramArguments</key>",
        "  <array>",
        "    <string>/bin/bash</string>",
        "    <string>/usr/libexec/cydia/cydo-root.sh</string>",
        "  </array>",
        "  <key>QueueDirectories</key>",
        "  <array><string>\(queue)</string></array>",
        "  <key>RunAtLoad</key><false/>",
        "  <key>KeepAlive</key><false/>",
        "</dict>",
        "</plist>",
    ]

    /// Writes a file in the guest a line at a time. One line per command on
    /// purpose: the console drops bytes inside long lines, and a here-document
    /// would leave our own text sitting in the terminal while the guest is
    /// busy — which is exactly how transfers used to break.
    private static func write(_ lines: [String], to path: String, shell: GuestShell) throws {
        guard shell.line("rm -f \(path)", timeout: 60) == 0 else { throw Failure.step(path, -1) }
        for line in lines {
            let quoted = line.replacingOccurrences(of: "'", with: "'\\''")
            guard shell.line("printf '%s\\n' '\(quoted)' >> \(path)", timeout: 60) == 0 else {
                throw Failure.step(path, -1)
            }
        }
    }

    private static var steps: [Step] {
        [
            Step(title: L("Перемонтирую корень на запись"), command: "mount -uw /",
                 timeout: 60, fatal: true),
            Step(title: L("Готовлю папки apt"),
                 command: "mkdir -p /var/lib /var/cache/apt/archives/partial /var/lib/apt/lists/partial",
                 timeout: 60, fatal: true),
            Step(title: L("Ставлю ссылку на базу dpkg"), command: "ln -sfn /Library/dpkg /var/lib/dpkg",
                 timeout: 60, fatal: true),
            // Slow ones. On a phone the guest runs several times slower than the
            // rig, where these take about twenty seconds and a minute.
            Step(title: L("Регистрирую прошивку"),
                 command: "/usr/libexec/cydia/firmware.sh >> \(log) 2>&1",
                 timeout: 900, fatal: false),
            Step(title: L("Настраиваю пакеты"), command: "dpkg --configure -a >> \(log) 2>&1",
                 timeout: 1200, fatal: false),
            Step(title: L("Проверяю базу"), command: "dpkg --audit >> \(log) 2>&1",
                 timeout: 600, fatal: false),
        ]
    }

    /// Runs the repair. `note` is called with the step that is about to run, and
    /// returns the lines worth showing when it is over.
    static func repair(serial: SerialConsole, note: @escaping (String) -> Void) throws -> [String] {
        var complaints: [String] = []

        try serial.exclusive {
            let shell = GuestShell(serial: serial)
            // Nothing is typed into a console that has no shell on it yet: the
            // commands would land in the boot log and look like they ran.
            guard shell.number("echo 1", timeout: 30) == 1 else { throw Failure.noShell }
            shell.line("mkdir -p /var/mobile/.inferno; : > \(log)", timeout: 60)

            for step in steps {
                note(step.title + "…")
                guard let code = shell.line(step.command, timeout: step.timeout) else {
                    if step.fatal { throw Failure.silent(step.title) }
                    complaints.append(L("«%@» не ответил вовремя.", step.title))
                    shell.reset()
                    continue
                }
                guard code == 0 else {
                    if step.fatal { throw Failure.step(step.title, code) }
                    complaints.append(L("«%@» вернул %d.", step.title, Int(code)))
                    continue
                }
            }

            // The stand-in for the setuid helper. Written every time: it is
            // cheap, and an image where Cydia was reinstalled has the original
            // back in place.
            note(L("Ставлю помощника для Cydia…"))
            try write(rootScript, to: "/usr/libexec/cydia/cydo-root.sh", shell: shell)
            try write(clientScript, to: "/tmp/cydo.new", shell: shell)
            try write(plist, to: "/tmp/com.inferno.cydo.plist", shell: shell)
            let install = [
                "chmod 755 /usr/libexec/cydia/cydo-root.sh",
                "test -e /usr/libexec/cydia/cydo.real || mv /usr/libexec/cydia/cydo /usr/libexec/cydia/cydo.real",
                "cp /tmp/cydo.new /usr/libexec/cydia/cydo",
                "chmod 755 /usr/libexec/cydia/cydo",
                "mkdir -p /Library/LaunchDaemons \(queue)",
                "chmod 777 \(queue)",
                "cp /tmp/com.inferno.cydo.plist /Library/LaunchDaemons/com.inferno.cydo.plist",
                // launchd refuses a job whose plist is not root's, and says so
                // only as `Path had bad ownership/permissions`.
                "chown root:wheel /Library/LaunchDaemons /Library/LaunchDaemons/com.inferno.cydo.plist",
                "chmod 755 /Library/LaunchDaemons",
                "chmod 644 /Library/LaunchDaemons/com.inferno.cydo.plist",
                "rm -f /tmp/cydo.new /tmp/com.inferno.cydo.plist",
            ].joined(separator: "; ")
            if shell.line(install, timeout: 120) != 0 { complaints.append(L("Помощника не удалось разложить.")) }
            // Already loaded is not a failure, and the exit status does not
            // tell the two apart — the check below does.
            shell.line("launchctl load -w /Library/LaunchDaemons/com.inferno.cydo.plist >/dev/null 2>&1",
                       timeout: 120)
            if shell.number("launchctl list 2>/dev/null | grep -c com.inferno.cydo") != 1 {
                complaints.append(L("launchd не подхватил помощника — Cydia останется без прав."))
            }

            note(L("Проверяю…"))
            // The one thing worth failing over: without a writable root the
            // whole repair is theatre.
            if shell.number("mount | grep -c ' on / .*read-only'") != 0 { throw Failure.stillReadOnly }
            if shell.number("test -e /var/lib/dpkg/status; echo $?") != 0 {
                complaints.append(L("База dpkg на месте не найдена — Cydia может всё ещё ругаться."))
            }
            // Whatever dpkg had to say, in one line: the console is no place for
            // paragraphs, and the last of it is the part that matters.
            if let said = shell.text("grep -v '^$' \(log) | tail -3 | tr '\\n' ' ' | cut -c1-240", timeout: 120),
               !said.isEmpty {
                complaints.append(L("dpkg сказал: %@", said))
            }
        }

        return complaints
    }
}
