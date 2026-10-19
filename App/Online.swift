// What the core leaves to the app on the network: RPCS3's title configuration database, the Patch
// Engine repository (HTTPS + JSON), and PS3 title updates (the core fetches Sony's manifest and the
// packages over its own TLS; the app reads the manifest and picks the packages).

import Foundation

enum Online {
    // MARK: Title configuration database

    /// RPCS3's per-title recommended settings, refreshed at most once a day.
    static func refreshConfigDatabase(force: Bool = false) async throws {
        let key = "rpcs3.configdb.updated"
        if !force, let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        guard let url = URL(string: "https://api.rpcs3.net/config/?api=v1") else { return }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CoreError.status(RPCS3_IOS_NETWORK_ERROR, "") }
        try await Core.runAsync { try Core.updateConfigDatabase(data) }
        UserDefaults.standard.set(Date(), forKey: key)
    }

    // MARK: Patch Engine repository

    enum PatchResult { case updated, upToDate }

    static func refreshPatches() async throws -> PatchResult {
        let address = try await Core.runAsync { try Core.patchRepositoryURL() }
        guard let url = URL(string: address) else { throw CoreError.status(RPCS3_IOS_PATCH_REPOSITORY_INVALID, "") }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError.status(RPCS3_IOS_PATCH_REPOSITORY_INVALID, "Réponse du serveur de patchs illisible.")
        }
        let code = (json["return_code"] as? NSNumber)?.intValue ?? -255
        switch code {
        case 1: return .upToDate
        case 0: break
        case -1: throw CoreError.status(RPCS3_IOS_PATCH_REPOSITORY_INVALID, "Aucun patch pour cette version du moteur de patchs.")
        case -2: throw CoreError.status(RPCS3_IOS_NETWORK_ERROR, "Serveur de patchs en maintenance.")
        default: throw CoreError.status(RPCS3_IOS_NETWORK_ERROR, "Erreur du serveur de patchs (\(code)).")
        }
        guard let version = json["version"] as? String, let sha = json["sha256"] as? String, let patch = json["patch"] as? String, !patch.isEmpty else {
            throw CoreError.status(RPCS3_IOS_PATCH_REPOSITORY_INVALID, "Réponse du serveur de patchs incomplète.")
        }
        try await Core.runAsync { try Core.installPatchRepository(version: version, sha256: sha, content: Data(patch.utf8)) }
        return .updated
    }

    // MARK: Title updates

    struct UpdatePackage: Hashable, Identifiable {
        var id: String { version }
        let version: String
        let size: UInt64
        let url: String
        let systemVersion: String
    }

    /// The packages Sony lists for a title, oldest first ("nothing" when there are none).
    static func updatePackages(_ titleID: String) async throws -> [UpdatePackage] {
        let xml = try await Core.runAsync { try Core.updateManifest(titleID) }
        guard !xml.isEmpty else { return [] }
        return ManifestParser.parse(xml).sorted { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
    }

    /// Downloads and installs every package newer than `installed`, in order.
    static func installUpdates(_ titleID: String, packages: [UpdatePackage], installed: String,
                               progress: @escaping (String, Double) -> Void) async throws {
        let todo = packages.filter { installed.isEmpty || $0.version.compare(installed, options: .numeric) == .orderedDescending }
        let folder = Core.cache.appendingPathComponent("updates", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for package in todo {
            let path = folder.appendingPathComponent("\(titleID)-\(package.version).pkg").path
            try await Core.runAsync {
                try Core.downloadUpdate(url: package.url, to: path, size: package.size) { done, total in
                    let f = total > 0 ? Double(done) / Double(total) : 0
                    DispatchQueue.main.async { progress("Téléchargement de la mise à jour \(package.version)", f) }
                }
                try Core.installGameUpdate(titleID: titleID, path: path) { done, total, _ in
                    let f = total > 0 ? Double(done) / Double(total) : 0
                    DispatchQueue.main.async { progress("Installation de la mise à jour \(package.version)", f) }
                }
            }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private final class ManifestParser: NSObject, XMLParserDelegate {
        var packages: [UpdatePackage] = []

        static func parse(_ data: Data) -> [UpdatePackage] {
            let p = ManifestParser()
            let parser = XMLParser(data: data)
            parser.delegate = p
            parser.parse()
            return p.packages
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            guard name == "package", let version = attributes["version"], let url = attributes["url"] else { return }
            packages.append(UpdatePackage(version: version, size: UInt64(attributes["size"] ?? "") ?? 0, url: url,
                                          systemVersion: attributes["ps3_system_ver"] ?? ""))
        }
    }
}
