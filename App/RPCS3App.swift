// RPCS3 for iOS 16: the JIT check at launch, then the game library.

import SwiftUI

@main
struct RPCS3App: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Files opened with RPCS3 (PKG, PUP, ISO, RAP…) from Files or another app.
                    if url.isFileURL, app.phase == .ready { app.install([url]) }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            switch app.phase {
            case .starting:
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Initialisation du cœur RPCS3…").foregroundColor(.secondary)
                }
            case .needsJIT:
                JITGateView()
            case let .failed(message):
                VStack(spacing: 16) {
                    Image(systemName: "xmark.octagon.fill").font(.system(size: 48)).foregroundColor(.red)
                    Text("RPCS3 n'a pas pu démarrer").font(.title2.bold())
                    Text(message).multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 520)
                    NavigationStack { LogView() }.frame(maxWidth: 700, maxHeight: 380).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding()
            case .ready:
                LibraryView()
            }
        }
        .onAppear { app.start() }
        .fullScreenCover(item: $app.session) { session in
            EmulationView(session: session) {
                app.session = nil
                app.reload()
            }
        }
        .overlay { if let task = app.task { WorkOverlay(work: task) } }
        .alert("RPCS3", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) {
            Button("OK") {}
        } message: {
            Text(app.message ?? "")
        }
    }
}

/// Shown at launch when the process has no debugger attached (so no JIT).
struct JITGateView: View {
    @EnvironmentObject private var app: AppModel
    @State private var remember = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 64)).foregroundColor(.orange)
            Text("Le JIT n'est pas activé").font(.largeTitle.bold())
            Text("RPCS3 a besoin du JIT pour faire tourner les jeux à une vitesse jouable. Sur iOS 16 avec TrollStore, relancez l'app avec « Open with JIT ».")
                .multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 560)
            Button {
                app.relaunchWithJIT()
            } label: {
                Label("Relancer avec JIT (TrollStore)", systemImage: "bolt.fill").font(.headline).frame(maxWidth: 360)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            VStack(spacing: 10) {
                Button("Continuer sans JIT") { app.continueWithoutJIT(remember: remember) }
                    .buttonStyle(.bordered)
                Toggle("Ne plus demander", isOn: $remember).frame(maxWidth: 260)
                Text("Sans JIT, RPCS3 utilise ses interpréteurs : la bibliothèque, les installations et les réglages marchent, mais les jeux sont très lents.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 480)
            }

            Text("Si rien ne se passe : ouvrez TrollStore, faites un appui long sur RPCS3, puis « Open with JIT ». TrollStore 2.0.12 ou plus récent est nécessaire.")
                .font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 520)
        }
        .padding(32)
    }
}

