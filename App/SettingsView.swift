// RPCS3's settings, global or for one game, drawn from what the core describes: a toggle, a stepper
// or slider, a menu of choices, or a text field per setting, grouped by category and section.

import SwiftUI

/// Where the settings come from and go to.
enum SettingsScope: Equatable {
    case global
    case game(Game)
}

@MainActor
final class SettingsModel: ObservableObject {
    let scope: SettingsScope
    @Published var settings: [Setting] = []
    @Published var custom = false
    @Published var loading = true
    @Published var error: String?
    /// A change is on its way to the core: further taps wait for it (the list then shows the
    /// value the core actually kept).
    @Published private(set) var busy = false

    init(_ scope: SettingsScope) { self.scope = scope }

    var categories: [String] {
        let present = Set(settings.map(\.category))
        return SettingNames.categoryOrder.filter(present.contains) + present.subtracting(SettingNames.categoryOrder).sorted()
    }

    func load() {
        let scope = scope
        Core.run({ () -> ([Setting], Bool) in
            switch scope {
            case .global: return (try Core.settings(), false)
            case let .game(g): return try Core.gameSettings(g.titleID)
            }
        }) { result in
            self.loading = false
            switch result {
            case let .success((list, custom)):
                self.settings = list
                self.custom = custom
            case let .failure(e): self.error = e.localizedDescription
            }
        }
    }

    func set(_ setting: Setting, _ value: String) {
        guard value != setting.value, !busy else { return }
        busy = true
        error = nil
        Diagnostics.event("Modification demandée : \(setting.key) = \(value)")
        let scope = scope
        Core.run({
            func apply() throws {
                switch scope {
                case .global: try Core.setSetting(setting.key, value)
                case let .game(g): try Core.setGameSetting(g.titleID, setting.key, value)
                }
            }
            do {
                try apply()
            } catch let error as CoreError where error.code == RPCS3_IOS_INVALID_STATE {
                // Settings only change with emulation stopped. No game is on screen here (the
                // settings are reached from the home screen), so what is left is a session that
                // didn't fully end: stop it, then try once more.
                let state = Core.emulationState
                guard state != RPCS3_IOS_EMULATION_STATE_RUNNING, state != RPCS3_IOS_EMULATION_STATE_PAUSED else { throw error }
                Diagnostics.event("Réglage refusé (état \(state.rawValue)) : arrêt de l'émulation restante, puis nouvel essai")
                try? Core.stop()
                try apply()
            }
        }) { result in
            let target: String
            switch scope {
            case .global: target = "global"
            case let .game(g): target = g.titleID
            }
            switch result {
            case .success: Diagnostics.event("Réglage \(target) : \(setting.key) = \(value) (était \(setting.value))")
            case let .failure(e):
                Diagnostics.event("Réglage \(target) : \(setting.key) = \(value) refusé : \(e.localizedDescription)")
                self.error = e.localizedDescription
            }
            // Some settings change what others allow: reload all of them.
            self.busy = false
            self.load()
        }
    }

    func reset() {
        let scope = scope
        Core.run({
            switch scope {
            case .global: try Core.resetSettings()
            case let .game(g): try Core.resetGameSettings(g.titleID)
            }
        }) { result in
            if case let .failure(e) = result { self.error = e.localizedDescription }
            self.load()
        }
    }

    func useGlobal() {
        guard case let .game(g) = scope else { return }
        Core.run({ try Core.removeGameSettings(g.titleID) }) { result in
            if case let .failure(e) = result { self.error = e.localizedDescription }
            self.load()
        }
    }
}

struct SettingsView: View {
    @StateObject private var model: SettingsModel
    @State private var search = ""
    @State private var confirmReset = false
    @State private var confirmGlobal = false

    init(scope: SettingsScope) {
        _model = StateObject(wrappedValue: SettingsModel(scope))
    }

    var body: some View {
        List {
            SettingsErrorBanner(model: model)
            if model.loading {
                HStack { Spacer(); ProgressView("Chargement des réglages…"); Spacer() }
            }
            if case .game = model.scope {
                Section {
                    Label(model.custom ? "Ce jeu a sa propre configuration." : "Ce jeu utilise les réglages globaux. La première modification crée sa configuration.",
                          systemImage: model.custom ? "slider.horizontal.below.square.filled.and.square" : "globe")
                        .font(.callout)
                    if model.custom {
                        Button("Utiliser les réglages globaux", role: .destructive) { confirmGlobal = true }
                    }
                }
            }
            if search.isEmpty {
                Section {
                    ForEach(model.categories, id: \.self) { category in
                        NavigationLink {
                            SettingsCategoryView(model: model, category: category)
                        } label: {
                            Label(SettingNames.category(category), systemImage: SettingNames.categoryIcons[category] ?? "gearshape")
                        }
                    }
                }
            } else {
                let matches = model.settings.filter {
                    SettingNames.name($0).localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search)
                }
                ForEach(matches) { SettingRow(setting: $0, model: model) }
            }
            Section {
                Button("Rétablir les valeurs par défaut", role: .destructive) { confirmReset = true }
            } footer: {
                if case .game = model.scope {
                    Text("« Rétablir » garde une configuration propre au jeu avec les valeurs d'origine de RPCS3. « Utiliser les réglages globaux » la supprime.")
                }
            }
        }
        .searchable(text: $search, prompt: "Rechercher un réglage")
        .navigationTitle(title)
        .onAppear { if model.settings.isEmpty { model.load() } }
        .confirmationDialog("Rétablir tous les réglages ?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Rétablir", role: .destructive) { model.reset() }
        }
        .confirmationDialog("Utiliser les réglages globaux ?", isPresented: $confirmGlobal, titleVisibility: .visible) {
            Button("Supprimer la configuration du jeu", role: .destructive) { model.useGlobal() }
        } message: {
            Text("RPCS3 utilisera les réglages globaux au prochain lancement.")
        }
    }

    private var title: String {
        switch model.scope {
        case .global: return "Réglages"
        case let .game(g): return "Réglages de \(g.title)"
        }
    }
}

