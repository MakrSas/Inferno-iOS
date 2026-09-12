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

    /// Runs dpkg as root for whoever asks.
    ///
    /// A plain background process rather than a launchd job: launchd on this
    /// image takes its daemons from a cache (`launchd_unsecure_cache=1`), so a
    /// plist dropped into /Library/LaunchDaemons lasts only until the guest
    /// reboots — and a helper that is quietly gone is worse than none, because
    /// Cydia then waits on it until the watchdog kills Cydia.
    private static let rootScript = [
        "#!/bin/bash",
        "# Runs dpkg as root on behalf of Cydia. Started by Inferno, because",
        "# nothing in this guest is setuid and cydo cannot elevate itself.",
        "set -u",
        "queue=\(queue)",
        "mkdir -p \"$queue\"",
        "chmod 777 \"$queue\"",
        "echo $$ > \"$queue/pid\"",
        "trap \"rm -f $queue/pid\" EXIT",
        "while true; do",
        "    for req in \"$queue\"/*.req; do",
        "        [ -e \"$req\" ] || continue",
        "        id=\"${req%.req}\"",
        "        mapfile -t args < \"$req\"",
        "        rm -f \"$req\"",
        "        printf %s\\\\n \"--- $id\" \"${args[@]}\" >> \"$queue/args.log\"",
        // apt hands dpkg an open file descriptor to report progress on. It
        // cannot cross into this process, and dpkg refuses to start without
        // the one it was told about, so those arguments are dropped: apt then
        // shows no progress bar and everything else works.
        "        keep=()",
        "        skip=0",
        "        for a in \"${args[@]}\"; do",
        "            if [ $skip = 1 ]; then skip=0; continue; fi",
        "            case \"$a\" in",
        "                --status-fd|--log-fd) skip=1; continue;;",
        "                --status-fd=*|--log-fd=*) continue;;",
        "            esac",
        "            keep+=(\"$a\")",
        "        done",
        // cydo is not only dpkg. Cydia hands it a program to run as root —
        // /bin/rm, /bin/ln, /bin/cp, setnsfpn, firmware.sh — and passes bare
        // options only when it means dpkg itself. Running dpkg either way is
        // how `/bin/rm -f …` turned into `dpkg -f …` and answered `need an
        // action option`.
        "        case \"${keep[0]-}\" in",
        // firmware.sh takes tens of seconds here and Cydia blocks its main
        // thread on this call, which on a guest this slow is long enough for
        // iOS to kill Cydia as unresponsive. The repair button runs it for
        // real; from here it is let go of and answered at once.
        "            */firmware.sh)",
        "                (nohup \"${keep[@]}\" >/dev/null 2>&1 &)",
        "                : > \"$id.out\"",
        "                ;;",
        "            /*) \"${keep[@]}\" > \"$id.out\" 2>&1;;",
        "            *)  /usr/bin/dpkg \"${keep[@]}\" > \"$id.out\" 2>&1;;",
        "        esac",
        "        echo $? > \"$id.rc\"",
        "    done",
        "    sleep 0.3",
        "done",
    ]

    /// Takes cydo's place: same arguments, same output, same exit status.
    ///
    /// Refuses at once when the helper is not running, and says why. Cydia
    /// blocks on this call, so waiting in silence ends with the watchdog
    /// killing Cydia — which is how the first version of this went wrong.
    private static let clientScript = [
        "#!/bin/bash",
        "# Stands in for Cydia's setuid helper. The real one is cydo.real.",
        "set -u",
        "queue=\(queue)",
        "pid=$(cat \"$queue/pid\" 2>/dev/null || echo 0)",
        // `ps`, not `kill -0`: the client runs as mobile and the helper is
        // root's, so a signal to it comes back as "not permitted" rather than
        // as "alive", and the client would refuse every time.
        "if ! ps -p \"$pid\" >/dev/null 2>&1; then",
        "    echo \"cydo: Inferno helper is not running - press Repair the package manager in the app\" >&2",
        "    exit 2",
        "fi",
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

    /// Installs a `.deb` in the guest, without Cydia in the way.
    ///
    /// Cydia blocks its own main thread while dpkg runs, and on a guest this
    /// slow that is long enough for iOS to kill it as unresponsive — which
    /// also kills the helper's client and leaves dpkg holding the database.
    /// Here nothing is waiting on a screen, so a package can take its minutes.
    ///
    /// `--force-overwrite` because the bootstrap and the packages it came from
    /// disagree about who owns a handful of files in /etc/apt; every install in
    /// this image trips over that and nothing else.
    static func installDeb(_ local: URL, serial: SerialConsole, files: GuestFiles,
                           progress: @escaping (Int64, Int64) -> Void,
                           note: @escaping (String) -> Void) throws -> String {
        let remote = "/var/mobile/.inferno/install.deb"

        return try serial.exclusive {
            let shell = GuestShell(serial: serial)
            guard shell.number("echo 1", timeout: 30) == 1 else { throw Failure.noShell }
            shell.line("mkdir -p /var/mobile/.inferno", timeout: 60)

            note(L("Переношу пакет в гостя…"))
            try files.carry(local, to: remote, shell: shell, progress: progress, note: note)

            note(L("Ставлю пакет…"))
            guard let code = shell.line("dpkg -i --force-overwrite \(remote) >> \(log) 2>&1",
                                        timeout: 1800)
            else { throw Failure.silent(L("Ставлю пакет")) }

            note(L("Настраиваю пакеты…"))
            shell.line("dpkg --configure -a >> \(log) 2>&1", timeout: 1800)

            // A package that brings an app leaves it on disk and nothing else:
            // SpringBoard learns about it from uicache, and without that the
            // install looks like it did nothing at all.
            note(L("Показываю приложения SpringBoard…"))
            shell.line("uicache --all >> \(log) 2>&1", timeout: 1800)
            shell.line("rm -f \(remote)", timeout: 60)

            let said = shell.text("grep -v '^$' \(log) | tail -3 | tr '\\n' ' ' | cut -c1-240", timeout: 120)
            if code != 0 { throw Failure.step(L("Ставлю пакет") + (said.map { ": " + $0 } ?? ""), code) }
            return said ?? ""
        }
    }

    /// Restarts SpringBoard.
    ///
    /// Tweaks are loaded into it when it starts, so one that was just installed
    /// does nothing until this happens. Cydia calls it a respring and asks
    /// first; here it is a menu entry for the same reason.
    static func respring(serial: SerialConsole) throws {
        try serial.exclusive {
            let shell = GuestShell(serial: serial)
            guard shell.number("echo 1", timeout: 30) == 1 else { throw Failure.noShell }
            shell.line("killall -9 SpringBoard", timeout: 120)
        }
    }

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

    /// What a guest loses on every reboot, and what therefore has to be done
    /// again each time the machine starts. Seconds, not minutes.
    private static var fastSteps: [Step] {
        [
            Step(title: L("Перемонтирую корень на запись"), command: "mount -uw /",
                 timeout: 60, fatal: true),
            Step(title: L("Готовлю папки apt"),
                 command: "mkdir -p /var/lib /var/cache/apt/archives/partial /var/lib/apt/lists/partial",
                 timeout: 60, fatal: true),
            Step(title: L("Ставлю ссылку на базу dpkg"), command: "ln -sfn /Library/dpkg /var/lib/dpkg",
                 timeout: 60, fatal: true),
        ]
    }

    /// Needed once per image and slow enough to be worth a button: on a phone
    /// these two are minutes, and they hold the console while they run.
    private static var slowSteps: [Step] {
        [
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
    /// Everything, including the slow steps. This is the button.
    static func repair(serial: SerialConsole, note: @escaping (String) -> Void) throws -> [String] {
        try run(serial: serial, steps: fastSteps + slowSteps, note: note)
    }

    /// Only what the reboot undid: the remount, the folders, the helper. Run at
    /// every start, quietly, because without it Cydia is broken again and the
    /// error it gives says nothing about why.
    static func prepare(serial: SerialConsole) throws -> [String] {
        try run(serial: serial, steps: fastSteps, note: { _ in })
    }

    private static func run(serial: SerialConsole, steps: [Step],
                            note: @escaping (String) -> Void) throws -> [String] {
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
            let install = [
                "chmod 755 /usr/libexec/cydia/cydo-root.sh",
                "test -e /usr/libexec/cydia/cydo.real || mv /usr/libexec/cydia/cydo /usr/libexec/cydia/cydo.real",
                "cp /tmp/cydo.new /usr/libexec/cydia/cydo",
                "chmod 755 /usr/libexec/cydia/cydo",
                "rm -f /tmp/cydo.new",
                // An earlier version of this shipped a launchd job. It does not
                // survive a reboot on this image, so it is taken back out.
                "launchctl unload /Library/LaunchDaemons/com.inferno.cydo.plist >/dev/null 2>&1",
                "rm -f /Library/LaunchDaemons/com.inferno.cydo.plist",
                // Requests left behind while no helper was running: nobody is
                // waiting on them any more.
                "mkdir -p \(queue)",
                "chmod 777 \(queue)",
                "rm -f \(queue)/*.req \(queue)/*.out \(queue)/*.rc \(queue)/*.tmp",
                "pkill -f cydo-root.sh",
                // In a subshell, and nothing after it on the line: a bare `&`
                // with the marker appended behind it is a syntax error, and
                // bash then runs none of this at all.
                "(nohup /bin/bash /usr/libexec/cydia/cydo-root.sh >/dev/null 2>&1 &)",
            ].joined(separator: "; ")
            if shell.line(install, timeout: 180) != 0 { complaints.append(L("Помощника не удалось разложить.")) }
            // It writes its pid as its first act, so a short wait tells a
            // running helper from one that fell over on startup.
            if shell.number("sleep 2; test -e \(queue)/pid; echo $?") != 0 {
                complaints.append(L("Помощник не запустился — Cydia останется без прав."))
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
