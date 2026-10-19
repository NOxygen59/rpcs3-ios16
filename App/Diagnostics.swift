// Diagnostics: what is needed to understand a problem, without the noise. RPCS3 logs tens of
// thousands of lines; only the important ones (errors, warnings, and notices about JIT,
// compilation, caches, boot, memory) are kept, written to Documents/Diagnostics as they come so
// they survive a crash or a freeze. A report adds the device, the system's grants, the settings
// that differ from the defaults and the previous session's end.

import Foundation
import UIKit

enum Diagnostics {
    /// Fichiers › Sur mon iPad › RPCS3 › Diagnostics.
    static var folder: URL { Storage.documents.appendingPathComponent("Diagnostics", isDirectory: true) }
    private static var logURL: URL { folder.appendingPathComponent("journal-important.log") }
    private static var previousLogURL: URL { folder.appendingPathComponent("journal-important.précédent.log") }
    private static var runningMarker: URL { folder.appendingPathComponent(".session-en-cours") }

    private static let queue = DispatchQueue(label: "rpcs3.diagnostics", qos: .utility)
    private static var handle: FileHandle?
    private static var pending = Data()
    private static var flushScheduled = false
    /// Whether the previous session ended without going through `appWillEnd` (crash, freeze
    /// killed by iOS, or the app removed from the switcher while a game ran).
    private(set) static var previousSessionEndedAbnormally = false

    // MARK: Session

    /// At launch: rotates the previous log, notes whether that session ended normally, and
    /// starts a new log with what describes this run.
    static func start() {
        queue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            previousSessionEndedAbnormally = fm.fileExists(atPath: runningMarker.path)
            if fm.fileExists(atPath: logURL.path) {
                try? fm.removeItem(at: previousLogURL)
                try? fm.moveItem(at: logURL, to: previousLogURL)
            }
            fm.createFile(atPath: logURL.path, contents: nil)
            fm.createFile(atPath: runningMarker.path, contents: nil)
            handle = try? FileHandle(forWritingTo: logURL)
        }
        write("=== Session \(timestamp()) ===")
        write(systemSummary(core: false).joined(separator: "\n"))
        if previousSessionEndedAbnormally {
            write("!!! La session précédente ne s'est pas terminée normalement (plantage, blocage ou fermeture forcée).")
        }
    }

    /// The app is going away normally (sent to the background, which iOS may turn into a quit).
    static func appWillEnd() {
        queue.async {
            flushNow()
            try? FileManager.default.removeItem(at: runningMarker)
        }
    }

    /// Back in the foreground: the session is running again.
    static func appDidResume() {
        queue.async { FileManager.default.createFile(atPath: runningMarker.path, contents: nil) }
    }

    // MARK: Lines

    /// From the core's log callback (any thread). Keeps only what matters.
    static func core(level: Int32, _ text: String) {
        guard isImportant(level: level, text) else { return }
        write("[\(levelName(level))] \(text)")
    }

    /// Something the app itself did (session started, stall detected, setting changed…).
    static func event(_ text: String) {
        write("[app] \(text)")
    }

    /// RPCS3 levels: 0 always, 1 fatal, 2 error, 3 todo, 4 success, 5 warning, 6 notice, 7 trace.
    private static func isImportant(level: Int32, _ text: String) -> Bool {
        // Guest syscall traces ("PPU[0x…] Thread (…) [0x…]: sys_…") and the periodic usage
        // tables are warnings by thousands a minute: noise, unless they failed (errors stay).
        if level >= 3, text.hasPrefix("PPU["), text.contains("]: sys_") || text.contains("]: _sys_") || text.contains("]: cell") { return false }
        if text.contains("PPU Syscall Usage Stats") { return false }
        // The module loader's per-symbol export / import / relocation traces ("**** …").
        if level >= 4, text.contains("**** ") { return false }
        if level <= 5 { return true }
        if level == 6 {
            let lower = text.lowercased()
            return keywords.contains { lower.contains($0) }
        }
        return false
    }

    private static let keywords = ["jit", "llvm", "spu", "ppu", "cache", "boot", "vsh", "firmware", "memory", "mémoire",
                                   "arena", "ios", "vulkan", "moltenvk", "metal", "savestate", "loaded", "module", "stop", "pause"]

    private static func levelName(_ level: Int32) -> String {
        switch level {
        case 0: return "!"
        case 1: return "FATAL"
        case 2: return "E"
        case 3: return "TODO"
        case 4: return "OK"
        case 5: return "W"
        case 6: return "N"
        default: return "T"
        }
    }

    private static func write(_ line: String) {
        let stamped = "\(timeOnly()) \(line)\n"
        queue.async {
            pending.append(Data(stamped.utf8))
            // Fatal lines go out at once: the app may not live to the next flush.
            if line.hasPrefix("[FATAL]") || pending.count > 64 * 1024 {
                flushNow()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + 1) { flushNow() }
            }
        }
    }

    private static func flushNow() {
        flushScheduled = false
        guard !pending.isEmpty, let handle else { return }
        handle.write(pending)
        pending.removeAll(keepingCapacity: true)
        // Keep the file bounded (~2 MB): past that, start over keeping the session header.
        if let size = try? handle.offset(), size > 2_000_000 {
            try? handle.truncate(atOffset: 0)
            handle.write(Data("\(timeOnly()) [app] Journal remis à zéro (trop long)\n".utf8))
        }
    }

    // MARK: Report

    /// Builds the report and saves it in Diagnostics (to share or to find in Files).
    static func makeReport(settings: [Setting], completion: @escaping (URL?) -> Void) {
        let changed = settings.filter { $0.value != $0.defaultValue }
        let pending = (UserDefaults.standard.dictionary(forKey: "rpcs3.restoreSettings") as? [String: String]) ?? [:]
        queue.async {
            flushNow()
            var text = "RAPPORT DE DIAGNOSTIC RPCS3 iOS 16 — \(timestamp())\n\n"
            text += "== Système ==\n" + systemSummary(core: true).joined(separator: "\n") + "\n"
            text += "Session précédente : \(previousSessionEndedAbnormally ? "terminée ANORMALEMENT" : "terminée normalement")\n\n"
            text += "== Réglages différents des valeurs par défaut (\(changed.count)) ==\n"
            text += changed.isEmpty ? "(aucun)\n" : changed.map { "\($0.key) = \($0.value)  (défaut : \($0.defaultValue))" }.joined(separator: "\n") + "\n"
            if !pending.isEmpty {
                text += "Réglages temporaires en cours (à rétablir) : " + pending.map { "\($0.key) → \($0.value)" }.joined(separator: ", ") + "\n"
            }
            text += "\n== Cette session : lignes importantes ==\n"
            text += tail(of: logURL, lines: 600)
            if previousSessionEndedAbnormally {
                text += "\n== Session précédente (terminée anormalement) : fin du journal ==\n"
                text += tail(of: previousLogURL, lines: 300)
            }
            let url = folder.appendingPathComponent("rapport-\(fileStamp()).txt")
            let ok = (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
            DispatchQueue.main.async { completion(ok ? url : nil) }
        }
    }

    private static func tail(of url: URL, lines count: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "(vide)\n" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(count).joined(separator: "\n") + "\n"
    }

    // MARK: System

    /// `core`: whether the core is up (its version and the firmware can only be read then).
    static func systemSummary(core: Bool) -> [String] {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var lines = [
            "Appareil : \(model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "App : RPCS3 iOS 16 \(app)",
            "JIT : \(JIT.enabled ? "actif" : "inactif")\(UserDefaults.standard.bool(forKey: JIT.jitlessKey) ? " (sans JIT forcé)" : "")",
            "Mémoire accrue : \(SystemStatus.increasedMemoryLimit ? "oui" : "non"), adressage étendu : \(SystemStatus.extendedVirtualAddressing ? "oui" : "non")",
            "Mémoire disponible : \(Strings.bytes(SystemStatus.availableMemory)), physique : \(Strings.bytes(ProcessInfo.processInfo.physicalMemory))",
            "État thermique : \(ProcessInfo.processInfo.thermalState.rawValue), mode économie : \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "oui" : "non")",
        ]
        if core {
            lines.append("Cœur : ABI \(Core.abiVersion), \(Core.buildInfo)")
            lines.append("Firmware PS3 : \(Core.firmwareVersion.isEmpty ? "non installé" : Core.firmwareVersion)")
        }
        return lines
    }

    private static func timestamp() -> String { Date().formatted(date: .numeric, time: .standard) }
    private static func timeOnly() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}

