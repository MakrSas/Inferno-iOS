import Foundation

/// Prepares the app's Documents folder on first launch.
///
/// iOS hides an app's folder in the Files app while its Documents directory is
/// empty, even with UIFileSharingEnabled set. Creating the directory tree (and
/// leaving a note in it) makes the folder appear, and gives the guest images an
/// obvious place to land.
enum Bootstrap {
    static func prepareDocuments() {
        let fm = FileManager.default
        let documents = VMConfig.documents

        let directories = [
            "InfernoData",
            "InfernoData/Restore",
            "InfernoData/Restore/Firmware",
            "InfernoData/Restore/Firmware/all_flash",
        ]
        for relative in directories {
            let url = documents.appendingPathComponent(relative)
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }

        let readme = documents.appendingPathComponent(L("КУДА КЛАСТЬ ФАЙЛЫ.txt"))
        if !fm.fileExists(atPath: readme.path) {
            try? note.data(using: .utf8)?.write(to: readme)
        }
    }

    private static let note = """
    Inferno — файлы гостевой системы
    ================================

    Разложите содержимое комплекта прямо в эту папку:

      AppleSEPROM-Cebu-B1
      InfernoData/root.qcow2        (или root — сырой образ)
      InfernoData/firmware
      InfernoData/syscfg
      InfernoData/ctrl_bits
      InfernoData/nvram
      InfernoData/effaceable
      InfernoData/panic_log
      InfernoData/sep_nvram
      InfernoData/sep_ssc
      InfernoData/root_ticket.der
      InfernoData/sep-firmware.n104.RELEASE.new.img4
      InfernoData/Restore/kernelcache.release.iphone12b
      InfernoData/Restore/Firmware/038-44135-124.dmg.trustcache
      InfernoData/Restore/Firmware/all_flash/DeviceTree.n104ap.im4p

    Пустые папки уже созданы — файлы можно класть прямо в них.

    Про образ диска: берите root.qcow2, а не сырой root. Сырой занимает 34 ГБ
    номинально при ~9 ГБ данных и держится на разрежённости файла, которую
    копирование на телефон теряет. qcow2 занимает свои реальные гигабайты при
    любом способе переноса.

    JIT включайте через StikDebug ДО запуска машины. Без него транслятор не
    сможет сделать буфер трансляций исполняемым, и эмулятор не стартует.

    Этот файл можно удалить.
    """
}
