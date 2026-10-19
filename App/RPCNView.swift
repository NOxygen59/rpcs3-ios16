// RPCN, RPCS3's online service: account, server, and friends. The core keeps the password only in
// memory, so the app stores it in the Keychain and hands it back at every launch.

import Security
import SwiftUI

enum RPCNKeychain {
    private static let service = "rpcs3.rpcn"

    struct Credentials: Codable {
        var username: String
        var password: String
        var token: String
        var ipv6: Bool
    }

    static func load() -> Credentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return try? JSONDecoder().decode(Credentials.self, from: data)
        }
        // Without Keychain access (unusual signing), a protected file in the app's own folder.
        guard let data = try? Data(contentsOf: fallback) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ c: Credentials) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
            try? data.write(to: fallback, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            try? FileManager.default.removeItem(at: fallback)
        }
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        try? FileManager.default.removeItem(at: fallback)
    }

    private static var fallback: URL { Core.appSupport.appendingPathComponent(".rpcn-credentials") }

    /// Called once the core is up.
    static func restore() {
        guard let c = load() else { return }
        try? Core.setRPCNCredentials(username: c.username, password: c.password, token: c.token, ipv6: c.ipv6)
    }
}

struct RPCNView: View {
    @State private var config = RPCNConfig()
    @State private var servers: [RPCNServer] = []
    @State private var contacts: [RPCNContact] = []
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var email = ""
    @State private var ipv6 = false
    @State private var busy = false
    @State private var status: String?
    @State private var addingServer = false
    @State private var newServerName = ""
    @State private var newServerHost = ""
    @State private var friendName = ""
    @State private var confirmDelete = false
    @State private var resetToken = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Circle().fill(config.authenticated ? Color.green : config.connected ? .orange : .gray).frame(width: 10, height: 10)
                    Text(config.authenticated ? "Connecté en tant que \(config.onlineName.isEmpty ? config.username : config.onlineName)"
                         : config.hasPassword ? "Compte configuré" : "Aucun compte")
                }
            } footer: {
                Text("Pour jouer en ligne, activez aussi Réglages › Réseau › État du réseau « Connected » et État du PSN « RPCN ».")
            }

            Section("Compte") {
                TextField("Nom d'utilisateur", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Mot de passe", text: $password)
                TextField("Jeton (reçu par e-mail)", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("IPv6", isOn: $ipv6)
                Button("Enregistrer et tester") { saveAndTest() }
                    .disabled(username.isEmpty || password.isEmpty || busy)
            }

            Section {
                TextField("Adresse e-mail", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Créer le compte") {
                    run("Compte créé : un jeton a été envoyé par e-mail. Saisissez-le puis touchez « Enregistrer et tester ».") {
                        try Core.createRPCNAccount(username: username, password: password, email: email)
                    }
                }
                .disabled(username.isEmpty || password.isEmpty || email.isEmpty || busy)
                Button("Renvoyer le jeton") { run("Jeton renvoyé par e-mail.") { try Core.resendRPCNToken() } }
                    .disabled(!config.hasPassword || busy)
                Button("Mot de passe oublié") {
                    run("Un code de réinitialisation a été envoyé par e-mail.") { try Core.requestRPCNPasswordReset(username: username, email: email) }
                }
                .disabled(username.isEmpty || email.isEmpty || busy)
                if !resetToken.isEmpty || !email.isEmpty {
                    TextField("Code de réinitialisation", text: $resetToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Définir le nouveau mot de passe") {
                        run("Mot de passe changé.") { try Core.resetRPCNPassword(username: username, token: resetToken, password: password) }
                    }
                    .disabled(resetToken.isEmpty || password.isEmpty || busy)
                }
            } header: {
                Text("Nouveau compte")
            } footer: {
                Text("Pour créer un compte, remplissez nom d'utilisateur, mot de passe et e-mail ci-dessus.")
            }

            Section("Serveur") {
                ForEach(servers) { s in
                    Button {
                        run(nil) { try Core.setRPCNServer(s.host) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.description).foregroundColor(.primary)
                                Text(s.host).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if s.selected { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                    }
                    .swipeActions {
                        if s.removable {
                            Button(role: .destructive) { run(nil) { try Core.removeRPCNServer(s.description, s.host) } } label: { Label("Supprimer", systemImage: "trash") }
                        }
                    }
                }
                if addingServer {
                    TextField("Nom", text: $newServerName)
                    TextField("Adresse (hôte:port)", text: $newServerHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Ajouter") {
                        let (n, h) = (newServerName, newServerHost)
                        run(nil) { try Core.addRPCNServer(n, h) }
                        addingServer = false
                        newServerName = ""
                        newServerHost = ""
                    }
                    .disabled(newServerName.isEmpty || newServerHost.isEmpty)
                } else {
                    Button("Ajouter un serveur…") { addingServer = true }
                }
            }

            Section {
                if contacts.isEmpty { Text("Aucun contact. La liste se remplit pendant qu'un jeu en ligne tourne.").foregroundColor(.secondary) }
                ForEach(contacts) { c in
                    HStack {
                        Circle().fill(c.online ? Color.green : .gray).frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(c.username)
                            let detail = [kindLabel(c.kind), c.presenceTitle, c.presenceStatus].filter { !$0.isEmpty }.joined(separator: " · ")
                            if !detail.isEmpty { Text(detail).font(.caption).foregroundColor(.secondary) }
                        }
                        Spacer()
                        contactActions(c)
                    }
                }
                HStack {
                    TextField("Ajouter un ami", text: $friendName).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Envoyer") {
                        let name = friendName
                        run("Demande envoyée.") { try Core.rpcnSocial(RPCS3_IOS_RPCN_SOCIAL_ADD_FRIEND, name) }
                        friendName = ""
                    }
                    .disabled(friendName.isEmpty)
                }
            } header: {
                Text("Amis")
            } footer: {
                Text("La gestion des amis n'est possible que pendant qu'un jeu est lancé.")
            }

            if config.hasPassword {
                Section {
                    Button("Supprimer le compte RPCN", role: .destructive) { confirmDelete = true }
                }
            }

            if let status {
                Section { Text(status).font(.callout) }
            }
        }
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .navigationTitle("RPCN")
        .onAppear(perform: load)
        .confirmationDialog("Supprimer définitivement le compte RPCN ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                run("Compte supprimé.") {
                    try Core.deleteRPCNAccount()
                    RPCNKeychain.clear()
                }
            }
        }
    }

    private func kindLabel(_ kind: UInt32) -> String {
        switch kind {
        case RPCS3_IOS_RPCN_SOCIAL_FRIEND.rawValue: return "Ami"
        case RPCS3_IOS_RPCN_SOCIAL_REQUEST_RECEIVED.rawValue: return "Demande reçue"
        case RPCS3_IOS_RPCN_SOCIAL_REQUEST_SENT.rawValue: return "Demande envoyée"
        case RPCS3_IOS_RPCN_SOCIAL_BLOCKED.rawValue: return "Bloqué"
        case RPCS3_IOS_RPCN_SOCIAL_RECENT_PLAYER.rawValue: return "Joueur récent"
        default: return ""
        }
    }

    @ViewBuilder private func contactActions(_ c: RPCNContact) -> some View {
        let name = c.username
        Menu {
            switch c.kind {
            case RPCS3_IOS_RPCN_SOCIAL_FRIEND.rawValue:
                Button("Retirer des amis", role: .destructive) { run(nil) { try Core.rpcnSocial(RPCS3_IOS_RPCN_SOCIAL_REMOVE_FRIEND, name) } }
            case RPCS3_IOS_RPCN_SOCIAL_REQUEST_RECEIVED.rawValue:
                Button("Accepter") { run(nil) { try Core.rpcnSocial(RPCS3_IOS_RPCN_SOCIAL_ACCEPT_REQUEST, name) } }
                Button("Refuser") { run(nil) { try Core.rpcnSocial(RPCS3_IOS_RPCN_SOCIAL_REJECT_REQUEST, name) } }
            case RPCS3_IOS_RPCN_SOCIAL_REQUEST_SENT.rawValue:
                Button("Annuler la demande") { run(nil) { try Core.rpcnSocial(RPCS3_IOS_RPCN_SOCIAL_CANCEL_REQUEST, name) } }
            case RPCS3_IOS_RPCN_SOCIAL_BLOCKED.rawValue:
                Button("Débloquer") { run(nil) { try Core.rpcnSocial(RPCS3_IOS_RPCN_SOCIAL_UNBLOCK_USER, name) } }
            default:
                Button("Ajouter en ami") { run(nil) { try Core.rpcnSocial(RPCS3_IOS_RPCN_SOCIAL_ADD_FRIEND, name) } }
            }
            if c.kind != RPCS3_IOS_RPCN_SOCIAL_BLOCKED.rawValue {
                Button("Bloquer", role: .destructive) { run(nil) { try Core.rpcnSocial(RPCS3_IOS_RPCN_SOCIAL_BLOCK_USER, name) } }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private func load() {
        if let saved = RPCNKeychain.load() {
            username = saved.username
            password = saved.password
            token = saved.token
            ipv6 = saved.ipv6
        }
        Core.run({ (try Core.rpcnConfig(), (try? Core.rpcnServers()) ?? [], (try? Core.rpcnContacts()) ?? []) }) { result in
            if case let .success((c, s, f)) = result {
                config = c
                servers = s
                contacts = f
                if username.isEmpty { username = c.username }
                if !c.hasPassword { ipv6 = c.ipv6 }
            }
        }
    }

    private func run(_ success: String?, _ work: @escaping () throws -> Void) {
        busy = true
        Core.run(work) { result in
            busy = false
            switch result {
            case .success: status = success
            case let .failure(e): status = e.localizedDescription
            }
            load()
        }
    }

    private func saveAndTest() {
        let c = RPCNKeychain.Credentials(username: username, password: password, token: token, ipv6: ipv6)
        RPCNKeychain.save(c)
        run("Connexion à RPCN réussie.") {
            try Core.setRPCNCredentials(username: c.username, password: c.password, token: c.token, ipv6: c.ipv6)
            try Core.testRPCNAccount()
        }
    }
}
