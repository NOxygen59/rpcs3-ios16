// The app's state: starting the core (with or without JIT), the game library, installs and their
// progress, and the running session.

import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case starting
        /// No debugger: JIT is off. The user relaunches through TrollStore or goes on without it.
        case needsJIT
        case ready
        case failed(String)
    }

    /// What the emulation screen shows.
    enum Session: Equatable, Identifiable {
        case game(Game, savestate: String?)
        case xmb
        case bigPicture

        var id: String {
            switch self {
            case let .game(g, s): return "game-\(g.titleID)-\(s ?? "")"
            case .xmb: return "xmb"
            case .bigPicture: return "bigpicture"
            }
        }
    }

    struct Work: Equatable {
        var title: String
        var stage: String = ""
        var fraction: Double?
    }

    @Published var phase: Phase = .starting
    @Published private(set) var games: [Game] = []
    @Published private(set) var firmware = ""
    @Published var task: Work?
    @Published var message: String?
    @Published var session: Session? {
        didSet {
            if session != nil { coverShown = true }
            if let session, session != oldValue { Diagnostics.event("Lancement : \(session.id)") }
        }
    }
    /// A session to start once the game screen has really gone away (iOS reuses a screen that
    /// is still closing when the same session comes back too soon).
    private var pendingSession: Session?
    private var coverShown = false
    @Published private(set) var jitless = false

    init() {
        Storage.prepare()
        Diagnostics.start()
    }

    // MARK: Starting

    func start() {
        guard phase != .ready else { return }
        if JIT.enabled {
            initialize()
        } else if UserDefaults.standard.bool(forKey: JIT.jitlessKey) {
            JIT.useJitless()
            jitless = true
            initialize()
        } else {
            phase = .needsJIT
        }
    }

    /// Relaunch through TrollStore's "Open with JIT".
    func relaunchWithJIT() {
        guard let url = JIT.trollStoreURL else { return }
        UIApplication.shared.open(url) { opened in
            if !opened {
                self.message = "TrollStore n'a pas répondu. Dans TrollStore, faites un appui long sur RPCS3 puis « Open with JIT »."
            }
        }
    }

    func continueWithoutJIT(remember: Bool) {
        if remember { UserDefaults.standard.set(true, forKey: JIT.jitlessKey) }
        JIT.useJitless()
        jitless = true
        initialize()
    }

    private func initialize() {
        phase = .starting
        let arena = UInt32(UserDefaults.standard.integer(forKey: "rpcs3.jitArena"))
        Core.run({
            try Core.initialize(expandedArenaMiB: arena)
            RPCNKeychain.restore()
        }) { result in
            switch result {
            case .success:
                self.phase = .ready
                Diagnostics.event("Cœur prêt (\(self.jitless ? "sans JIT" : "JIT")) — " + Diagnostics.systemSummary(core: true).suffix(2).joined(separator: " ; "))
                self.reload()
                self.restorePrecompilationIfNeeded()
                Task { try? await Online.refreshConfigDatabase() }
            case let .failure(error):
                Diagnostics.event("Échec du démarrage du cœur : \(error.localizedDescription)")
                if (error as? CoreError)?.code == RPCS3_IOS_JIT_UNAVAILABLE {
                    self.phase = .needsJIT
                } else {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func reload() {
        Core.run({ (try Core.games(), Core.firmwareVersion) }) { result in
            if case let .success((games, firmware)) = result {
                self.games = games
                self.firmware = firmware
            }
        }
    }

    // MARK: Installing

    static let importTypes: [UTType] = [.item, .folder]

    /// Installs what the user picked: firmware (.PUP), packages (.pkg), licences (.rap), disc images
    /// (.iso, with its .dkey/.key picked alongside), game archives (.zip) and game folders.
    func install(_ urls: [URL]) {
        let keys = urls.filter { ["dkey", "key"].contains($0.pathExtension.lowercased()) }
        let items = urls.filter { !keys.contains($0) }
        guard !items.isEmpty else { return }
        task = Work(title: "Préparation…")
        Core.queue.async {
            var failures: [String] = []
            var installedSomething = false
            for url in items {
                let scoped = url.startAccessingSecurityScopedResource()
                let keyURL = keys.first { $0.deletingPathExtension().lastPathComponent.lowercased() == url.deletingPathExtension().lastPathComponent.lowercased() } ?? (items.count == 1 ? keys.first : nil)
                let keyScoped = keyURL?.startAccessingSecurityScopedResource() ?? false
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    if keyScoped { keyURL?.stopAccessingSecurityScopedResource() }
                }
                let name = url.lastPathComponent
                let progress: Progress = { done, total, stage in
                    let f = total > 0 ? Double(done) / Double(total) : nil
                    DispatchQueue.main.async { self.task = Work(title: name, stage: stage, fraction: f) }
                }
                DispatchQueue.main.async { self.task = Work(title: name) }
                do {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    switch url.pathExtension.lowercased() {
                    case _ where isDir.boolValue: try Core.installFolder(url.path, progress: progress)
                    case "pup": try Core.installFirmware(url.path, progress: progress)
                    case "pkg": try Core.installPackage(url.path, progress: progress)
                    case "rap": try Core.installRAP(url.path)
                    case "iso": try Core.installISO(url.path, key: keyURL?.path, progress: progress)
                    case "zip": try Core.installZIP(url.path, progress: progress)
                    default: throw CoreError.status(RPCS3_IOS_INVALID_ARGUMENT, "\(name) : format non pris en charge (PUP, PKG, RAP, ISO, ZIP ou dossier).")
                    }
                    installedSomething = true
                } catch {
                    failures.append("\(name) : \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.task = nil
                if installedSomething { self.reload() }
                if !failures.isEmpty { self.message = failures.joined(separator: "\n") }
            }
        }
    }

    // MARK: Playing

    func play(_ game: Game, savestate: String? = nil) {
        guard game.bootable else {
            message = "\(game.title) n'est pas un jeu lançable (\(game.category))."
            return
        }
        session = .game(game, savestate: savestate)
    }

    // MARK: Temporary settings (one session)

    /// Settings changed for one session only, with their previous values, kept in the user
    /// defaults until restored (when the session ends, or at the next launch after a crash).
    private static let restoreKey = "rpcs3.restoreSettings"
    private static let legacyRestoreKey = "rpcs3.restorePrecompilation"

    /// A setting to change for one session: its key, and how to pick the new value among the
    /// core's options (option values are read at run time, not hard-coded).
    struct Override {
        let key: String
        let pick: (Setting) -> String?
    }

    /// PPU/SPU precompilation off: RPCS3 compiles as it runs instead of building the cache first.
    static let withoutPrecompilation = [Override(key: "advanced.llvm_precompilation") { _ in "false" }]

    /// The XMB: the RSX FIFO behaves as in upstream RPCS3. This port's ARMSX3-style FIFO changes
    /// (deferred GET publishing, 4 KiB read cache, event waits, parked DMA waits) are the first
    /// suspects of the VSH freeze ("nv406e::semaphore_acquire has timed out" right after the RSX
    /// context is set up).
    static let xmbCompatibility: [Override] = [
        Override(key: "experimental.deferred_get_publishing") { option($0, matching: ["disab", "désac", "off"]) },
        Override(key: "experimental.fifo_cache_size") { option($0, matching: ["1 kib", "1kib", "1 kb", "1024", "original"]) },
        Override(key: "experimental.fifo_idle_mode") { option($0, matching: ["yield", "céder"]) },
        Override(key: "experimental.rsx_dma_wait_parking") { option($0, matching: ["disab", "désac", "off"]) },
    ]

    private static func option(_ setting: Setting, matching words: [String]) -> String? {
        setting.options.first { option in
            let text = (option.value + " " + option.label).lowercased()
            return words.contains { text.contains($0) }
        }?.value
    }

    /// Applies `overrides`, remembers the previous values, then starts `session`.
    func start(_ session: Session, with overrides: [Override], reason: String) {
        Core.run({ () -> [String: String] in
            let settings = (try? Core.settings()) ?? []
            var previous: [String: String] = [:]
            var applied: [String] = []
            for override in overrides {
                guard let setting = settings.first(where: { $0.key == override.key }),
                      let value = override.pick(setting), value != setting.value else { continue }
                try Core.setSetting(override.key, value)
                previous[override.key] = setting.value
                applied.append("\(override.key) = \(value) (était \(setting.value))")
            }
            Diagnostics.event("\(reason) : " + (applied.isEmpty ? "rien à changer" : applied.joined(separator: " ; ")))
            return previous
        }) { result in
            switch result {
            case let .success(previous):
                var saved = UserDefaults.standard.dictionary(forKey: Self.restoreKey) as? [String: String] ?? [:]
                for (key, value) in previous where saved[key] == nil { saved[key] = value }
                UserDefaults.standard.set(saved, forKey: Self.restoreKey)
                self.pendingSession = session
                self.launchPending()
            case let .failure(error):
                self.message = error.localizedDescription
            }
        }
    }

    /// Called once the stalled session has closed: the same session again, without precompilation.
    func retryWithoutPrecompilation(_ session: Session) {
        start(session, with: Self.withoutPrecompilation, reason: "Redémarrage sans précompilation")
    }

    /// The console's own menu, in XMB compatibility mode unless turned off.
    func bootXMB() {
        if UserDefaults.standard.object(forKey: "rpcs3.xmbCompat") as? Bool ?? true {
            start(.xmb, with: Self.xmbCompatibility, reason: "Mode compatibilité XMB")
        } else {
            session = .xmb
        }
    }

    /// The game screen has finished closing.
    func gameScreenDismissed() {
        coverShown = false
        launchPending()
    }

    private func launchPending() {
        guard let next = pendingSession, session == nil, !coverShown else { return }
        pendingSession = nil
        session = next
    }

    /// Puts back every setting a session changed.
    func restorePrecompilationIfNeeded() {
        var saved = UserDefaults.standard.dictionary(forKey: Self.restoreKey) as? [String: String] ?? [:]
        if let legacy = UserDefaults.standard.string(forKey: Self.legacyRestoreKey) {
            saved["advanced.llvm_precompilation"] = saved["advanced.llvm_precompilation"] ?? legacy
            UserDefaults.standard.removeObject(forKey: Self.legacyRestoreKey)
        }
        guard !saved.isEmpty else { return }
        Core.run({ () -> [String] in
            var restored: [String] = []
            for (key, value) in saved where (try? Core.setSetting(key, value)) != nil { restored.append(key) }
            Diagnostics.event("Réglages rétablis : \(restored.joined(separator: ", "))")
            return restored
        }) { result in
            guard case let .success(restored) = result else { return }
            var left = UserDefaults.standard.dictionary(forKey: Self.restoreKey) as? [String: String] ?? [:]
            for key in restored { left.removeValue(forKey: key) }
            if left.isEmpty { UserDefaults.standard.removeObject(forKey: Self.restoreKey) } else { UserDefaults.standard.set(left, forKey: Self.restoreKey) }
        }
    }

    func delete(_ game: Game) {
        Core.run({ try Core.deleteGame(game.titleID) }) { result in
            if case let .failure(error) = result { self.message = error.localizedDescription }
            self.reload()
        }
    }
}
