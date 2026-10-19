// The game screen: a CAMetalLayer handed to the core, the boot progress while RPCS3 loads, a
// performance HUD, the on-screen pad, and a menu to pause, resume or stop.

import AVFoundation
import GameController
import SwiftUI

/// A view backed by the CAMetalLayer the core renders into. It keeps the layer's drawable size in
/// physical pixels and tells the core whenever it changes.
final class MetalSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var attached = false
    private var lastSize = CGSize.zero
    /// Called once, when the view first has a size (the core needs one before booting).
    var onReady: ((MetalSurfaceView) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        contentScaleFactor = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0, size != lastSize else { return }
        lastSize = size
        metalLayer.drawableSize = size
        if attached { attach() }
        if let ready = onReady {
            onReady = nil
            ready(self)
        }
    }

    /// Hands the layer (or its new size) to the core. The view keeps the layer alive.
    func attach() {
        guard lastSize.width > 0 else { return }
        attached = true
        // PS3 games run at 60 Hz at most; reporting ProMotion's 120 Hz would let display-rate limits double the work.
        let refresh = Float(min(window?.screen.maximumFramesPerSecond ?? 60, 60))
        let pointer = Unmanaged.passUnretained(metalLayer).toOpaque()
        let w = UInt32(lastSize.width), h = UInt32(lastSize.height)
        Core.queue.async { try? Core.setDisplay(layer: pointer, width: w, height: h, refresh: refresh) }
    }
}

private struct MetalSurface: UIViewRepresentable {
    let ready: (MetalSurfaceView) -> Void

    func makeUIView(context: Context) -> MetalSurfaceView {
        let view = MetalSurfaceView()
        view.onReady = ready
        return view
    }

    func updateUIView(_ view: MetalSurfaceView, context: Context) {}
}