private struct SettingsCategoryView: View {
    @ObservedObject var model: SettingsModel
    let category: String

    var body: some View {
        let settings = model.settings.filter { $0.category == category }
        var sections: [String] = []
        for s in settings where !sections.contains(s.section) { sections.append(s.section) }
        return List {
            SettingsErrorBanner(model: model)
            ForEach(sections, id: \.self) { section in
                Section(SettingNames.section(section)) {
                    ForEach(settings.filter { $0.section == section }) { SettingRow(setting: $0, model: model) }
                }
            }
        }
        .navigationTitle(SettingNames.category(category))
    }
}

private struct SettingRow: View {
    let setting: Setting
    @ObservedObject var model: SettingsModel
    @State private var text = ""
    @State private var number = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            Text(SettingNames.detail(setting)).font(.caption).foregroundColor(.secondary)
            if let r = setting.recommended, !r.isEmpty, r != setting.value {
                Button {
                    model.set(setting, r)
                } label: {
                    Label("Recommandé pour ce jeu : \(label(for: r))", systemImage: "star.fill").font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func label(for value: String) -> String {
        if setting.kind == RPCS3_IOS_SETTING_BOOLEAN { return value == "true" ? "activé" : "désactivé" }
        return setting.options.first { $0.value == value }?.label ?? value
    }

    @ViewBuilder private var control: some View {
        let name = SettingNames.name(setting)
        switch setting.kind {
        case RPCS3_IOS_SETTING_BOOLEAN:
            Toggle(name, isOn: Binding(get: { setting.value == "true" }, set: { model.set(setting, $0 ? "true" : "false") }))
        case RPCS3_IOS_SETTING_CHOICE:
            Picker(name, selection: Binding(get: { setting.value }, set: { model.set(setting, $0) })) {
                ForEach(setting.options, id: \.value) { Text($0.label).tag($0.value) }
                if !setting.options.contains(where: { $0.value == setting.value }) {
                    Text(setting.value).tag(setting.value)
                }
            }
            .pickerStyle(.menu)
        case RPCS3_IOS_SETTING_INTEGER, RPCS3_IOS_SETTING_DECIMAL:
            numeric(name)
        default:
            HStack {
                Text(name)
                Spacer()
                TextField(setting.defaultValue, text: $text)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { model.set(setting, text) }
                    .frame(maxWidth: 260)
            }
            .onAppear { text = setting.value }
        }
    }

    @ViewBuilder private func numeric(_ name: String) -> some View {
        let decimal = setting.kind == RPCS3_IOS_SETTING_DECIMAL
        let step = setting.step > 0 ? setting.step : 1
        let range = setting.minimum...max(setting.maximum, setting.minimum)
        let current = Double(setting.value) ?? 0
        let format: (Double) -> String = { decimal ? String(format: "%g", $0) : String(Int64($0.rounded())) }
        // Wide ranges get a slider; short ones a stepper.
        if (range.upperBound - range.lowerBound) / step > 40 {
            VStack(alignment: .leading) {
                HStack {
                    Text(name)
                    Spacer()
                    Text(format(number)).monospacedDigit().foregroundColor(.secondary)
                }
                Slider(value: $number, in: range, step: step) { editing in
                    if !editing { model.set(setting, format(number)) }
                }
            }
            .onAppear { number = current }
            .onChange(of: setting.value) { number = Double($0) ?? 0 }
        } else {
            Stepper(value: Binding(get: { current }, set: { model.set(setting, format(min(max($0, range.lowerBound), range.upperBound))) }),
                    in: range, step: step) {
                HStack {
                    Text(name)
                    Spacer()
                    Text(format(current)).monospacedDigit().foregroundColor(.secondary)
                }
            }
        }
    }
}

/// A refused change, shown at the top of the list that is on screen. (An alert attached to the
/// settings root while a category page was pushed over it could lock the whole interface.)
private struct SettingsErrorBanner: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if let error = model.error {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(error).font(.callout)
                    Spacer()
                    Button("OK") { model.error = nil }.buttonStyle(.borderless)
                }
            }
        }
    }
}