/// The app's Documents folder, which is what Files shows as On My iPad › RPCS3 (iOS lists an
/// app there only once that folder exists).
enum Storage {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var games: URL { documents.appendingPathComponent("Jeux", isDirectory: true) }
    static var firmware: URL { documents.appendingPathComponent("Firmware", isDirectory: true) }

    static func prepare() {
        let fm = FileManager.default
        for dir in [documents, games, firmware, Diagnostics.folder] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let readme = documents.appendingPathComponent("Lisez-moi.txt")
        if !fm.fileExists(atPath: readme.path) {
            try? """
            RPCS3 — dossier visible dans Fichiers › Sur mon iPad › RPCS3

            Firmware : déposez PS3UPDAT.PUP dans « Firmware ».
            Jeux : déposez vos .pkg (avec leurs .rap), .iso (avec leur .dkey), .zip ou dossiers de jeu dans « Jeux ».
            Puis, dans RPCS3 : Jeu › Fichiers dans RPCS3, et installez.

            Diagnostics : journal des lignes importantes et rapports à envoyer en cas de problème.
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// Installable items found in Jeux and Firmware (files by extension, game folders by their
    /// PARAM.SFO), with their size.
    static func installables() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in [firmware, games] {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for url in items {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    let sfo = ["PARAM.SFO", "PS3_GAME/PARAM.SFO"].contains { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
                    if sfo { out.append(url) }
                } else if ["pup", "pkg", "rap", "iso", "zip", "dkey", "key"].contains(url.pathExtension.lowercased()) {
                    out.append(url)
                }
            }
        }
        return out.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