struct WorkOverlay: View {
    let work: AppModel.Work

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(work.title).font(.headline).multilineTextAlignment(.center)
                if let f = work.fraction {
                    ProgressView(value: f).frame(width: 320)
                    Text("\(Int(f * 100)) %").font(.caption).monospacedDigit().foregroundColor(.secondary)
                } else {
                    ProgressView()
                }
                if !work.stage.isEmpty { Text(work.stage).font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center) }
                Text("Gardez RPCS3 au premier plan pendant l'installation.").font(.caption2).foregroundColor(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 440)
            .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @State private var importing = false
    @State private var search = ""
    @State private var sheet: Sheet?
    @State private var path = NavigationPath()

    enum Sheet: String, Identifiable {
        case settings, rpcn, log, about
        var id: String { rawValue }
    }

    private var games: [Game] {
        let list = app.games.filter { $0.bootable }
        guard !search.isEmpty else { return list }
        return list.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.titleID.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if app.firmware.isEmpty { firmwareBanner }
                if games.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 22)], spacing: 26) {
                        ForEach(games) { game in
                            NavigationLink(value: game) {
                                VStack(alignment: .leading, spacing: 8) {
                                    GameIcon(path: game.iconPath, size: 121)
                                        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                                    Text(game.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundColor(.primary)
                                    Text(game.titleID).font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { app.play(game) } label: { Label("Jouer", systemImage: "play.fill") }
                                Button { path.append(game) } label: { Label("Détails", systemImage: "info.circle") }
                                Button(role: .destructive) { app.delete(game) } label: { Label("Supprimer", systemImage: "trash") }
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { app.play(game) })
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Bibliothèque")
            .navigationDestination(for: Game.self) { GameDetailView(game: $0) }
            .searchable(text: $search, prompt: "Rechercher un jeu")
            .refreshable { app.reload() }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Menu {
                        Button { app.session = .xmb } label: { Label("Menu de la PS3 (XMB)", systemImage: "square.grid.3x3") }
                            .disabled(app.firmware.isEmpty)
                        Button { app.session = .bigPicture } label: { Label("Mode Big Picture", systemImage: "tv") }
                    } label: {
                        Label("Lancer", systemImage: "play.rectangle")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { importing = true } label: { Label("Installer", systemImage: "plus") }
                    Menu {
                        Button { sheet = .settings } label: { Label("Réglages", systemImage: "gearshape") }
                        Button { sheet = .rpcn } label: { Label("RPCN (jeu en ligne)", systemImage: "person.2") }
                        Button { sheet = .log } label: { Label("Journal", systemImage: "doc.text") }
                        Button { sheet = .about } label: { Label("À propos", systemImage: "info.circle") }
                    } label: {
                        Label("Plus", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
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
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { sheet = nil } } }
            }
            .environmentObject(app)
        }
    }

    private var firmwareBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Firmware PS3 manquant").font(.headline)
                Text("Installez PS3UPDAT.PUP (téléchargeable sur le site de PlayStation) avec le bouton +.").font(.callout).foregroundColor(.secondary)
            }
            Spacer()
            Button("Installer") { importing = true }.buttonStyle(.borderedProminent)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.yellow.opacity(0.12)))
        .padding([.horizontal, .top], 24)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller").font(.system(size: 56)).foregroundColor(.secondary)
            Text(search.isEmpty ? "Aucun jeu" : "Aucun résultat").font(.title2.bold())
            if search.isEmpty {
                Text("Touchez + pour installer : firmware (.PUP), jeux PSN (.pkg) et leurs licences (.rap), disques (.iso avec sa clé .dkey), archives (.zip) ou dossiers de jeu.")
                    .multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 520)
                Text("Vous pouvez aussi déposer vos fichiers dans Fichiers › Sur mon iPad › RPCS3, puis les installer depuis +.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 520)
            }
        }
        .padding(.top, 120)
        .frame(maxWidth: .infinity)
    }
}

struct AboutView: View {
    @EnvironmentObject private var app: AppModel
    @AppStorage("rpcs3.jitArena") private var arena = 0
    @AppStorage(JIT.jitlessKey) private var alwaysJitless = false

    var body: some View {
        List {
            Section("RPCS3") {
                row("Firmware", app.firmware.isEmpty ? "non installé" : app.firmware)
                row("JIT", app.jitless ? "désactivé (interpréteurs)" : "activé")
                row("ABI du cœur", "\(Core.abiVersion)")
            }
            Section {
                Toggle("Toujours démarrer sans JIT", isOn: $alwaysJitless)
                Picker("Mémoire JIT supplémentaire", selection: $arena) {
                    Text("Automatique").tag(0)
                    Text("512 Mio").tag(512)
                    Text("768 Mio").tag(768)
                    Text("1 Gio").tag(1024)
                }
            } header: {
                Text("JIT")
            } footer: {
                Text("Ces réglages s'appliquent au prochain lancement de l'app.")
            }
            Section("Build") {
                Text(Core.buildInfo).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section {
                Text("Émulateur RPCS3 (équipe RPCS3), port iOS par XITRIX, interface iOS 16 réécrite pour iPad.").font(.callout)
            }
        }
        .navigationTitle("À propos")
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack { Text(name); Spacer(); Text(value).foregroundColor(.secondary) }
    }
}

struct LogView: View {
    @ObservedObject private var log = Log.shared
    @State private var errorsOnly = false
    @State private var sharing: URL?

    var body: some View {
        let lines = errorsOnly ? log.lines.filter { (1...2).contains($0.level) } : log.lines
        ScrollViewReader { proxy in
            List(lines) { line in
                Text(line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(line.level == 1 ? .red : line.level == 2 ? .orange : line.level == 5 ? .yellow : .primary)
                    .textSelection(.enabled)
                    .id(line.id)
            }
            .listStyle(.plain)
            .onAppear {
                log.watch()
                if let last = log.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onDisappear { log.unwatch() }
        }
        .navigationTitle("Journal")
        .sheet(item: $sharing) { ShareSheet(items: [$0]) }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                Toggle(isOn: $errorsOnly) { Label("Erreurs", systemImage: "exclamationmark.triangle") }
                Button {
                    // Built only when asked: joining thousands of lines on every redraw would be waste.
                    let url = Core.cache.appendingPathComponent("RPCS3-journal.txt")
                    try? Log.shared.text.write(to: url, atomically: true, encoding: .utf8)
                    sharing = url
                } label: { Label("Partager", systemImage: "square.and.arrow.up") }
            }
        }
    }
}
