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
        didSet { if session != nil { coverShown = true } }
    }
    /// A session to start once the game screen has really gone away (iOS reuses a screen that
    /// is still closing when the same session comes back too soon).
    private var pendingSession: Session?
    private var coverShown = false
    @Published private(set) var jitless = false

    init() {}

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
                self.reload()
                self.restorePrecompilationIfNeeded()
                Task { try? await Online.refreshConfigDatabase() }
            case let .failure(error):
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

    // MARK: Starting without precompilation

    /// The key of RPCS3's "PPU/SPU LLVM Precompilation" setting, and where its previous value
    /// is kept while a session runs without it (restored when it ends, or at the next launch).
    private static let precompilationKey = "advanced.llvm_precompilation"
    private static let restoreKey = "rpcs3.restorePrecompilation"

    /// Stops nothing itself: called once the stalled session has closed. Turns precompilation
    /// off, then starts the same session again; RPCS3 then compiles SPU code as it runs instead
    /// of building the whole cache first.
    func retryWithoutPrecompilation(_ session: Session) {
        Core.run({ () -> String in
            let current = (try? Core.settings())?.first { $0.key == Self.precompilationKey }?.value ?? "true"
            try Core.setSetting(Self.precompilationKey, "false")
            return current
        }) { result in
            switch result {
            case let .success(previous):
                if UserDefaults.standard.string(forKey: Self.restoreKey) == nil {
                    UserDefaults.standard.set(previous, forKey: Self.restoreKey)
                }
                self.pendingSession = session
                self.launchPending()
            case let .failure(error):
                self.message = error.localizedDescription
            }
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

    /// Puts the precompilation setting back as it was, if a session changed it.
    func restorePrecompilationIfNeeded() {
        guard let previous = UserDefaults.standard.string(forKey: Self.restoreKey) else { return }
        Core.run({ try Core.setSetting(Self.precompilationKey, previous) }) { result in
            if case .success = result { UserDefaults.standard.removeObject(forKey: Self.restoreKey) }
        }
    }

    func delete(_ game: Game) {
        Core.run({ try Core.deleteGame(game.titleID) }) { result in
            if case let .failure(error) = result { self.message = error.localizedDescription }
            self.reload()
        }
    }
}
