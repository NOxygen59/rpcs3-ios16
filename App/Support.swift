// Small pieces the screens share: the core's log, JIT detection, French texts for the core's
// statuses, byte counts.

import Foundation
import UIKit

/// The core's log: the last lines in a ring buffer. RPCS3 logs a lot while a game runs, so lines
/// are only stored (cheap) unless the Journal screen is open, which then gets batched updates.
final class Log: ObservableObject {
    static let shared = Log()

    struct Line: Identifiable {
        let id: Int
        let level: Int32
        let text: String
    }

    private static let capacity = 4000
    private var ring: [Line] = []
    private var next = 0
    private let lock = NSLock()
    private var scheduled = false
    private var watchers = 0
    @Published private(set) var lines: [Line] = []

    /// Called from any thread (the core's).
    func append(level: Int32, _ text: String) {
        lock.lock()
        let line = Line(id: next, level: level, text: text)
        if ring.count < Self.capacity { ring.append(line) } else { ring[next % Self.capacity] = line }
        next += 1
        let publish = watchers > 0 && !scheduled
        if publish { scheduled = true }
        lock.unlock()
        guard publish else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock()
            scheduled = false
            lock.unlock()
            refresh()
        }
    }

    private func snapshot() -> [Line] {
        lock.lock()
        defer { lock.unlock() }
        guard ring.count == Self.capacity else { return ring }
        let start = next % Self.capacity
        return Array(ring[start...] + ring[..<start])
    }

    private func refresh() { lines = snapshot() }

    /// The Journal screen subscribes while it is on screen.
    func watch() {
        lock.lock(); watchers += 1; lock.unlock()
        refresh()
    }

    func unwatch() {
        lock.lock(); watchers = max(0, watchers - 1); lock.unlock()
        if watchers == 0 { lines = [] }
    }

    var text: String { snapshot().map(\.text).joined(separator: "\n") }
}

/// JIT on iOS 16: a debugger (TrollStore's "Open with JIT") marks the process CS_DEBUGGED, which
/// the core's legacy debugger backend checks. Without it the core runs JIT-less (interpreters).
enum JIT {
    static let jitlessKey = "rpcs3.jitless"

    static var enabled: Bool {
        var status: Int32 = 0
        // CS_OPS_STATUS = 0, CS_DEBUGGED = 0x10000000.
        guard csops(getpid(), 0, &status, MemoryLayout<Int32>.size) == 0 else { return false }
        return UInt32(bitPattern: status) & 0x1000_0000 != 0
    }

    /// TrollStore relaunches the app with a debugger attached (TrollStore 2.0.12+).
    static var trollStoreURL: URL? {
        URL(string: "apple-magnifier://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier ?? "")")
    }

    /// The core reads RPCS3_IOS_JITLESS once, before initialization.
    static func useJitless() { setenv("RPCS3_IOS_JITLESS", "1", 1) }
}

enum Strings {
    static func status(_ s: rpcs3_ios_status) -> String {
        switch s {
        case RPCS3_IOS_OK: return "OK"
        case RPCS3_IOS_INVALID_ARGUMENT: return "Paramètre invalide."
        case RPCS3_IOS_INVALID_STATE: return "Opération impossible dans l'état actuel de l'émulateur."
        case RPCS3_IOS_JIT_UNAVAILABLE: return "Le JIT n'est pas activé."
        case RPCS3_IOS_JIT_MAPPING_FAILED: return "Impossible de préparer la mémoire du JIT."
        case RPCS3_IOS_CORE_INIT_FAILED: return "Le cœur RPCS3 n'a pas pu démarrer."
        case RPCS3_IOS_FIRMWARE_INVALID: return "Fichier de firmware invalide (PS3UPDAT.PUP attendu)."
        case RPCS3_IOS_FIRMWARE_INSTALL_FAILED: return "L'installation du firmware a échoué."
        case RPCS3_IOS_BOOT_FAILED: return "Le jeu n'a pas pu démarrer."
        case RPCS3_IOS_PACKAGE_INVALID: return "Paquet PKG invalide."
        case RPCS3_IOS_PACKAGE_INSTALL_FAILED: return "L'installation du PKG a échoué."
        case RPCS3_IOS_GAME_NOT_FOUND: return "Jeu introuvable."
        case RPCS3_IOS_ISO_INVALID: return "Image ISO invalide."
        case RPCS3_IOS_ISO_INSTALL_FAILED: return "L'import de l'ISO a échoué."
        case RPCS3_IOS_ZIP_INVALID: return "Archive ZIP invalide (un seul dossier de jeu, non chiffré)."
        case RPCS3_IOS_ZIP_INSTALL_FAILED: return "L'import du ZIP a échoué."
        case RPCS3_IOS_FOLDER_INVALID: return "Ce dossier n'est pas un jeu PS3."
        case RPCS3_IOS_FOLDER_INSTALL_FAILED: return "L'import du dossier a échoué."
        case RPCS3_IOS_RAP_INVALID: return "Licence RAP invalide."
        case RPCS3_IOS_NETWORK_ERROR: return "Erreur réseau."
        case RPCS3_IOS_RPCN_ERROR: return "Erreur RPCN."
        case RPCS3_IOS_RPCN_NOT_CONFIGURED: return "RPCN n'est pas configuré."
        default: return "Erreur \(s.rawValue)."
        }
    }

    static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }
}

extension UIApplication {
    var keyWindowRoot: UIViewController? {
        connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
    }
}
