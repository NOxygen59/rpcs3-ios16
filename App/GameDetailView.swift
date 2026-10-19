// One game: play it, its savestates, settings, patches, title updates, trophies, caches, and removal.

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Icons decoded once, off the main thread, at the size they are shown, then kept in memory
/// (PS3 icons are 320×176 PNGs; the library shows dozens of them).
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "rpcs3.images", qos: .utility)

    init() { cache.totalCostLimit = 48 << 20 }

    func cached(_ path: String, pixels: Int) -> UIImage? { cache.object(forKey: "\(pixels)|\(path)" as NSString) }

    func load(_ path: String, pixels: Int, done: @escaping (UIImage?) -> Void) {
        let key = "\(pixels)|\(path)" as NSString
        queue.async {
            var image: UIImage?
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, options) {
                let thumb = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                             kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb) {
                    image = UIImage(cgImage: cg)
                    self.cache.setObject(image!, forKey: key, cost: cg.bytesPerRow * cg.height)
                }
            }
            DispatchQueue.main.async { done(image) }
        }
    }
}

struct GameIcon: View {
    let path: String
    var size: CGFloat = 64
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    private var pixels: Int { Int(size * 320 / 176 * scale) }

    var body: some View {
        Group {
            if let image = image ?? ImageCache.shared.cached(path, pixels: pixels) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "gamecontroller.fill").font(.system(size: size * 0.32)).foregroundColor(.white.opacity(0.6))
                }
            }
        }
        // PS3 icons (ICON0.PNG) are 320×176.
        .frame(width: size * 320 / 176, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
        .task(id: path) {
            guard !path.isEmpty, image == nil, ImageCache.shared.cached(path, pixels: pixels) == nil else { return }
            ImageCache.shared.load(path, pixels: pixels) { image = $0 }
        }
    }
}

