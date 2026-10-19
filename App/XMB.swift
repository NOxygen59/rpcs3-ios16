// The home screen, after the PS3's XrossMediaBar: categories in a row, the selected one's items
// in a column (those before the selection above the row, as on the console), over the PS3's
// "Original" theme: a gradient whose colour follows the month and whose brightness follows the
// time of day, with slow waves. Touch and game controllers both drive it (D-pad, ✕ to open,
// △ for a game's options).

import GameController
import SwiftUI

// MARK: - Theme and background

/// The PS3's colour for each month (January first), and how bright it is at this hour.
enum XMBTheme {
    private static let months: [(Double, Double, Double)] = [
        (0.62, 0.64, 0.68),  // January: silver
        (0.80, 0.66, 0.20),  // February: gold
        (0.48, 0.70, 0.22),  // March: light green
        (0.86, 0.45, 0.62),  // April: pink
        (0.20, 0.62, 0.30),  // May: green
        (0.55, 0.36, 0.72),  // June: purple
        (0.12, 0.62, 0.66),  // July: teal
        (0.28, 0.60, 0.86),  // August: sky blue
        (0.18, 0.36, 0.78),  // September: blue
        (0.46, 0.26, 0.66),  // October: violet
        (0.58, 0.40, 0.24),  // November: bronze
        (0.72, 0.16, 0.18),  // December: red
    ]

    static func color(at date: Date) -> (top: Color, bottom: Color) {
        let calendar = Calendar.current
        let (r, g, b) = months[(calendar.component(.month, from: date) - 1) % 12]
        let hour = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
        // Brightest at 14:00, darkest around 02:00, as the console dims at night.
        let light = 0.62 + 0.38 * (0.5 + 0.5 * cos((hour - 14) / 24 * 2 * .pi))
        let top = Color(red: r * light, green: g * light, blue: b * light)
        let bottom = Color(red: r * light * 0.32, green: g * light * 0.32, blue: b * light * 0.32)
        return (top, bottom)
    }
}

/// The animated waves. Twenty frames a second at most (they move slowly), paused while a game runs, while the app
/// isn't on screen, or when the animated background is turned off.
struct XMBBackground: View {
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { timeline in
            let date = timeline.date
            let colors = XMBTheme.color(at: date)
            Canvas(opaque: true) { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .linearGradient(Gradient(colors: [colors.top, colors.bottom]),
                                                              startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                let t = date.timeIntervalSinceReferenceDate
                for wave in 0..<3 {
                    let w = Double(wave)
                    let base = size.height * (0.52 + 0.07 * w)
                    let amplitude = size.height * (0.05 + 0.015 * w)
                    let thickness = size.height * (0.035 + 0.02 * w)
                    var top = Path(), band = Path()
                    var points: [CGPoint] = []
                    for x in stride(from: 0.0, through: Double(size.width) + 16, by: 16) {
                        let k: Double = x / Double(size.width)
                        let phase1: Double = k * 2.3 * Double.pi + t * (0.18 + 0.05 * w) + w * 1.7
                        let phase2: Double = k * 5.1 * Double.pi - t * (0.11 + 0.04 * w) + w
                        let y: Double = Double(base) + Double(amplitude) * (sin(phase1) + 0.45 * sin(phase2))
                        points.append(CGPoint(x: x, y: y))
                    }
                    top.addLines(points)
                    band.addLines(points)
                    for p in points.reversed() {
                        let k = Double(p.x) / Double(size.width)
                        band.addLine(to: CGPoint(x: p.x, y: p.y + thickness * (0.6 + 0.4 * sin(k * 3 * .pi + t * 0.2 + w))))
                    }
                    band.closeSubpath()
                    context.fill(band, with: .linearGradient(Gradient(colors: [.white.opacity(0.13 - 0.03 * w), .white.opacity(0.0)]),
                                                             startPoint: CGPoint(x: 0, y: base - amplitude), endPoint: CGPoint(x: 0, y: base + thickness + amplitude)))
                    context.stroke(top, with: .color(.white.opacity(0.32 - 0.07 * w)), lineWidth: 1.2)
                }
            }
            // Rasterized by the GPU (Metal), not the CPU, at every frame.
            .drawingGroup()
        }
        .ignoresSafeArea()
    }
}

