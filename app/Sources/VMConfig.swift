import Foundation

/// Builds the emulator command line and reports what is missing.
///
/// The layout mirrors the desktop kit: an `InfernoData` directory plus the SEP
/// ROM, dropped into the app's Documents folder over the Files app.
struct VMConfig {
    var cores: Int = 4          // 3 CPU cores + the SEP core
    var memory: String = "3G"
    var vncPort: UInt16 = 5900
    var serialPort: UInt16 = 4555
    var qmpPort: UInt16 = 4556
    var tcgThreads: String = "multi"
    var tbSize: Int = 128
    /// Reverse tethering over the guest's own USB port: the emulator plays the
    /// USB host, brings up the device's CDC-NCM interface and NATs through
    /// slirp. No privileges, no companion VM.
    var network: Bool = true
    /// No screen at all: nothing to encode or copy. The guest is then reachable
    /// only through its console, which is what a headless run is for.
    var headless: Bool = false
    /// Read the framebuffer where it already is instead of going through a VNC
    /// server on the loopback. The VNC path stays available: it is the one that
    /// has years of use behind it, and it is worth being able to fall back to
    /// when something looks wrong.
    var builtInDisplay: Bool = true
    /// The guest's framebuffer in pixels, and how many of them make a point.
    /// The panel is 828×1792 at two, which is an iPhone 11; halving the
    /// framebuffer and dropping the scale to one keeps the same interface over
    /// a quarter of the pixels, and the app scales the picture back up so it
    /// covers the same area of the screen.
    /// Whether the machine is given a way to be heard. The emulated sound card
    /// exists either way; this decides whether anything is on the other end.
    var audio: Bool = false
    var displayWidth: Int = 828
    var displayHeight: Int = 1792
    var displayScale: Int = 2

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var dataDirectory: URL { documents.appendingPathComponent("InfernoData") }

    /// The scratch namespace both sides reach: the app writes bytes into this
    /// file, the guest reads the same place as a block device.
    static var transferImage: URL { dataDirectory.appendingPathComponent("xfer") }
    /// Sixteen mebibytes, and sparse, so it costs nothing until it is used. A
    /// gibibyte is not required: that floor applies only to a namespace with
    /// nstype=1, which is the root disk.
    static let transferBytes: Int64 = 16 * 1024 * 1024

    /// Creates the scratch namespace if it is not there yet.
    static func ensureTransferImage() {
        let path = transferImage.path
        guard !FileManager.default.fileExists(atPath: path) else { return }
        guard FileManager.default.createFile(atPath: path, contents: nil) else { return }
        // Truncated rather than written: the file reads as zeroes and occupies
        // only the blocks that are actually used.
        if let handle = try? FileHandle(forWritingTo: transferImage) {
            try? handle.truncate(atOffset: UInt64(transferBytes))
            try? handle.close()
        }
    }
    /// Where the emulator must chdir to before the sockets below resolve.
    static var socketDirectory: String { NSTemporaryDirectory() }
    static let usbSocketName = "inferno-usb.sock"
    /// Everything the guest prints, from the first byte, kept on disk.
    static var guestConsoleLog: URL { documents.appendingPathComponent("guest-console.log") }
    static var sepROM: URL { documents.appendingPathComponent("AppleSEPROM-Cebu-B1") }

    /// The device image, either as the raw file from the desktop kit or as a
    /// qcow2 conversion of it. qcow2 is preferred for transfers: the raw file is
    /// 34 GB of mostly holes, and most ways of copying it onto a phone fill them in.
    static var rootImage: (path: String, format: String)? {
        let qcow = dataDirectory.appendingPathComponent("root.qcow2")
        if FileManager.default.fileExists(atPath: qcow.path) {
            return (qcow.path, "qcow2")
        }
        let raw = dataDirectory.appendingPathComponent("root")
        if FileManager.default.fileExists(atPath: raw.path) {
            return (raw.path, "raw")
        }
        return nil
    }