struct GameDetailView: View {
    let game: Game
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var savestates: [Savestate] = []
    @State private var cache = CacheInfo()
    @State private var installed: [InstalledUpdate] = []
    @State private var confirmDelete = false
    @State private var importingState = false
    @State private var exporting: URL?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    GameIcon(path: game.iconPath, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.title).font(.title3.bold())
                        Text("\(game.titleID) · version \(game.version.isEmpty ? "?" : game.version)").font(.callout).foregroundColor(.secondary)
                        if !game.firmwareVersion.isEmpty {
                            Text("Firmware requis : \(game.firmwareVersion)").font(.caption).foregroundColor(.secondary)
                        }
                        if let size = game.sizeOnDisk {
                            Text(Strings.bytes(size)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Button {
                    app.play(game)
                } label: {
                    Label("Jouer", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!game.bootable)
            }

            Section("Sauvegardes d'état") {
                if savestates.isEmpty {
                    Text("Aucune sauvegarde d'état. Créez-en une depuis le menu de RPCS3 en jeu (bouton PS).").font(.callout).foregroundColor(.secondary)
                }
                ForEach(savestates) { state in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(state.modified.formatted(date: .abbreviated, time: .shortened))
                            Text(Strings.bytes(state.size) + (state.compatible ? "" : " · incompatible avec cette version")).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Charger") { app.play(game, savestate: state.identifier) }
                            .buttonStyle(.bordered)
                            .disabled(!state.compatible)
                    }
                    .contextMenu {
                        Button { duplicate(state) } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
                        Button { export(state) } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { deleteState(state) } label: { Label("Supprimer", systemImage: "trash") }
                    }
                    .swipeActions {
                        Button(role: .destructive) { deleteState(state) } label: { Label("Supprimer", systemImage: "trash") }
                    }
                }
                Button { importingState = true } label: { Label("Importer une sauvegarde d'état…", systemImage: "square.and.arrow.down") }
            }

            Section("Configuration") {
                NavigationLink { SettingsView(scope: .game(game)) } label: { Label("Réglages du jeu", systemImage: "slider.horizontal.3") }
                NavigationLink { PresetsView(game: game) } label: { Label("Préréglages", systemImage: "square.stack.3d.up") }
                NavigationLink { PatchesView(game: game) } label: { Label("Patchs", systemImage: "bandage") }
                NavigationLink { UpdatesView(game: game, installed: installed.first?.version ?? "") { refresh() } } label: {
                    HStack {
                        Label("Mises à jour du jeu", systemImage: "arrow.down.circle")
                        Spacer()
                        if let v = installed.first?.version { Text(v).foregroundColor(.secondary) }
                    }
                }
                NavigationLink { TrophiesView(game: game) } label: { Label("Trophées", systemImage: "trophy") }
            }

            Section("Caches") {
                cacheRow("Shaders", cache.shader, RPCS3_IOS_GAME_CACHE_SHADER)
                cacheRow("PPU", cache.ppu, RPCS3_IOS_GAME_CACHE_PPU)
                cacheRow("SPU", cache.spu, RPCS3_IOS_GAME_CACHE_SPU)
                cacheRow("Données temporaires (dev_hdd1)", cache.hdd1, RPCS3_IOS_GAME_CACHE_HDD1)
                Button(role: .destructive) { clear(RPCS3_IOS_GAME_CACHE_ALL) } label: {
                    Text("Tout vider (\(Strings.bytes(cache.total)))")
                }
                .disabled(cache.total == 0)
            }

            Section {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Supprimer le jeu", systemImage: "trash") }
            }
        }
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .fileImporter(isPresented: $importingState, allowedContentTypes: [.item]) { result in
            if case let .success(url) = result { importState(url) }
        }
        .sheet(item: $exporting) { url in ShareSheet(items: [url]) }
        .confirmationDialog("Supprimer \(game.title) ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                app.delete(game)
                dismiss()
            }
        } message: {
            Text("Le jeu, ses mises à jour et ses caches seront supprimés. Les sauvegardes de jeu sont conservées.")
        }
        .alert("Erreur", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func cacheRow(_ name: String, _ size: UInt64, _ type: rpcs3_ios_game_cache_type) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(Strings.bytes(size)).foregroundColor(.secondary)
            Button("Vider") { clear(type) }.buttonStyle(.borderless).disabled(size == 0)
        }
    }

    private func refresh() {
        let id = game.titleID
        Core.run({ (try Core.savestates(id), (try? Core.cacheInfo(id)) ?? CacheInfo(), (try? Core.installedUpdates(id)) ?? []) }) { result in
            switch result {
            case let .success((s, c, u)):
                savestates = s.sorted { $0.modified > $1.modified }
                cache = c
                installed = u
            case let .failure(e): error = e.localizedDescription
            }
        }
    }

    private func perform(_ work: @escaping () throws -> Void) {
        Core.run(work) { result in
            if case let .failure(e) = result { error = e.localizedDescription }
            refresh()
        }
    }

    private func clear(_ type: rpcs3_ios_game_cache_type) { perform { try Core.clearCache(game.titleID, type) } }
    private func duplicate(_ s: Savestate) { perform { try Core.duplicateSavestate(game.titleID, s.identifier) } }
    private func deleteState(_ s: Savestate) { perform { try Core.deleteSavestate(game.titleID, s.identifier) } }

    private func importState(_ url: URL) {
        // The core reads from its own folders: copy the file into the cache first.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = Core.cache.appendingPathComponent("import-" + url.lastPathComponent)
        try? FileManager.default.createDirectory(at: Core.cache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.copyItem(at: url, to: dest) } catch { self.error = error.localizedDescription; return }
        perform {
            defer { try? FileManager.default.removeItem(at: dest) }
            try Core.importSavestate(game.titleID, from: dest.path)
        }
    }

    private func export(_ s: Savestate) {
        let base = "\(game.titleID)-\(Int(s.modified.timeIntervalSince1970))"
        try? FileManager.default.createDirectory(at: Core.cache, withIntermediateDirectories: true)
        // The export keeps the native extension, which depends on how RPCS3 compressed the state.
        Core.run({ () -> URL in
            var last: Error?
            for suffix in [".SAVESTAT.zst", ".SAVESTAT.gz", ".SAVESTAT"] {
                let dest = Core.cache.appendingPathComponent(base + suffix)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try Core.exportSavestate(game.titleID, s.identifier, to: dest.path)
                    return dest
                } catch {
                    last = error
                    if (error as? CoreError)?.code != RPCS3_IOS_INVALID_ARGUMENT { throw error }
                }
            }
            throw last ?? CoreError.status(RPCS3_IOS_INVALID_ARGUMENT, "")
        }) { result in
            switch result {
            case let .success(url): exporting = url
            case let .failure(e): error = e.localizedDescription
            }
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Presets

private struct PresetsView: View {
    let game: Game
    @State private var presets: [Preset] = []
    @State private var naming: NameRequest?
    @State private var importing = false
    @State private var exporting: URL?
    @State private var error: String?
    @State private var info: String?

    private struct NameRequest: Identifiable {
        let id = UUID()
        let title: String
        var name: String
        let done: (String) -> Void
    }

    var body: some View {
        List {
            Section {
                Button { naming = NameRequest(title: "Enregistrer les réglages actuels", name: "") { save($0) } } label: {
                    Label("Enregistrer les réglages actuels…", systemImage: "plus")
                }
                Button { importing = true } label: { Label("Importer un préréglage…", systemImage: "square.and.arrow.down") }
            } footer: {
                Text("Un préréglage enregistre la configuration du jeu pour la réappliquer plus tard.")
            }
            Section("Préréglages") {
                if presets.isEmpty { Text("Aucun préréglage.").foregroundColor(.secondary) }
                ForEach(presets) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.name)
                            Text(p.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Appliquer") { apply(p) }.buttonStyle(.bordered)
                    }
                    .contextMenu {
                        Button { naming = NameRequest(title: "Renommer", name: p.name) { to in run { try Core.renamePreset(game.titleID, p.name, to) } } } label: { Label("Renommer", systemImage: "pencil") }
                        Button { naming = NameRequest(title: "Dupliquer", name: p.name + " (copie)") { to in run { try Core.duplicatePreset(game.titleID, p.name, to) } } } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
                        Button { export(p) } label: { Label("Exporter", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { run { try Core.deletePreset(game.titleID, p.name) } } label: { Label("Supprimer", systemImage: "trash") }
                    }
                }
            }
        }
        .navigationTitle("Préréglages")
        .onAppear(perform: refresh)
        .sheet(item: $naming) { request in
            NameSheet(title: request.title, name: request.name) { request.done($0) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = Core.cache.appendingPathComponent("preset-import.yml")
            try? FileManager.default.createDirectory(at: Core.cache, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return }
            let name = url.deletingPathExtension().lastPathComponent
            run {
                defer { try? FileManager.default.removeItem(at: dest) }
                try Core.importPreset(game.titleID, from: dest.path, name: name)
            }
        }
        .sheet(item: $exporting) { ShareSheet(items: [$0]) }
        .alert("Erreur", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
        .alert("Préréglages", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) { Button("OK") {} } message: { Text(info ?? "") }
    }

    private func refresh() {
        Core.run({ try Core.presets(game.titleID) }) { result in
            if case let .success(p) = result { presets = p }
        }
    }

    private func run(_ work: @escaping () throws -> Void) {
        Core.run(work) { result in
            if case let .failure(e) = result { error = e.localizedDescription }
            refresh()
        }
    }

    private func save(_ name: String) { run { try Core.savePreset(game.titleID, name) } }

    private func apply(_ p: Preset) {
        Core.run({ try Core.applyPreset(game.titleID, p.name) }) { result in
            switch result {
            case .success: info = "« \(p.name) » est maintenant la configuration du jeu."
            case let .failure(e): error = e.localizedDescription
            }
        }
    }

    private func export(_ p: Preset) {
        let dest = Core.cache.appendingPathComponent("\(game.titleID) - \(p.name).yml")
        try? FileManager.default.createDirectory(at: Core.cache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        Core.run({ try Core.exportPreset(game.titleID, p.name, to: dest.path) }) { result in
            switch result {
            case .success: exporting = dest
            case let .failure(e): error = e.localizedDescription
            }
        }
    }
}

struct NameSheet: View {
    let title: String
    @State var name: String
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { TextField("Nom", text: $name) }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") { done(name.trimmingCharacters(in: .whitespaces)); dismiss() }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Patches

private struct PatchesView: View {
    let game: Game
    @State private var patches: [RuntimePatch] = []
    @State private var loading = true
    @State private var refreshing = false
    @State private var status: String?

    var body: some View {
        List {
            Section {
                Button {
                    refreshRepository()
                } label: {
                    HStack {
                        Label("Mettre à jour les patchs", systemImage: "arrow.clockwise")
                        if refreshing { Spacer(); ProgressView() }
                    }
                }
                .disabled(refreshing)
            } footer: {
                if let status { Text(status) }
            }
            if !loading && patches.isEmpty {
                Text("Aucun patch pour ce jeu et cette version.").foregroundColor(.secondary)
            }
            let groups = Dictionary(grouping: patches, by: { $0.group.isEmpty ? $0.title : $0.group })
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Section(group) {
                    ForEach(groups[group] ?? []) { patch in
                        Toggle(isOn: Binding(get: { patch.enabled }, set: { set(patch, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(patch.detail.isEmpty ? patch.title : patch.detail)
                                let meta = [patch.author.isEmpty ? nil : "par \(patch.author)", patch.patchVersion.isEmpty ? nil : "v\(patch.patchVersion)", patch.appVersion.isEmpty ? nil : "jeu \(patch.appVersion)"].compactMap { $0 }
                                if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.caption).foregroundColor(.secondary) }
                                if !patch.notes.isEmpty { Text(patch.notes).font(.caption2).foregroundColor(.secondary) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Patchs")
        .onAppear(perform: load)
    }

    private func load() {
        Core.run({ try Core.runtimePatches(game.titleID, appVersion: game.version) }) { result in
            loading = false
            switch result {
            case let .success(p): patches = p
            case let .failure(e): status = e.localizedDescription
            }
        }
    }

    private func set(_ patch: RuntimePatch, _ on: Bool) {
        Core.run({ try Core.setRuntimePatch(game.titleID, patch, enabled: on) }) { result in
            if case let .failure(e) = result { status = e.localizedDescription }
            load()
        }
    }

    private func refreshRepository() {
        refreshing = true
        Task {
            do {
                switch try await Online.refreshPatches() {
                case .updated: status = "Patchs mis à jour."
                case .upToDate: status = "Les patchs sont déjà à jour."
                }
            } catch {
                status = error.localizedDescription
            }
            refreshing = false
            load()
        }
    }
}

// MARK: - Title updates

private struct UpdatesView: View {
    let game: Game
    let installed: String
    let changed: () -> Void
    @State private var packages: [Online.UpdatePackage] = []
    @State private var loading = true
    @State private var progress: (String, Double)?
    @State private var status: String?
    @State private var importing = false
    @EnvironmentObject private var app: AppModel

    private var pending: [Online.UpdatePackage] {
        packages.filter { installed.isEmpty || $0.version.compare(installed, options: .numeric) == .orderedDescending }
    }

    var body: some View {
        List {
            Section {
                HStack { Text("Version installée"); Spacer(); Text(installed.isEmpty ? game.version : installed).foregroundColor(.secondary) }
            }
            Section("Disponibles chez Sony") {
                if loading { ProgressView() }
                if !loading && packages.isEmpty { Text("Aucune mise à jour pour ce jeu.").foregroundColor(.secondary) }
                ForEach(packages) { p in
                    HStack {
                        Text("Version \(p.version)")
                        Spacer()
                        Text(Strings.bytes(p.size)).foregroundColor(.secondary)
                        if !pending.contains(p) { Image(systemName: "checkmark").foregroundColor(.green) }
                    }
                }
                if let progress {
                    VStack(alignment: .leading) {
                        Text(progress.0).font(.callout)
                        ProgressView(value: progress.1)
                    }
                } else if !pending.isEmpty {
                    Button { install() } label: {
                        Label("Installer \(pending.count == 1 ? "la mise à jour" : "les \(pending.count) mises à jour")", systemImage: "arrow.down.circle.fill")
                    }
                }
            }
            Section {
                Button { importing = true } label: { Label("Installer un PKG de mise à jour…", systemImage: "folder") }
            } footer: {
                if let status { Text(status) }
            }
        }
        .navigationTitle("Mises à jour")
        .task { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            progress = ("Installation de \(url.lastPathComponent)", 0)
            Core.run({
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try Core.installGameUpdate(titleID: game.titleID, path: url.path) { done, total, _ in
                    DispatchQueue.main.async { progress = ("Installation de \(url.lastPathComponent)", total > 0 ? Double(done) / Double(total) : 0) }
                }
            }) { result in
                progress = nil
                switch result {
                case .success: status = "Mise à jour installée."; changed(); app.reload()
                case let .failure(e): status = e.localizedDescription
                }
            }
        }
    }

    private func load() async {
        do { packages = try await Online.updatePackages(game.titleID) } catch { status = error.localizedDescription }
        loading = false
    }

    private func install() {
        let todo = pending
        progress = ("Préparation…", 0)
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            do {
                try await Online.installUpdates(game.titleID, packages: todo, installed: installed) { stage, f in progress = (stage, f) }
                status = "Mises à jour installées."
                changed()
                app.reload()
            } catch {
                status = error.localizedDescription
            }
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - Trophies

private struct TrophiesView: View {
    let game: Game
    @State private var trophies: [Trophy] = []
    @State private var message: String?

    private static let grades = [1: ("Platine", Color(red: 0.75, green: 0.85, blue: 0.95)), 2: ("Or", .yellow), 3: ("Argent", Color(white: 0.75)), 4: ("Bronze", .brown)]

    var body: some View {
        List {
            if !trophies.isEmpty {
                let earned = trophies.filter(\.earned).count
                Section {
                    VStack(alignment: .leading) {
                        Text("\(earned) sur \(trophies.count) obtenus")
                        ProgressView(value: Double(earned), total: Double(trophies.count))
                    }
                }
            }
            if let message { Text(message).foregroundColor(.secondary) }
            ForEach(trophies) { t in
                HStack(spacing: 12) {
                    TrophyIcon(path: t.iconPath)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(t.earned ? 1 : 0.35)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.hidden && !t.earned ? "Trophée caché" : t.name).font(.headline)
                        if !(t.hidden && !t.earned) { Text(t.detail).font(.caption).foregroundColor(.secondary) }
                        if let date = t.unlocked, t.earned { Text("Obtenu le \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundColor(.secondary) }
                    }
                    Spacer()
                    if let g = Self.grades[Int(t.grade)] {
                        Image(systemName: "trophy.fill").foregroundColor(g.1).help(g.0)
                    }
                }
            }
        }
        .navigationTitle("Trophées")
        .onAppear {
            Core.run({ try Core.trophies(game.titleID) }) { result in
                switch result {
                case let .success(r):
                    trophies = r.list.sorted { $0.order < $1.order }
                    if r.list.isEmpty { message = "Aucun trophée : lancez le jeu une première fois." }
                case .failure: message = "Aucun trophée : lancez le jeu une première fois."
                }
            }
        }
    }
}

private struct TrophyIcon: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                Image(systemName: "trophy.fill").resizable().scaledToFit().padding(10)
            }
        }
        .frame(width: 52, height: 52)
        .task(id: path) {
            guard !path.isEmpty else { return }
            if let hit = ImageCache.shared.cached(path, pixels: 156) { image = hit; return }
            ImageCache.shared.load(path, pixels: 156) { image = $0 }
        }
    }
}
