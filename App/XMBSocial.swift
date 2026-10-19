// The PS3's Users and Friends categories, for nostalgia: local profiles (one is signed in, shown
// in the top-right corner) and pretend friends, each online, offline or invisible. Nothing here
// talks to a server; RPCN (real online play) is under PlayStation Network.

import SwiftUI

/// The avatar colours, as the PS3's default user icons came in a few hues.
enum XMBAvatar {
    static let colors: [Color] = [
        Color(red: 0.25, green: 0.52, blue: 0.95), Color(red: 0.92, green: 0.35, blue: 0.35),
        Color(red: 0.30, green: 0.75, blue: 0.45), Color(red: 0.95, green: 0.70, blue: 0.20),
        Color(red: 0.62, green: 0.40, blue: 0.90), Color(red: 0.20, green: 0.75, blue: 0.80),
        Color(red: 0.95, green: 0.50, blue: 0.75), Color(white: 0.55),
    ]
    static let symbols = ["person.fill", "gamecontroller.fill", "star.fill", "bolt.fill", "flame.fill",
                          "leaf.fill", "moon.stars.fill", "music.note", "crown.fill", "hare.fill"]

    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

/// A round avatar, with an optional presence dot.
struct XMBAvatarView: View {
    let colorIndex: Int
    let symbol: String
    var size: CGFloat = 46
    var status: XMBFriend.Status?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(LinearGradient(colors: [XMBAvatar.color(colorIndex), XMBAvatar.color(colorIndex).opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: symbol).font(.system(size: size * 0.45, weight: .semibold)).foregroundColor(.white)
            }
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            if let status {
                Circle()
                    .fill(status.color)
                    .frame(width: size * 0.28, height: size * 0.28)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1.5))
                    .offset(x: size * 0.06, y: size * 0.06)
            }
        }
    }
}

struct XMBProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var colorIndex: Int
    var symbol: String
}

struct XMBFriend: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case online, offline, invisible

        var label: String {
            switch self {
            case .online: return "En ligne"
            case .offline: return "Hors ligne"
            case .invisible: return "Invisible"
            }
        }

        var color: Color {
            switch self {
            case .online: return .green
            case .offline: return Color(white: 0.55)
            case .invisible: return Color(white: 0.3)
            }
        }
    }

    var id = UUID()
    var name: String
    var status: Status
    var colorIndex: Int
    var symbol: String
    /// What they're "playing" when online.
    var activity: String
}

/// Profiles and friends, saved in the user defaults.
@MainActor
final class XMBSocial: ObservableObject {
    @Published var profiles: [XMBProfile] { didSet { save() } }
    @Published var currentProfile: UUID? { didSet { save() } }
    @Published var friends: [XMBFriend] { didSet { save() } }

    private static let key = "rpcs3.xmb.social"

    private struct Stored: Codable {
        var profiles: [XMBProfile]
        var currentProfile: UUID?
        var friends: [XMBFriend]
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            profiles = stored.profiles
            currentProfile = stored.currentProfile
            friends = stored.friends
        } else {
            let first = XMBProfile(name: "Joueur 1", colorIndex: 0, symbol: "person.fill")
            profiles = [first]
            currentProfile = first.id
            friends = [
                XMBFriend(name: "Kratos_Spartan", status: .online, colorIndex: 1, symbol: "flame.fill", activity: "God of War III"),
                XMBFriend(name: "Nathan_Drake", status: .offline, colorIndex: 3, symbol: "star.fill", activity: ""),
            ]
        }
    }

    var signedIn: XMBProfile? { profiles.first { $0.id == currentProfile } ?? profiles.first }

    private func save() {
        let stored = Stored(profiles: profiles, currentProfile: currentProfile, friends: friends)
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func upsert(_ profile: XMBProfile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile } else { profiles.append(profile) }
    }

    func delete(_ profile: XMBProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if currentProfile == profile.id { currentProfile = profiles.first?.id }
    }

    func upsert(_ friend: XMBFriend) {
        if let i = friends.firstIndex(where: { $0.id == friend.id }) { friends[i] = friend } else { friends.append(friend) }
    }

    func delete(_ friend: XMBFriend) {
        friends.removeAll { $0.id == friend.id }
    }
}

// MARK: - Editors