/// The audio session lives only while a game runs: active hardware costs battery, and the core
/// starts its audio unit only once told the session is active (and stops it before deactivation).
@MainActor
final class GameAudio {
    private var active = false
    private var wanted = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        wanted = true
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                if raw == AVAudioSession.InterruptionType.began.rawValue { self?.deactivate(release: false) } else { self?.activate() }
            }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.deactivate(release: true) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.activate() }
        })
        activate()
    }

    func stop() {
        wanted = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        deactivate(release: true)
    }

    private func activate() {
        guard wanted, !active else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            Log.shared.append(level: 2, "Session audio : \(error.localizedDescription)")
            return
        }
        active = true
        NotificationCenter.default.post(name: Notification.Name("RPCS3AudioSessionDidActivate"), object: nil)
    }

    private func deactivate(release: Bool) {
        guard active else { return }
        active = false
        // Synchronous: the core stops its audio unit before the session goes away.
        NotificationCenter.default.post(name: Notification.Name("RPCS3AudioSessionWillDeactivate"), object: nil)
        if release { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}

/// What the HUD shows, kept apart so a refresh redraws only the HUD (not the pad or the game view).
@MainActor
final class HUDModel: ObservableObject {
    @Published var text = ""
    @Published var hot = false
}

@MainActor
final class EmulationController: ObservableObject {
    enum Stage: Equatable {
        case attaching
        case booting(stage: String, fraction: Double?)
        case running
        case paused
        case stopping
        case failed(String)
    }

    @Published var stage: Stage = .attaching
    /// When the boot started, and when its progress last changed (to tell slow from stuck).
    let bootStarted = Date()
    @Published private(set) var lastProgress = Date()
    @Published var controllerConnected = EmulationController.hasController()

    static func hasController() -> Bool {
        GCController.controllers().contains { $0.extendedGamepad != nil }
    }

    /// Re-reads whether a controller is there (notifications can be missed while booting).
    func refreshControllers() {
        let now = Self.hasController()
        if now != controllerConnected { controllerConnected = now }
    }

    let input = InputLoop()
    let hud = HUDModel()
    private let audio = GameAudio()
    private var surface: MetalSurfaceView?
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var booted = false
    private var observers: [NSObjectProtocol] = []
    var hudVisible = true { didSet { if hudVisible != oldValue { schedule() } } }
    var finished: (() -> Void)?

    func surfaceReady(_ view: MetalSurfaceView, session: AppModel.Session) {
        guard surface == nil else { return }
        surface = view
        view.attach()
        boot(session)
    }

    private func boot(_ session: AppModel.Session) {
        stage = .booting(stage: "Démarrage…", fraction: nil)
        input.start()
        audio.start()
        observe()
        UIApplication.shared.isIdleTimerDisabled = true
        Core.run({
            switch session {
            case let .game(game, savestate): try Core.boot(game.titleID, savestate: savestate)
            case .xmb: try Core.bootXMB()
            case .bigPicture: try Core.bootBigPicture()
            }
        }) { result in
            switch result {
            case .success: self.booted = true
            case let .failure(error): self.stage = .failed(error.localizedDescription)
            }
        }
        schedule()
    }

    /// Fast while booting (progress), slow while running (the HUD, and noticing the game quit),
    /// slower still when nothing is shown. The tolerance lets iOS batch the wake-ups.
    private func schedule() {
        let wanted: TimeInterval
        switch stage {
        case .attaching, .booting, .stopping: wanted = 0.25
        case .running: wanted = hudVisible ? 1 : 2
        case .paused, .failed: wanted = 2
        }
        guard wanted != interval || timer == nil else { return }
        timer?.invalidate()
        interval = wanted
        let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = wanted * 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func set(_ next: Stage) {
        guard next != stage else { return }
        lastProgress = Date()
        switch next {
        case let .booting(stageText, fraction):
            if case let .booting(previous, _) = stage, previous == stageText {} else {
                Diagnostics.event("Étape : \(stageText)\(fraction.map { String(format: " (%.0f %%)", $0 * 100) } ?? "")")
            }
        case let .failed(message): Diagnostics.event("Échec : \(message)")
        default: Diagnostics.event("État : \(next)")
        }
        let was = stage
        stage = next
        if next == .paused { input.suspend() }
        if next == .running, was == .paused { input.resume() }
        schedule()
    }

    private func poll() {
        refreshControllers()
        switch Core.emulationState {
        case RPCS3_IOS_EMULATION_STATE_RUNNING:
            set(.running)
            if hudVisible { refreshHUD() }
        case RPCS3_IOS_EMULATION_STATE_PAUSED:
            set(.paused)
        case RPCS3_IOS_EMULATION_STATE_STOPPING:
            set(.stopping)
        case RPCS3_IOS_EMULATION_STATE_STOPPED:
            // The game quit by itself (or stop finished): back to the library.
            if booted, case .failed = stage {} else if booted { close() }
        default:
            if let p = Core.bootProgress() {
                let f = p.total > 0 ? Double(p.completed) / Double(p.total) : nil
                set(.booting(stage: p.stage.isEmpty ? "Chargement…" : p.stage, fraction: f))
            }
        }
    }

    private func refreshHUD() {
        let p = Core.performance() ?? Performance()
        var parts: [String] = []
        if let fps = p.fps { parts.append(String(format: "%.0f FPS", fps)) }
        if let cpu = p.cpu { parts.append(String(format: "CPU %.0f %%", cpu)) }
        if let gpu = p.gpu { parts.append(String(format: "GPU %.0f %%", gpu)) }
        if let used = p.memoryUsed { parts.append("RAM \(Strings.bytes(used))") }
        let thermal = ProcessInfo.processInfo.thermalState
        let hot = thermal == .serious || thermal == .critical
        if hot { parts.append("CHAUD") }
        let text = parts.joined(separator: "  ·  ")
        if hud.text != text { hud.text = text }
        if hud.hot != hot { hud.hot = hot }
    }

    private func observe() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshControllers() }
            })
        }
        // Pause when the app leaves the screen; the user resumes from the menu.
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.stage == .running { self?.pause() } }
        })
    }

    // On the main thread: RPCS3 runs pause and resume through BlockingCallFromMainThread, which
    // logged an error when called from the core queue's thread. Both take a few milliseconds.
    func pause() {
        try? Core.pause()
        poll()
    }

    func resume() {
        try? Core.resume()
        poll()
    }

    func stop() {
        set(.stopping)
        Core.run({ try Core.stop() }) { _ in self.close() }
    }

    /// Stops, then runs `next` instead of going back to the library.
    func stopThen(_ next: @escaping () -> Void) {
        finished = next
        stop()
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        input.stop()
        audio.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        UIApplication.shared.isIdleTimerDisabled = false
        let f = finished
        finished = nil
        f?()
    }
}