// MARK: - Status (top right)

/// JIT, increased memory limit, extended virtual addressing, and the memory left: green when
/// granted. Refreshed every five seconds.
struct XMBStatus: View {
    @EnvironmentObject private var app: AppModel
    @State private var available = SystemStatus.availableMemory

    var body: some View {
        HStack(spacing: 8) {
            pill("JIT", on: !app.jitless && JIT.enabled, tip: app.jitless ? "JIT désactivé : interpréteurs" : "JIT actif")
            pill("Mém. accrue", on: SystemStatus.increasedMemoryLimit, tip: "increased-memory-limit")
            pill("Adr. étendu", on: SystemStatus.extendedVirtualAddressing, tip: "extended-virtual-addressing")
            // Zero when iOS reports no limit (the simulator): nothing to show then.
            if available > 0 {
                Text("\(Strings.bytes(available)) libres")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .monospacedDigit()
            }
        }
        .onReceive(Timer.publish(every: 5, tolerance: 1, on: .main, in: .common).autoconnect()) { _ in
            available = SystemStatus.availableMemory
        }
    }

    private func pill(_ label: String, on: Bool, tip: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Color.red.opacity(0.85)).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        .accessibilityLabel("\(label) : \(on ? "actif" : "inactif") (\(tip))")
    }
}

/// The date and time, as the PS3 shows them in its top-right corner.
struct XMBClock: View {
    var body: some View {
        TimelineView(.everyMinute) { timeline in
            Text(timeline.date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).hour().minute()))
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()
        }
    }
}

// MARK: - Model

/// One entry of a category's column.
struct XMBItem: Identifiable {
    enum Icon {
        case symbol(String)
        case game(String)
        /// The PS3's own menu, drawn as a game tile.
        case system
    }

    let id: String
    let title: String
    let subtitle: String
    let icon: Icon
    var game: Game?
    let action: () -> Void
}

struct XMBCategory: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let items: [XMBItem]
}

// MARK: - The bar

