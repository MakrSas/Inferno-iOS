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
/// `cydo` itself is a red herring. It is a setuid helper that checks its
/// caller's signature and answers everything but Cydia with `none shall pass`,
/// so its path cannot be reproduced from a shell. The `(2)` the user sees is
/// dpkg's exit status inside a call cydo did allow.
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
