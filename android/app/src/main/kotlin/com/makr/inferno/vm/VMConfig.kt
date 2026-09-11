package com.makr.inferno.vm

import android.content.Context
import android.os.ParcelFileDescriptor
import java.io.File

/**
 * Builds the emulator command line and reports what is missing.
 *
 * The machine itself — t8030, the same NVMe namespaces, the same SEP
 * pflash pair — doesn't change with the host platform; only how the
 * library is loaded (JNI here, dlopen from Swift there) and how the
 * display is shown (always the built-in path here — see EmbeddedDisplay)
 * differ from VMConfig.swift.
 */
data class VMConfig(
    val cores: Int = 4, // 3 CPU cores + the SEP core
    val memory: String = "3G",
    val serialPort: Int = 4555,
    val qmpPort: Int = 4556,
    val tcgThreads: String = "multi",
    val tbSize: Int = 128,
    /** Reverse tethering over the guest's own USB port, same as iOS: the
     *  emulator plays the USB host and NATs through slirp. No companion VM,
     *  no privileges — `INTERNET` is the only permission it needs. */
    val network: Boolean = true,
    val headless: Boolean = false,
    /** The panel is 828×1792 at scale 2 — an iPhone 11, same as the guest
     *  expects on iOS. Nothing here lets it be anything else yet; see
     *  TODO.md upstream about why the guest doesn't tolerate other sizes. */
    val displayWidth: Int = 828,
    val displayHeight: Int = 1792,
    val displayScale: Int = 2,
) {
    companion object {
        private const val USB_SOCKET_NAME = "inferno-usb.sock"

        /**
         * `Android/data/<package>/files` — visible to any file manager,
         * survives an uninstall's scoped cleanup being the app's own, and
         * needs no storage permission on any supported API level. Exactly
         * the folder ANDROID-PORT.md points at ("Файлы").
         */
        fun guestFilesRoot(context: Context): File =
            context.getExternalFilesDir(null) ?: context.filesDir

        fun dataDirectory(context: Context): File = File(guestFilesRoot(context), "InfernoData")
        fun sepROM(context: Context): File = File(guestFilesRoot(context), "AppleSEPROM-Cebu-B1")
        fun guestConsoleLog(context: Context): File = File(guestFilesRoot(context), "guest-console.log")

        /**
         * AF_UNIX's `sun_path` is capped at 108 bytes on Linux. A path under
         * external app storage can run close to that on a device with a
         * long username; the process's own cache directory is short,
         * internal, and always local — so the USB socket lives there
         * instead. Same problem VMConfig.swift solves by using a bare file
         * name against a chdir'd working directory; this sidesteps it by
         * picking a directory that is already short.
         */
        fun socketDirectory(context: Context): File = context.cacheDir

        data class RequiredFile(val label: String, val relativePath: String)

        val requiredFiles = listOf(
            RequiredFile("Прошивка NVMe", "InfernoData/firmware"),
            RequiredFile("syscfg", "InfernoData/syscfg"),
            RequiredFile("ctrl_bits", "InfernoData/ctrl_bits"),
            RequiredFile("nvram", "InfernoData/nvram"),
            RequiredFile("effaceable", "InfernoData/effaceable"),
            RequiredFile("panic_log", "InfernoData/panic_log"),
            RequiredFile("SEP nvram", "InfernoData/sep_nvram"),
            RequiredFile("SEP ssc", "InfernoData/sep_ssc"),
            RequiredFile("Тикет", "InfernoData/root_ticket.der"),
            RequiredFile("Прошивка SEP", "InfernoData/sep-firmware.n104.RELEASE.new.img4"),
            RequiredFile("Kernelcache", "InfernoData/Restore/kernelcache.release.iphone12b"),
            RequiredFile("Device tree", "InfernoData/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p"),
            RequiredFile("TrustCache", "InfernoData/Restore/Firmware/038-44135-124.dmg.trustcache"),
            RequiredFile("SEP ROM", "AppleSEPROM-Cebu-B1"),
        )

        /** [fds], when non-empty, means [path] is a `/dev/fdset/N` alias
         *  rather than a real filesystem path, and [fds] are the raw
         *  descriptor numbers `arguments()` must register with `-add-fd`
         *  for that alias to resolve — see its comment for why the
         *  SAF-backed case needs this instead of a plain path, and why more
         *  than one fd is needed. */
        data class RootImage(val path: String, val format: String, val fds: List<Int> = emptyList())

        /** [image] is what goes on the `-drive file=...` line; [descriptors],
         *  when non-empty, are the open SAF handles backing a `/dev/fdset/N`
         *  alias in it and must be kept alive (not garbage-collected, not
         *  closed) until the machine has actually opened the file — see
         *  VMModel, which holds them for the machine's whole run to be safe. */
        data class ResolvedRoot(val image: RootImage, val descriptors: List<ParcelFileDescriptor>)

        /** The copied-in disk, if there is one. qcow2 preferred, same
         *  reasoning as iOS: the raw image is tens of gigabytes of mostly
         *  holes, and most ways of copying it onto a phone fill them in. */
        fun localRootImage(context: Context): RootImage? {
            val dir = dataDirectory(context)
            val qcow = File(dir, "root.qcow2")
            if (qcow.exists()) return RootImage(qcow.path, "qcow2")
            val raw = File(dir, "root")
            if (raw.exists()) return RootImage(raw.path, "raw")
            return null
        }

        fun hasRootImage(context: Context): Boolean =
            localRootImage(context) != null || GuestUriStore.rootDocument(context) != null

        /** Arbitrary but fixed — there is only ever one `-add-fd`-registered
         *  drive, so nothing else can collide with this set id. */
        private const val ROOT_FD_SET = 9

        /**
         * The disk itself is the one file SetupScreen doesn't copy (see its
         * own comment on why) — this is where that trade-off is paid back.
         * A local copy under `InfernoData/` wins if one exists (someone put
         * it there by hand, or a future version copies it after all);
         * failing that, it's opened straight out of the SAF tree the user
         * picked. That descriptor is only good for as long as it stays the
         * exact fd QEMU inherited across fork+exec — it must be handed to
         * QEMU via `-add-fd` + `/dev/fdset/N` (see `arguments()`), *not* by
         * building a `/proc/self/fd/N` path here: that trick only holds
         * within a single process. Once QEMU is a forked-and-exec'd child
         * rather than this same process calling in, re-opening that path is
         * a brand new `open(2)` against the real file, checked against this
         * app's own uid — which SAF granted the fd for precisely so this
         * app would never need direct filesystem permission on it. QEMU's
         * `-add-fd` exists for exactly this situation (a managing process
         * that can open a disk image the emulator itself may not be able
         * to): it hands over the already-open fd with no further `open()`
         * involved.
         *
         * One such fd is not enough, though: the block layer opens a fresh
         * fd from the set every time it needs one, matching by access mode
         * (see monitor_fdset_dup_fd_add in QEMU) — and it opens this drive
         * twice, first read-only while it still doesn't know whether
         * anything will need to write to it, then again read-write once
         * the attached nvme-ns device states its actual requirement. A set
         * holding only an O_RDWR fd has nothing to offer the read-only
         * request and fails outright, so both access modes are opened and
         * registered.
         */
        fun resolveRootImage(context: Context): ResolvedRoot? {
            localRootImage(context)?.let { return ResolvedRoot(it, emptyList()) }
            val doc = GuestUriStore.rootDocument(context) ?: return null
            val name = doc.name ?: return null
            val format = if (name.endsWith(".qcow2")) "qcow2" else "raw"
            val pfdRW = runCatching { context.contentResolver.openFileDescriptor(doc.uri, "rw") }
                .getOrNull() ?: return null
            val pfdRO = runCatching { context.contentResolver.openFileDescriptor(doc.uri, "r") }
                .getOrNull()
            val descriptors = listOfNotNull(pfdRW, pfdRO)
            val image = RootImage("/dev/fdset/$ROOT_FD_SET", format, descriptors.map { it.fd })
            return ResolvedRoot(image, descriptors)
        }

        fun missingFiles(context: Context): List<String> {
            val root = guestFilesRoot(context)
            val missing = requiredFiles
                .filterNot { File(root, it.relativePath).exists() }
                .map { it.label }
                .toMutableList()
            if (!hasRootImage(context)) {
                missing.add(0, "Диск устройства (root.qcow2 или root)")
            }
            return missing
        }
    }

    fun arguments(context: Context, libraryPath: String, root: RootImage?): List<String> {
        val data = dataDirectory(context).path
        val sep = sepROM(context).path
        val usbSocket = File(socketDirectory(context), USB_SOCKET_NAME).path

        val machine = listOf(
            "t8030",
            "usb-conn-type=unix",
            "usb-conn-addr=$usbSocket",
            "trustcache=$data/Restore/Firmware/038-44135-124.dmg.trustcache",
            "ticket=$data/root_ticket.der",
            "sep-fw=$data/sep-firmware.n104.RELEASE.new.img4",
            "sep-rom=$sep",
            "kaslr-off=true",
            "disp-width=$displayWidth",
            "disp-height=$displayHeight",
            "disp-scale=$displayScale",
        ).joinToString(",")

        // Sibling to the library itself, matching the iOS bundle's
        // qemu-data layout — where the Android build eventually drops the
        // library is where the keymaps go too.
        val dataDir = File(libraryPath).parentFile?.resolve("qemu-data")?.path ?: data

        val argv = mutableListOf(
            "qemu-system-aarch64",
            "-L", dataDir,
            // Multi-threaded TCG, same as iOS — Android has no privileged
            // hypervisor path for an app either (see the project's own
            // notes on why KVM isn't reachable from here) — but split-wx is
            // gone: nothing on Android enforces W^X against this process,
            // so the translation buffer is just ordinary RWX memory.
            "-accel", "tcg,thread=$tcgThreads,tb-size=$tbSize",
            "-M", machine,
            "-kernel", "$data/Restore/kernelcache.release.iphone12b",
            "-dtb", "$data/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p",
            "-append", "tlto_us=-1 mtxspin=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=3 wdt=-1 -vm_compressor_wk_sw",
            "-smp", cores.toString(),
            "-m", memory,
            "-chardev", "socket,id=serial0,host=127.0.0.1,port=$serialPort,server=on,wait=off," +
                "logfile=${guestConsoleLog(context).path},logappend=off",
            "-serial", "chardev:serial0",
            "-qmp", "tcp:127.0.0.1:$qmpPort,server,nowait",
            "-drive", "file=$data/sep_nvram,if=pflash,format=raw",
            "-drive", "file=$data/sep_ssc,if=pflash,format=raw",
            // Always "none": there is no VNC path on this platform at all —
            // the app reads the framebuffer directly once the machine is up
            // (see EmbeddedDisplay), or there is no screen at all.
            "-display", "none",
        )

        root?.let { image ->
            // A local copy has a plain path QEMU can open itself; a
            // SAF-backed disk instead comes as an already-open fd this
            // process obtained (and this process alone has permission
            // for) — `-add-fd` hands that fd to QEMU directly, so its own
            // `-drive file=/dev/fdset/N` never has to call `open()` on the
            // real path at all. See resolveRootImage() for why a
            // `/proc/self/fd/N` path — which works fine within a single
            // process — doesn't survive fork()+execve() into a plain
            // child process with only its own uid's permissions.
            for (fd in image.fds) {
                argv += listOf("-add-fd", "fd=$fd,set=$ROOT_FD_SET,opaque=root")
            }
            argv += listOf("-drive", "file=${image.path},format=${image.format},if=none,id=root")
            argv += listOf(
                "-device",
                "nvme-ns,drive=root,bus=nvme-bus.0,nsid=1,nstype=1,logical_block_size=4096,physical_block_size=4096",
            )
        }

        val namespaces = listOf(
            Triple("firmware", 2, 2),
            Triple("syscfg", 3, 3),
            Triple("ctrl_bits", 4, 4),
            Triple("effaceable", 6, 6),
            Triple("panic_log", 7, 8),
        )
        for ((file, nsid, nstype) in namespaces) {
            argv += listOf("-drive", "file=$data/$file,format=raw,if=none,id=$file")
            argv += listOf(
                "-device",
                "nvme-ns,drive=$file,bus=nvme-bus.0,nsid=$nsid,nstype=$nstype," +
                    "logical_block_size=4096,physical_block_size=4096",
            )
        }

        if (network) {
            argv += listOf("-netdev", "user,id=net0")
            argv += listOf("-device", "apple-ncm-host,netdev=net0,conn-addr=$usbSocket")
        }

        argv += listOf("-drive", "file=$data/nvram,if=none,format=raw,id=nvram")
        argv += listOf(
            "-device",
            "apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram," +
                "logical_block_size=4096,physical_block_size=4096",
        )

        return argv
    }
}