struct EmulationView: View {
    let session: AppModel.Session
    let close: () -> Void
    /// Stops the session and starts it again with RPCS3's precompilation off.
    var retryWithoutPrecompilation: (() -> Void)?
    @StateObject private var controller = EmulationController()
    @AppStorage("rpcs3.hud") private var showHUD = true
    @AppStorage("rpcs3.touchpad") private var touchMode = 0 // 0 auto, 1 always, 2 never
    @AppStorage("rpcs3.touchpadOpacity") private var touchOpacity = 0.75
    @AppStorage("rpcs3.touchpadScale") private var touchScale = 0 // 0 small, 1 medium, 2 large
    @State private var menu = false
    @State private var pausedByMenu = false
    @State private var sharing: URL?

    private var title: String {
        switch session {
        case let .game(game, _): return game.title
        case .xmb: return "PlayStation 3 — XMB"
        case .bigPicture: return "Big Picture"
        }
    }

    private func openMenu() {
        guard !menu else { return }
        if controller.stage == .running {
            pausedByMenu = true
            controller.pause()
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { menu = true }
    }

    private func closeMenu() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { menu = false }
        if pausedByMenu {
            pausedByMenu = false
            controller.resume()
        }
    }

    private func shareReport() {
        Core.run({ (try? Core.settings()) ?? [] }) { result in
            let settings = (try? result.get()) ?? []
            Diagnostics.makeReport(settings: settings) { url in sharing = url }
        }
    }

    private var showTouchPad: Bool {
        switch touchMode {
        case 1: return true
        case 2: return false
        default: return !controller.controllerConnected
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalSurface { view in
                controller.finished = close
                controller.surfaceReady(view, session: session)
            }
            .ignoresSafeArea()

            if controller.stage == .running || controller.stage == .paused {
                if showTouchPad && !menu {
                    TouchPadOverlay(pad: controller.input.touch, opacity: touchOpacity, scale: [0.8, 1.0, 1.2][touchScale % 3])
                        .transition(.opacity)
                }
                if showHUD { hud }
            }

            overlay

            if menu {
                InGameMenu(controller: controller, showHUD: $showHUD, touchMode: $touchMode, touchScale: $touchScale,
                           title: title, close: closeMenu, report: shareReport)
                    .zIndex(10)
            } else {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: openMenu) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 16)
                        .padding(.top, 12)
                    }
                    Spacer()
                }
                .zIndex(5)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            controller.input.touchEnabled = showTouchPad
            controller.hudVisible = showHUD
        }
        .onChange(of: showTouchPad) { controller.input.touchEnabled = $0 }
        .onChange(of: showHUD) { controller.hudVisible = $0 }
        .animation(.easeInOut(duration: 0.25), value: showTouchPad)
        .onAppear {
            controller.input.onMenuCombo = { openMenu() }
            controller.input.onControllerUsed = { [weak controller] in
                Task { @MainActor in controller?.refreshControllers() }
            }
        }
        .sheet(item: $sharing) { ShareSheet(items: [$0]) }
    }


    @ViewBuilder private var overlay: some View {
        switch controller.stage {
        case .attaching:
            ProgressView().tint(.white)
        case let .booting(stage, fraction):
            BootOverlay(stage: stage, fraction: fraction, controller: controller,
                        retry: retryWithoutPrecompilation.map { retry in { controller.stopThen(retry) } })
        case .paused:
            VStack(spacing: 16) {
                Image(systemName: "pause.circle.fill").font(.system(size: 64))
                Button("Reprendre") { controller.resume() }.buttonStyle(.borderedProminent)
            }
            .foregroundColor(.white)
        case .stopping:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Arrêt…").foregroundColor(.white)
            }
        case let .failed(message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundColor(.yellow)
                Text(message).multilineTextAlignment(.center).foregroundColor(.white).frame(maxWidth: 460)
                Button("Retour à la bibliothèque") { controller.stop() }.buttonStyle(.borderedProminent)
            }
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.7)))
        case .running:
            EmptyView()
        }
    }

    private var hud: some View {
        HUDView(model: controller.hud)
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack {
            HStack {
                Text(model.text)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(model.hot ? .orange : .green)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .opacity(model.text.isEmpty ? 0 : 1)
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, 18).padding(.top, 10)
        .allowsHitTesting(false)
    }
}