struct XMBView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("rpcs3.xmb.animated") private var animated = true
    @AppStorage("rpcs3.xmb.category") private var category = 1
    @State private var selection: [String: Int] = [:]
    @State private var drag = CGSize.zero
    @State private var importing = false
    @State private var sheet: Sheet?
    @StateObject private var pad = XMBGamepad()

    enum Sheet: Identifiable {
        case settings, rpcn, log, about, game(Game)
        var id: String {
            switch self {
            case .settings: return "settings"
            case .rpcn: return "rpcn"
            case .log: return "log"
            case .about: return "about"
            case let .game(g): return "game-\(g.titleID)"
            }
        }
    }

    private let spacing: CGFloat = 132
    private let rowHeight: CGFloat = 84

    private var categories: [XMBCategory] {
        let games = app.games.filter(\.bootable)
        var gameItems: [XMBItem] = []
        if app.firmware.isEmpty {
            gameItems.append(XMBItem(id: "firmware", title: "Installer le firmware PS3", subtitle: "PS3UPDAT.PUP, à télécharger sur le site de PlayStation",
                                     icon: .symbol("exclamationmark.triangle.fill"), action: { importing = true }))
        }
        // The console's own menu, first in the list like a game.
        gameItems.append(XMBItem(id: "vsh", title: "PlayStation 3 — XMB",
                                 subtitle: app.firmware.isEmpty ? "Installez d'abord le firmware PS3" : "Le vrai menu de la console, firmware \(app.firmware)",
                                 icon: .system, action: { if app.firmware.isEmpty { importing = true } else { app.session = .xmb } }))
        gameItems += games.map { game in
            XMBItem(id: "game-\(game.titleID)", title: game.title, subtitle: "\(game.titleID) · v\(game.version)",
                    icon: .game(game.iconPath), game: game, action: { app.play(game) })
        }
        gameItems.append(XMBItem(id: "install", title: "Installer des fichiers…", subtitle: "Firmware, PKG, RAP, ISO + clé, ZIP, dossier de jeu",
                                 icon: .symbol("square.and.arrow.down.fill"), action: { importing = true }))
        gameItems.append(XMBItem(id: "bigpicture", title: "Mode Big Picture", subtitle: "La bibliothèque de RPCS3, à la manette",
                                 icon: .symbol("tv.fill"), action: { app.session = .bigPicture }))

        return [
            XMBCategory(id: "settings", title: "Paramètres", symbol: "gearshape.fill", items: [
                XMBItem(id: "rpcs3", title: "Réglages de RPCS3", subtitle: "Processeur, graphismes, audio, système…", icon: .symbol("slider.horizontal.3"), action: { sheet = .settings }),
                XMBItem(id: "theme", title: "Thème : \(animated ? "animé" : "fixe")", subtitle: "Les vagues du fond (fixe : moins de batterie)", icon: .symbol("paintbrush.fill"), action: { animated.toggle() }),
                XMBItem(id: "about", title: "Système", subtitle: "JIT, mémoire, firmware, version", icon: .symbol("info.circle.fill"), action: { sheet = .about }),
                XMBItem(id: "log", title: "Journal", subtitle: "Messages du moteur", icon: .symbol("doc.text.fill"), action: { sheet = .log }),
            ]),
            XMBCategory(id: "game", title: "Jeu", symbol: "gamecontroller.fill", items: gameItems),
            XMBCategory(id: "network", title: "Réseau", symbol: "globe", items: [
                XMBItem(id: "rpcn", title: "RPCN", subtitle: "Compte, serveur et amis pour jouer en ligne", icon: .symbol("person.2.fill"), action: { sheet = .rpcn }),
                XMBItem(id: "patches", title: "Mettre à jour les patchs", subtitle: "Dépôt de patchs de RPCS3", icon: .symbol("bandage.fill"), action: refreshPatches),
                XMBItem(id: "configdb", title: "Mettre à jour la base de configuration", subtitle: "Réglages recommandés par jeu", icon: .symbol("arrow.triangle.2.circlepath"), action: refreshConfigDatabase),
            ]),
        ]
    }

    private func selected(in category: XMBCategory) -> Int {
        min(max(selection[category.id] ?? 0, 0), max(category.items.count - 1, 0))
    }

    var body: some View {
        GeometryReader { geo in
            let cats = categories
            let current = min(max(category, 0), cats.count - 1)
            let barY = geo.size.height * 0.30
            let anchorX = geo.size.width * 0.24
            ZStack(alignment: .topLeading) {
                XMBBackground(paused: !animated || app.session != nil || scenePhase != .active)

                // Items of the selected category: the selection and those after it below the
                // bar, those before it above.
                let cat = cats[current]
                let sel = selected(in: cat)
                ForEach(Array(cat.items.enumerated()), id: \.element.id) { index, item in
                    let isSelected = index == sel
                    let below = barY + 92 + CGFloat(index - sel) * rowHeight
                    let above = barY - 62 - CGFloat(sel - 1 - index) * rowHeight
                    let y = (index >= sel ? below : above) + (abs(drag.height) > abs(drag.width) ? drag.height : 0)
                    if y > -rowHeight, y < geo.size.height + rowHeight {
                    XMBRow(item: item, selected: isSelected, onOptions: item.game.map { game in { sheet = .game(game) } })
                        .position(x: anchorX - 40 + 260, y: y)
                        .opacity(index < sel ? 0.55 : (isSelected ? 1 : 0.75))
                        .onTapGesture {
                            if isSelected { item.action() } else { withAnimation(.easeOut(duration: 0.2)) { selection[cat.id] = index } }
                        }
                    }
                }

                // The categories.
                ForEach(Array(cats.enumerated()), id: \.element.id) { index, c in
                    let x = anchorX + CGFloat(index - current) * spacing + (abs(drag.width) > abs(drag.height) ? drag.width : 0)
                    VStack(spacing: 8) {
                        Image(systemName: c.symbol)
                            .font(.system(size: index == current ? 46 : 36, weight: .regular))
                            .shadow(color: .white.opacity(index == current ? 0.6 : 0), radius: 10)
                        Text(c.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .opacity(index == current ? 1 : 0)
                    }
                    .foregroundColor(.white.opacity(index == current ? 1 : 0.65))
                    .frame(width: 120, height: 100)
                    .position(x: x, y: barY)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.25)) { category = index } }
                }

                // Top right: status and clock.
                HStack(spacing: 14) {
                    XMBStatus()
                    XMBClock()
                }
                .padding(.top, 14)
                .padding(.trailing, 22)
                .frame(width: geo.size.width, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 12)
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    let t = value.translation
                    let cat = cats[current]
                    let sel = selected(in: cat)
                    withAnimation(.easeOut(duration: 0.25)) {
                        if abs(t.width) > abs(t.height), abs(t.width) > 40 {
                            category = min(max(current - Int((t.width / spacing).rounded(t.width > 0 ? .up : .down)), 0), cats.count - 1)
                        } else if abs(t.height) > 24 {
                            let steps = Int((t.height / rowHeight).rounded(t.height > 0 ? .up : .down))
                            selection[cat.id] = min(max(sel - steps, 0), max(cat.items.count - 1, 0))
                        }
                        drag = .zero
                    }
                })
            .onAppear {
                pad.handler = { handle($0) }
                pad.start()
            }
            // A game takes the controllers over (its InputLoop installs its own handlers);
            // back on the bar, they are the bar's again.
            .onChange(of: app.session == nil) { idle in if idle { pad.start() } else { pad.stop() } }
            // Play from a game's options: the sheet closes first, then the game opens (iOS
            // presents one over the other only once the sheet is gone).
            .onChange(of: app.session?.id) { id in
                guard id != nil, sheet != nil, let session = app.session else { return }
                app.session = nil
                sheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { app.session = session }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .fileImporter(isPresented: $importing, allowedContentTypes: AppModel.importTypes, allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { app.install(urls) }
        }
        .sheet(item: $sheet) { which in
            NavigationStack {
                Group {
                    switch which {
                    case .settings: SettingsView(scope: .global)
                    case .rpcn: RPCNView()
                    case .log: LogView()
                    case .about: AboutView()
                    case let .game(game): GameDetailView(game: game)
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { sheet = nil } } }
            }
            .environmentObject(app)
            .preferredColorScheme(.dark)
        }
    }

    /// A controller press: move along the bar or the column, ✕ opens, △ shows a game's options.
    private func handle(_ input: XMBGamepad.Input) {
        guard sheet == nil, app.session == nil, !importing else { return }
        let cats = categories
        let current = min(max(category, 0), cats.count - 1)
        let cat = cats[current]
        let sel = selected(in: cat)
        withAnimation(.easeOut(duration: 0.18)) {
            switch input {
            case .left: category = max(current - 1, 0)
            case .right: category = min(current + 1, cats.count - 1)
            case .up: selection[cat.id] = max(sel - 1, 0)
            case .down: selection[cat.id] = min(sel + 1, max(cat.items.count - 1, 0))
            case .confirm: if cat.items.indices.contains(sel) { cat.items[sel].action() }
            case .options: if let game = cat.items[safe: sel]?.game { sheet = .game(game) }
            }
        }
    }

    private func refreshPatches() {
        app.task = AppModel.Work(title: "Mise à jour des patchs…")
        Task {
            do {
                switch try await Online.refreshPatches() {
                case .updated: app.message = "Patchs mis à jour."
                case .upToDate: app.message = "Les patchs sont déjà à jour."
                }
            } catch {
                app.message = error.localizedDescription
            }
            app.task = nil
        }
    }

    private func refreshConfigDatabase() {
        app.task = AppModel.Work(title: "Mise à jour de la base de configuration…")
        Task {
            do {
                try await Online.refreshConfigDatabase(force: true)
                app.message = "Base de configuration à jour."
            } catch {
                app.message = error.localizedDescription
            }
            app.task = nil
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// One line of a column: the icon (a game's ICON0, as the console shows it), its title, and
/// for the selection a subtitle and, for a game, the △ options button.
private struct XMBRow: View {
    let item: XMBItem
    let selected: Bool
    let onOptions: (() -> Void)?

    var body: some View {
        HStack(spacing: 18) {
            Group {
                switch item.icon {
                case let .game(path):
                    GameIcon(path: path, size: selected ? 62 : 46)
                        .shadow(color: .white.opacity(selected ? 0.45 : 0), radius: 12)
                case .system:
                    XMBTile(size: selected ? 62 : 46)
                        .shadow(color: .white.opacity(selected ? 0.45 : 0), radius: 12)
                case let .symbol(name):
                    Image(systemName: name)
                        .font(.system(size: selected ? 34 : 26))
                        .foregroundColor(.white)
                        .frame(width: selected ? 113 : 84, height: selected ? 62 : 46)
                        .shadow(color: .white.opacity(selected ? 0.5 : 0), radius: 10)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: selected ? 22 : 18, weight: selected ? .semibold : .regular, design: .rounded))
                    .lineLimit(1)
                if selected {
                    Text(item.subtitle)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            if selected, let onOptions {
                Button(action: onOptions) {
                    HStack(spacing: 6) {
                        Text("△").font(.system(size: 16, weight: .bold)).foregroundColor(Color(red: 0.4, green: 0.9, blue: 0.75))
                        Text("Options").font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.3)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 520, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}

/// The tile of the console's own menu, at the size of a game's ICON0 (320 × 176).
private struct XMBTile: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.30), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
            Path { p in
                let w = size * 320 / 176
                p.move(to: CGPoint(x: 0, y: size * 0.70))
                p.addCurve(to: CGPoint(x: w, y: size * 0.55), control1: CGPoint(x: w * 0.35, y: size * 0.45), control2: CGPoint(x: w * 0.65, y: size * 0.85))
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
            VStack(spacing: size * 0.02) {
                Text("PS3").font(.system(size: size * 0.30, weight: .heavy, design: .rounded)).italic()
                Text("XMB").font(.system(size: size * 0.16, weight: .semibold, design: .rounded)).opacity(0.8)
            }
            .foregroundColor(.white)
        }
        .frame(width: size * 320 / 176, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
        .overlay(RoundedRectangle(cornerRadius: size * 0.12).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
    }
}

// MARK: - Game controllers on the bar

/// Reads controllers while the bar is on screen (the game takes them over while it runs):
/// directions repeat while held, as on the console.
final class XMBGamepad: ObservableObject {
    enum Input { case left, right, up, down, confirm, options }

    var handler: ((Input) -> Void)?
    private var held: Input?
    private var repeatTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.attach() })
        attach()
    }

    func stop() {
        guard running else { return }
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        release()
    }

    private func attach() {
        for controller in GCController.controllers() {
            guard let pad = controller.extendedGamepad else { continue }
            pad.valueChangedHandler = { [weak self] pad, element in self?.changed(pad, element) }
        }
    }

    private func changed(_ pad: GCExtendedGamepad, _ element: GCControllerElement) {
        guard running else { return }
        if element === pad.buttonA, pad.buttonA.isPressed { fire(.confirm); return }
        if element === pad.buttonY, pad.buttonY.isPressed { fire(.options); return }
        let x = pad.dpad.xAxis.value + pad.leftThumbstick.xAxis.value
        let y = pad.dpad.yAxis.value + pad.leftThumbstick.yAxis.value
        let direction: Input? = abs(x) > 0.5 && abs(x) >= abs(y) ? (x > 0 ? .right : .left)
            : abs(y) > 0.5 ? (y > 0 ? .up : .down) : nil
        guard direction != held else { return }
        release()
        guard let direction else { return }
        held = direction
        fire(direction)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] _ in
                if let held = self?.held { self?.fire(held) }
            }
        }
    }

    private func release() {
        held = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func fire(_ input: Input) {
        handler?(input)
    }
}