    /// Everything the machine needs on disk, in the order a person should fix it.
    static let requiredFiles: [(label: String, relativePath: String)] = [
        (L("Прошивка NVMe"), "InfernoData/firmware"),
        ("syscfg", "InfernoData/syscfg"),
        ("ctrl_bits", "InfernoData/ctrl_bits"),
        ("nvram", "InfernoData/nvram"),
        ("effaceable", "InfernoData/effaceable"),
        ("panic_log", "InfernoData/panic_log"),
        ("SEP nvram", "InfernoData/sep_nvram"),
        ("SEP ssc", "InfernoData/sep_ssc"),
        (L("Тикет"), "InfernoData/root_ticket.der"),
        (L("Прошивка SEP"), "InfernoData/sep-firmware.n104.RELEASE.new.img4"),
        ("Kernelcache", "InfernoData/Restore/kernelcache.release.iphone12b"),
        ("Device tree", "InfernoData/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p"),
        ("TrustCache", "InfernoData/Restore/Firmware/038-44135-124.dmg.trustcache"),
        ("SEP ROM", "AppleSEPROM-Cebu-B1"),
    ]

    static func missingFiles() -> [String] {
        var missing = requiredFiles.compactMap { entry -> String? in
            let url = documents.appendingPathComponent(entry.relativePath).resolvingSymlinksInPath()
            return usable(url) ? nil : entry.label
        }
        if rootImage == nil {
            missing.insert(L("Диск устройства (root.qcow2 или root)"), at: 0)
        }
        return missing
    }