/// Create or edit a user: name and avatar.
struct XMBProfileEditor: View {
    @ObservedObject var social: XMBSocial
    @State var profile: XMBProfile
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    XMBAvatarView(colorIndex: profile.colorIndex, symbol: profile.symbol, size: 84)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                TextField("Nom de l'utilisateur", text: $profile.name)
            }
            Section("Avatar") { AvatarPicker(colorIndex: $profile.colorIndex, symbol: $profile.symbol) }
            if !isNew {
                Section {
                    if social.currentProfile != profile.id {
                        Button("Se connecter avec cet utilisateur") {
                            social.upsert(profile)
                            social.currentProfile = profile.id
                            dismiss()
                        }
                    }
                    if social.profiles.count > 1 {
                        Button("Supprimer l'utilisateur", role: .destructive) {
                            social.delete(profile)
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Nouvel utilisateur" : profile.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer") {
                    social.upsert(profile)
                    if isNew { social.currentProfile = profile.id }
                    dismiss()
                }
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Create or edit a friend: name, avatar, presence and what they're playing.
struct XMBFriendEditor: View {
    @ObservedObject var social: XMBSocial
    @State var friend: XMBFriend
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    XMBAvatarView(colorIndex: friend.colorIndex, symbol: friend.symbol, size: 84, status: friend.status)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                TextField("Nom en ligne", text: $friend.name)
                Picker("Statut", selection: $friend.status) {
                    ForEach(XMBFriend.Status.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if friend.status == .online {
                    TextField("Joue à… (facultatif)", text: $friend.activity)
                }
            } footer: {
                Text("Pour la nostalgie : ces amis n'existent que sur cet iPad. Invisible : connecté, mais affiché hors ligne pour les autres. Pour de vrais amis en ligne, voir PlayStation Network › RPCN.")
            }
            Section("Avatar") { AvatarPicker(colorIndex: $friend.colorIndex, symbol: $friend.symbol) }
            if !isNew {
                Section {
                    Button("Supprimer cet ami", role: .destructive) {
                        social.delete(friend)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "Ajouter un ami" : friend.name)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer") {
                    social.upsert(friend)
                    dismiss()
                }
                .disabled(friend.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

private struct AvatarPicker: View {
    @Binding var colorIndex: Int
    @Binding var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ForEach(XMBAvatar.colors.indices, id: \.self) { i in
                    Circle().fill(XMBAvatar.color(i)).frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: i == colorIndex ? 3 : 0))
                        .onTapGesture { colorIndex = i }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 5), spacing: 10) {
                ForEach(XMBAvatar.symbols, id: \.self) { name in
                    Image(systemName: name)
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(name == symbol ? 0.22 : 0.06)))
                        .onTapGesture { symbol = name }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Category icons

/// The bar's icons, in the PS3's style: plain white glyphs. Users and Settings are drawn here
/// (the console's silhouette and toolbox); the others are system symbols, the PlayStation logo
/// included (Apple's SF Symbols ships it).
enum XMBCategoryIcon {
    case users, settings, game, network, psn, friends

    @ViewBuilder func view(size: CGFloat) -> some View {
        switch self {
        case .users: UserSilhouette().fill(Color.white).frame(width: size * 0.82, height: size)
        case .settings: Toolbox().frame(width: size, height: size * 0.82)
        case .game: Image(systemName: "gamecontroller.fill").font(.system(size: size * 0.82))
        case .network: Image(systemName: "globe").font(.system(size: size * 0.86, weight: .light))
        case .psn: Image(systemName: "playstation.logo").font(.system(size: size * 0.86))
        case .friends: Image(systemName: "person.2.fill").font(.system(size: size * 0.72))
        }
    }
}

/// A head and shoulders, as on the PS3's Users icon.
private struct UserSilhouette: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let head = r.width * 0.46
        p.addEllipse(in: CGRect(x: r.midX - head / 2, y: r.minY, width: head, height: head))
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY + head * 1.08),
                   control1: CGPoint(x: r.minX, y: r.minY + head * 1.35), control2: CGPoint(x: r.midX - r.width * 0.3, y: r.minY + head * 1.08))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.maxY),
                   control1: CGPoint(x: r.midX + r.width * 0.3, y: r.minY + head * 1.08), control2: CGPoint(x: r.maxX, y: r.minY + head * 1.35))
        p.closeSubpath()
        return p
    }
}

/// A toolbox, as on the PS3's Settings icon.
private struct Toolbox: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                // Handle.
                RoundedRectangle(cornerRadius: h * 0.08)
                    .stroke(Color.white, lineWidth: h * 0.09)
                    .frame(width: w * 0.42, height: h * 0.34)
                    .position(x: w / 2, y: h * 0.2)
                // Box, with its lid line and latch.
                RoundedRectangle(cornerRadius: h * 0.1)
                    .fill(Color.white)
                    .frame(width: w, height: h * 0.66)
                    .position(x: w / 2, y: h * 0.67)
                Rectangle().fill(Color.black.opacity(0.35))
                    .frame(width: w, height: h * 0.05)
                    .position(x: w / 2, y: h * 0.56)
                RoundedRectangle(cornerRadius: h * 0.03).fill(Color.black.opacity(0.35))
                    .frame(width: w * 0.16, height: h * 0.14)
                    .position(x: w / 2, y: h * 0.6)
            }
        }
    }
}