/// The loading screen: progress, how long it has run, the core's latest log lines (so slow and
/// stuck can be told apart), and, when nothing has moved for two minutes, a way out.
private struct BootOverlay: View {
    let stage: String
    let fraction: Double?
    @ObservedObject var controller: EmulationController
    let retry: (() -> Void)?
    @ObservedObject private var log = Log.shared
    @State private var sharing: URL?

    /// Two minutes without progress or log lines (RPCS3_STALL_SECONDS shortens it for tests).
    private static let stallDelay = ProcessInfo.processInfo.environment["RPCS3_STALL_SECONDS"].flatMap(Double.init) ?? 120

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = Int(timeline.date.timeIntervalSince(controller.bootStarted))
            let stalled = timeline.date.timeIntervalSince(max(controller.lastProgress, Log.shared.lastLineAt)) > Self.stallDelay
            VStack(spacing: 14) {
                Text("Chargement").font(.title2.bold())
                if let fraction {
                    ProgressView(value: fraction).frame(width: 340)
                } else {
                    ProgressView().tint(.white)
                }
                Text(stage).font(.callout).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center)
                Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                    .font(.system(.footnote, design: .monospaced)).foregroundColor(.white.opacity(0.6))

                // The last lines the core logged: if they keep changing, it is working.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(log.lines.suffix(4)) { line in
                        Text(line.text).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 460, alignment: .leading)

                if stalled {
                    Text("Ni la progression ni le journal n'ont bougé depuis 2 minutes : RPCS3 est sans doute bloqué.")
                        .font(.footnote).foregroundColor(.yellow).multilineTextAlignment(.center).frame(maxWidth: 460)
                    if let retry {
                        Button("Redémarrer sans précompilation") { retry() }
                            .buttonStyle(.borderedProminent)
                        Text("RPCS3 compilera le code SPU au fil du jeu au lieu de construire tout le cache d'abord. Votre réglage est rétabli à la fermeture.")
                            .font(.caption2).foregroundColor(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 420)
                    }
                } else {
                    Text("La première fois, RPCS3 compile le jeu (PPU, SPU, shaders) : cela peut prendre plusieurs minutes.")
                        .font(.footnote).foregroundColor(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                HStack(spacing: 12) {
                    Button {
                        Core.run({ (try? Core.settings()) ?? [] }) { result in
                            Diagnostics.makeReport(settings: (try? result.get()) ?? []) { sharing = $0 }
                        }
                    } label: { Label("Rapport de diagnostic", systemImage: "stethoscope") }
                    Button(role: .destructive) { controller.stop() } label: { Label("Arrêter", systemImage: "stop.fill") }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .foregroundColor(.white)
            .padding(28)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.65)))
            .onChange(of: stalled) { now in
                if now { Diagnostics.event("Aucune progression ni ligne de journal depuis \(Int(Self.stallDelay)) s (étape : \(stage))") }
            }
        }
        .onAppear { log.watch() }
        .onDisappear { log.unwatch() }
        .sheet(item: $sharing) { ShareSheet(items: [$0]) }
    }
}