    /// Whether a file the emulator needs is actually a file.
    ///
    /// Asking `fileExists` is not enough, and the difference is not academic:
    /// an unpacked archive can leave a *folder* named `firmware`, the check
    /// passes, Start is enabled, and then QEMU says `'file' driver requires
    /// '…/firmware' to be a regular file` and calls `exit(1)` — from inside
    /// `qemu_init`, which runs in our own process, so the whole app goes down
    /// and it looks like a crash. An empty file does the same. Reported as
    /// issue #5.
    private static func usable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
              !directory.boolValue
        else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
        return (size ?? 0) > 0
    }

    func arguments() -> [String] {
        let data = VMConfig.dataDirectory.path
        let sep = VMConfig.sepROM.path
        // A relative name on purpose: AF_UNIX stores the path itself, and the
        // 104-byte sun_path limit cannot hold an app container path. The
        // emulator runs with its working directory set to the socket's folder,
        // so both ends resolve this to the same file.
        let usbSocket = VMConfig.usbSocketName

        let machine = [
            "t8030",
            "usb-conn-type=unix",
            "usb-conn-addr=\(usbSocket)",
            "trustcache=\(data)/Restore/Firmware/038-44135-124.dmg.trustcache",
            "ticket=\(data)/root_ticket.der",
            "sep-fw=\(data)/sep-firmware.n104.RELEASE.new.img4",
            "sep-rom=\(sep)",
            "kaslr-off=true",
            // The machine boots whatever NVRAM says, and NVRAM can say
            // `auto-boot=false` — left there by a restore that did not finish.
            // Then it heads for recovery, wants a ramdisk nobody passed, and
            // the emulator quits with `RAM Disk required for recovery` before
            // the guest exists. This app only ever runs an installed system, so
            // it asks for the way out of recovery every time: on a machine that
            // was fine this changes nothing.
            "boot-mode=exit_recovery",
            "disp-width=\(displayWidth)",
            "disp-height=\(displayHeight)",
            "disp-scale=\(displayScale)",
        ].joined(separator: ",")

        // QEMU looks for its data files (VNC keymaps among them) next to the
        // binary; inside an app bundle it has to be told where they are, or it
        // reports "could not read keymap file" and exits.
        let dataDir = Bundle.main.bundlePath + "/qemu-data"

        var argv = [
            "qemu-system-aarch64",
            "-L", dataDir,
            // Multi-threaded TCG: the only acceleration available here, since
            // iOS gives no hypervisor access to applications.
            // split-wx maps the translation buffer twice — writable and
            // executable — which is what a debugger-enabled process is allowed
            // to do when MAP_JIT is refused.
            "-accel", "tcg,thread=\(tcgThreads),tb-size=\(tbSize)"
                + (JIT.needsSplitWX ? ",split-wx=on" : ""),
            "-M", machine,
            "-kernel", "\(data)/Restore/kernelcache.release.iphone12b",
            "-dtb", "\(data)/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p",
            "-append", "tlto_us=-1 mtxspin=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=3 wdt=-1 launchd_unsecure_cache=1 -vm_compressor_wk_sw",
            "-smp", String(cores),
            "-m", memory,
            // The console is logged to a file rather than only streamed: a
            // socket drops everything printed before a client attaches, and the
            // guest starts talking long before the UI can connect.
            "-chardev", "socket,id=serial0,host=127.0.0.1,port=\(serialPort),server=on,wait=off,logfile=\(VMConfig.guestConsoleLog.path),logappend=off",
            "-serial", "chardev:serial0",
            // Lets the app ask the machine what state it is in.
            "-qmp", "tcp:127.0.0.1:\(qmpPort),server,nowait",
            "-drive", "file=\(data)/sep_nvram,if=pflash,format=raw",
            "-drive", "file=\(data)/sep_ssc,if=pflash,format=raw",
        ]

        if !audio {
            // Silence is asked for explicitly: with no audiodev named, the
            // machine's sound card takes the first output the build offers.
            // The global is written in its long form on purpose — the short
            // one splits the driver name at its first dot, and this driver is
            // called `apple.mca`, so `-global apple.mca.audiodev=quiet` looks
            // for a device called `apple` and is quietly dropped.
            argv += ["-audiodev", "none,id=quiet",
                     "-global", "driver=apple.mca,property=audiodev,value=quiet"]
        }

        if headless || builtInDisplay {
            // Nothing for the emulator to serve: either there is no screen at
            // all, or the app reads the framebuffer directly once the machine
            // is up.
            argv += ["-display", "none"]
        }
        else {
            argv += ["-vnc", "127.0.0.1:\(vncPort - 5900)"]
        }

        if let root = VMConfig.rootImage {
            argv += ["-drive", "file=\(root.path),format=\(root.format),if=none,id=root"]
            argv += ["-device", "nvme-ns,drive=root,bus=nvme-bus.0,nsid=1,nstype=1,logical_block_size=4096,physical_block_size=4096"]
        }

        // The remaining NVMe namespaces the machine expects, in order.
        let namespaces: [(file: String, nsid: Int, nstype: Int)] = [
            ("firmware", 2, 2),
            ("syscfg", 3, 3),
            ("ctrl_bits", 4, 4),
            ("effaceable", 6, 6),
            ("panic_log", 7, 8),
        ]
        for ns in namespaces {
            argv += ["-drive", "file=\(data)/\(ns.file),format=raw,if=none,id=\(ns.file)"]
            argv += ["-device", "nvme-ns,drive=\(ns.file),bus=nvme-bus.0,nsid=\(ns.nsid),nstype=\(ns.nstype),logical_block_size=4096,physical_block_size=4096"]
        }

        // A scratch namespace that both sides can reach: the app writes bytes
        // into the file, the guest reads them straight off the block device, and
        // nothing travels through the console or the network on the way. It is
        // attached only when the file exists, because the guest only learns of a
        // namespace if the emulator describes it in the device tree — an
        // emulator without that patch would simply ignore this one.
        //
        // cache=none is not a tuning knob here. Without it the emulator answers
        // out of the host's page cache and the guest reads what the file used to
        // hold, which looks exactly like a corrupt transfer.
        let transfer = VMConfig.dataDirectory.appendingPathComponent("xfer")
        if FileManager.default.fileExists(atPath: transfer.path) {
            argv += ["-drive", "file=\(transfer.path),format=raw,if=none,id=xfer,cache=none"]
            argv += ["-device", "nvme-ns,drive=xfer,bus=nvme-bus.0,nsid=8,nstype=2,logical_block_size=4096,physical_block_size=4096"]
        }

        if network {
            // The device listens on the same socket the machine's USB port
            // dials into, so it must be named identically.
            argv += ["-netdev", "user,id=net0"]
            argv += ["-device", "apple-ncm-host,netdev=net0,conn-addr=\(usbSocket)"]
        }

        // nvram is its own device type, not a plain namespace.
        argv += ["-drive", "file=\(data)/nvram,if=none,format=raw,id=nvram"]
        argv += ["-device", "apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram,logical_block_size=4096,physical_block_size=4096"]

        return argv
    }
}
