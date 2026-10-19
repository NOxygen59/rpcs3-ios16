// The RPCS3 core (libRPCS3Core.dylib, C ABI 30) seen from Swift. Every call that does real work
// (installs, boots, settings) runs on one serial queue, as the core serialises its lifecycle;
// enumerations copy the callback-scoped C strings into Swift values before returning.

import Foundation

enum CoreError: LocalizedError {
    case status(rpcs3_ios_status, String)

    var code: rpcs3_ios_status {
        switch self { case let .status(code, _): return code }
    }

    var errorDescription: String? {
        switch self {
        case let .status(code, message):
            return message.isEmpty ? Strings.status(code) : message
        }
    }
}

/// Text from a callback-scoped C string (empty for NULL).
@inline(__always) func str(_ p: UnsafePointer<CChar>?) -> String {
    p.map { String(cString: $0) } ?? ""
}

struct Game: Identifiable, Hashable {
    var id: String { titleID }
    let titleID: String
    let title: String
    let version: String
    let category: String
    let iconPath: String
    let firmwareVersion: String
    let path: String
    let bootable: Bool
    let sizeOnDisk: UInt64?
}

struct Savestate: Identifiable, Hashable {
    var id: String { identifier }
    let identifier: String
    let compatible: Bool
    let size: UInt64
    let modified: Date
}

struct Trophy: Identifiable, Hashable {
    var id: UInt32 { trophyID }
    let trophyID: UInt32
    let order: UInt32
    let grade: UInt32
    let earned: Bool
    let hidden: Bool
    let unlocked: Date?
    let name: String
    let detail: String
    let iconPath: String
}

struct InstalledUpdate: Hashable {
    let titleID: String
    let title: String
    let version: String
}

struct RuntimePatch: Identifiable, Hashable {
    var id: String { hash + "|" + title + "|" + detail + "|" + appVersion }
    var enabled: Bool
    let hash: String
    let title: String
    let detail: String
    let patchVersion: String
    let author: String
    let notes: String
    let group: String
    let appVersion: String
}

struct SettingOption: Hashable {
    let value: String
    let label: String
}

struct Setting: Identifiable, Hashable {
    var id: String { key }
    let kind: rpcs3_ios_setting_kind
    let key: String
    let category: String
    let section: String
    let name: String
    let detail: String
    var value: String
    let defaultValue: String
    let minimum: Double
    let maximum: Double
    let step: Double
    var options: [SettingOption]
    let recommended: String?
}

struct Preset: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let size: UInt64
    let modified: Date
}

struct CacheInfo {
    var shader: UInt64 = 0, ppu: UInt64 = 0, spu: UInt64 = 0, hdd1: UInt64 = 0, total: UInt64 = 0
}

struct RPCNConfig {
    var hasPassword = false, hasToken = false, ipv6 = false, connected = false, authenticated = false
    var username = "", host = "", onlineName = "", avatarURL = ""
}

struct RPCNServer: Identifiable, Hashable {
    var id: String { host + description }
    let selected: Bool
    let removable: Bool
    let description: String
    let host: String
}

struct RPCNContact: Identifiable, Hashable {
    var id: String { "\(kind)-\(username)" }
    let kind: UInt32
    let online: Bool
    let username: String
    let presenceTitle: String
    let presenceStatus: String
    let comment: String
}

struct Performance {
    var fps: Double?
    var cpu: Double?
    var gpu: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
}

/// A closure behind a C `void*` context, for the synchronous enumeration and progress callbacks.
final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
    var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    static func from(_ p: UnsafeMutableRawPointer?) -> T? {
        p.map { Unmanaged<Box<T>>.fromOpaque($0).takeUnretainedValue().value }
    }
}

typealias Progress = (_ completed: UInt32, _ total: UInt32, _ stage: String) -> Void

private let progressThunk: @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafePointer<CChar>?) -> Void = { ctx, done, total, stage in
    Box<Progress>.from(ctx)?(done, total, str(stage))
}

enum Core {
    /// Every working call goes through this queue, never the main thread.
    static let queue = DispatchQueue(label: "rpcs3.core", qos: .userInitiated)

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RPCS3", isDirectory: true)
    }

    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RPCS3", isDirectory: true)
    }

    static func check(_ status: rpcs3_ios_status) throws {
        guard status != RPCS3_IOS_OK else { return }
        throw CoreError.status(status, str(rpcs3_ios_last_error()))
    }

    /// Runs `work` on the core queue and hands back its result on the main queue.
    static func run<T>(_ work: @escaping () throws -> T, done: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let result = Result { try work() }
            DispatchQueue.main.async { done(result) }
        }
    }

    static func runAsync<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try work() }) }
        }
    }

    // MARK: Lifecycle

    static var abiVersion: UInt32 { rpcs3_ios_abi_version() }
    static var buildInfo: String { str(rpcs3_ios_build_info()) }
    static var state: rpcs3_ios_state { rpcs3_ios_get_state() }
    static var emulationState: rpcs3_ios_emulation_state { rpcs3_ios_get_emulation_state() }

    static func initialize(expandedArenaMiB: UInt32) throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let support = appSupport.path, cachePath = cache.path
        try support.withCString { s in
            try cachePath.withCString { c in
                var config = rpcs3_ios_config()
                config.abi_version = RPCS3_IOS_ABI_VERSION
                config.struct_size = UInt32(MemoryLayout<rpcs3_ios_config>.size)
                config.application_support_path = s
                config.cache_path = c
                config.log_callback = { _, level, message in Log.shared.append(level: level, str(message)) }
                config.main_thread_callback = { _, task, context in
                    guard let task else { return }
                    let ctx = context.map { UInt(bitPattern: $0) }
                    DispatchQueue.main.async { task(ctx.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }) }
                }
                config.user_context = nil
                config.expanded_jit_arena = expandedArenaMiB
                try check(rpcs3_ios_initialize(&config))
            }
        }
    }

    static var firmwareVersion: String { str(rpcs3_ios_firmware_version()) }

    // MARK: Installing

    private static func withProgress(_ progress: @escaping Progress, _ body: (rpcs3_ios_firmware_progress_callback, UnsafeMutableRawPointer) -> rpcs3_ios_status) throws {
        let box = Box<Progress>(progress)
        try withExtendedLifetime(box) { try check(body(progressThunk, box.pointer)) }
    }

    static func installFirmware(_ path: String, progress: @escaping Progress) throws {
        try withProgress(progress) { cb, ctx in rpcs3_ios_install_firmware(path, cb, ctx) }
    }

    static func installPackage(_ path: String, progress: @escaping Progress) throws {
        try withProgress(progress) { cb, ctx in rpcs3_ios_install_package(path, cb, ctx) }
    }

    static func installRAP(_ path: String) throws { try check(rpcs3_ios_install_rap(path)) }

    static func installISO(_ path: String, key: String?, progress: @escaping Progress) throws {
        try withProgress(progress) { cb, ctx in
            if let key { return rpcs3_ios_install_iso(path, key, cb, ctx) }
            return rpcs3_ios_install_iso(path, nil, cb, ctx)
        }
    }

    static func installZIP(_ path: String, progress: @escaping Progress) throws {
        try withProgress(progress) { cb, ctx in rpcs3_ios_install_zip(path, cb, ctx) }
    }

    static func installFolder(_ path: String, progress: @escaping Progress) throws {
        try withProgress(progress) { cb, ctx in rpcs3_ios_install_folder(path, cb, ctx) }
    }

    static func installGameUpdate(titleID: String, path: String, progress: @escaping Progress) throws {
        try withProgress(progress) { cb, ctx in rpcs3_ios_install_game_patch(titleID, path, cb, ctx) }
    }

    // MARK: Library

    static func games() throws -> [Game] {
        var out: [Game] = []
        let collect = Box<(UnsafePointer<rpcs3_ios_game_info>) -> Void> { g in
            let i = g.pointee
            out.append(Game(titleID: str(i.title_id), title: str(i.title), version: str(i.version), category: str(i.category),
                            iconPath: str(i.icon_path), firmwareVersion: str(i.firmware_version), path: str(i.path),
                            bootable: i.bootable != 0, sizeOnDisk: i.size_on_disk == UInt64.max ? nil : i.size_on_disk))
        }
        try withExtendedLifetime(collect) {
            try check(rpcs3_ios_enumerate_games({ ctx, g in
                guard let g else { return }
                Box<(UnsafePointer<rpcs3_ios_game_info>) -> Void>.from(ctx)?(g)
            }, collect.pointer))
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func deleteGame(_ titleID: String) throws { try check(rpcs3_ios_delete_game(titleID)) }

    static func cacheInfo(_ titleID: String) throws -> CacheInfo {
        var info = rpcs3_ios_game_cache_info()
        info.struct_size = UInt32(MemoryLayout<rpcs3_ios_game_cache_info>.size)
        try check(rpcs3_ios_get_game_cache_info(titleID, &info))
        return CacheInfo(shader: info.shader, ppu: info.ppu, spu: info.spu, hdd1: info.hdd1, total: info.total)
    }

    @discardableResult
    static func clearCache(_ titleID: String, _ type: rpcs3_ios_game_cache_type) throws -> UInt64 {
        var removed: UInt64 = 0
        try check(rpcs3_ios_clear_game_cache(titleID, type, &removed))
        return removed
    }

    // MARK: Savestates

    static func savestates(_ titleID: String) throws -> [Savestate] {
        var out: [Savestate] = []
        let collect = Box<(UnsafePointer<rpcs3_ios_savestate_info>) -> Void> { s in
            let i = s.pointee
            out.append(Savestate(identifier: str(i.identifier), compatible: i.compatible != 0, size: i.size,
                                 modified: Date(timeIntervalSince1970: TimeInterval(i.modified_time))))
        }
        try withExtendedLifetime(collect) {
            try check(rpcs3_ios_enumerate_savestates(titleID, { ctx, s in
                guard let s else { return }
                Box<(UnsafePointer<rpcs3_ios_savestate_info>) -> Void>.from(ctx)?(s)
            }, collect.pointer))
        }
        return out
    }

    static func duplicateSavestate(_ titleID: String, _ id: String) throws { try check(rpcs3_ios_duplicate_savestate(titleID, id)) }
    static func deleteSavestate(_ titleID: String, _ id: String) throws { try check(rpcs3_ios_delete_savestate(titleID, id)) }
    static func importSavestate(_ titleID: String, from path: String) throws { try check(rpcs3_ios_import_savestate(titleID, path)) }
    static func exportSavestate(_ titleID: String, _ id: String, to path: String) throws { try check(rpcs3_ios_export_savestate(titleID, id, path)) }

    // MARK: Trophies

    static func trophies(_ titleID: String) throws -> (title: String, list: [Trophy]) {
        var out: [Trophy] = []
        var gameTitle = ""
        let collect = Box<(UnsafePointer<rpcs3_ios_trophy_info>) -> Void> { t in
            let i = t.pointee
            if gameTitle.isEmpty { gameTitle = str(i.game_title) }
            out.append(Trophy(trophyID: i.trophy_id, order: i.display_order, grade: i.grade, earned: i.earned != 0, hidden: i.hidden != 0,
                              unlocked: i.earned != 0 && i.unlock_timestamp > 0 ? Date.fromPS3RTC(i.unlock_timestamp) : nil,
                              name: str(i.name), detail: str(i.description), iconPath: str(i.icon_path)))
        }
        try withExtendedLifetime(collect) {
            try check(rpcs3_ios_enumerate_trophies(titleID, { ctx, t in
                guard let t else { return }
                Box<(UnsafePointer<rpcs3_ios_trophy_info>) -> Void>.from(ctx)?(t)
            }, collect.pointer))
        }
        return (gameTitle, out.sorted { $0.order < $1.order })
    }

    // MARK: Updates and patches

    static func installedUpdates(_ titleID: String) throws -> [InstalledUpdate] {
        var out: [InstalledUpdate] = []
        let collect = Box<(UnsafePointer<rpcs3_ios_game_patch_info>) -> Void> { p in
            let i = p.pointee
            out.append(InstalledUpdate(titleID: str(i.title_id), title: str(i.title), version: str(i.version)))
        }
        try withExtendedLifetime(collect) {
            try check(rpcs3_ios_enumerate_game_patches(titleID, { ctx, p in
                guard let p else { return }
                Box<(UnsafePointer<rpcs3_ios_game_patch_info>) -> Void>.from(ctx)?(p)
            }, collect.pointer))
        }
        return out
    }

    static func updateManifest(_ titleID: String) throws -> Data {
        let capacity = 4 << 20
        var data = Data(count: capacity)
        var size = 0
        try data.withUnsafeMutableBytes { raw in
            try check(rpcs3_ios_fetch_game_update_manifest(titleID, raw.baseAddress, capacity, &size))
        }
        return data.prefix(size)
    }

    static func downloadUpdate(url: String, to path: String, size: UInt64, progress: @escaping (UInt64, UInt64) -> Void) throws {
        let box = Box<(UInt64, UInt64) -> Void>(progress)
        try withExtendedLifetime(box) {
            try check(rpcs3_ios_download_game_update_package(url, path, size, { ctx, done, total in
                Box<(UInt64, UInt64) -> Void>.from(ctx)?(done, total)
            }, box.pointer))
        }
    }

    static func patchRepositoryURL() throws -> String {
        var buffer = [CChar](repeating: 0, count: 2048)
        try check(rpcs3_ios_get_patch_repository_url(&buffer, buffer.count))
        return String(cString: buffer)
    }

    static func installPatchRepository(version: String, sha256: String, content: Data) throws {
        try content.withUnsafeBytes { raw in
            try check(rpcs3_ios_install_patch_repository(version, sha256, raw.baseAddress, raw.count))
        }
    }

    static func runtimePatches(_ titleID: String, appVersion: String) throws -> [RuntimePatch] {
        var out: [RuntimePatch] = []
        let collect = Box<(UnsafePointer<rpcs3_ios_runtime_patch_info>) -> Void> { p in
            let i = p.pointee
            out.append(RuntimePatch(enabled: i.enabled != 0, hash: str(i.hash), title: str(i.title), detail: str(i.description),
                                    patchVersion: str(i.patch_version), author: str(i.author), notes: str(i.notes),
                                    group: str(i.patch_group), appVersion: str(i.app_version)))
        }
        try withExtendedLifetime(collect) {
            try check(rpcs3_ios_enumerate_runtime_patches(titleID, appVersion, { ctx, p in
                guard let p else { return }
                Box<(UnsafePointer<rpcs3_ios_runtime_patch_info>) -> Void>.from(ctx)?(p)
            }, collect.pointer))
        }
        return out
    }

    static func setRuntimePatch(_ titleID: String, _ patch: RuntimePatch, enabled: Bool) throws {
        try check(rpcs3_ios_set_runtime_patch_enabled(titleID, patch.hash, patch.title, patch.appVersion, patch.detail, enabled ? 1 : 0))
    }

    static func updateConfigDatabase(_ data: Data) throws {
        try data.withUnsafeBytes { raw in try check(rpcs3_ios_update_config_database(raw.baseAddress, raw.count)) }
    }

    // MARK: Settings

    private typealias SettingSink = (setting: (UnsafePointer<rpcs3_ios_setting_info>) -> Void, option: (UnsafePointer<rpcs3_ios_setting_option>) -> Void)

    private static func collectSettings(_ call: (rpcs3_ios_setting_callback, rpcs3_ios_setting_option_callback, UnsafeMutableRawPointer) -> rpcs3_ios_status) throws -> [Setting] {
        var list: [Setting] = []
        var index: [String: Int] = [:]
        let sink = Box<SettingSink>((setting: { s in
            let i = s.pointee
            index[str(i.key)] = list.count
            list.append(Setting(kind: rpcs3_ios_setting_kind(rawValue: i.kind), key: str(i.key), category: str(i.category), section: str(i.section),
                                name: str(i.name), detail: str(i.description), value: str(i.value), defaultValue: str(i.default_value),
                                minimum: i.minimum, maximum: i.maximum, step: i.step, options: [],
                                recommended: i.recommended_value.map { String(cString: $0) }))
        }, option: { o in
            let i = o.pointee
            if let at = index[str(i.setting_key)] {
                list[at].options.append(SettingOption(value: str(i.value), label: str(i.label)))
            }
        }))
        try withExtendedLifetime(sink) {
            try check(call({ ctx, s in
                guard let s else { return }
                Box<SettingSink>.from(ctx)?.setting(s)
            }, { ctx, o in
                guard let o else { return }
                Box<SettingSink>.from(ctx)?.option(o)
            }, sink.pointer))
        }
        return list
    }

    static func settings() throws -> [Setting] {
        try collectSettings { s, o, ctx in rpcs3_ios_enumerate_settings(s, o, ctx) }
    }

    static func setSetting(_ key: String, _ value: String) throws { try check(rpcs3_ios_set_setting(key, value)) }
    static func resetSettings() throws { try check(rpcs3_ios_reset_settings()) }

    static func gameSettings(_ titleID: String) throws -> (list: [Setting], custom: Bool) {
        var custom: UInt32 = 0
        let list = try collectSettings { s, o, ctx in rpcs3_ios_enumerate_game_settings(titleID, s, o, ctx, &custom) }
        return (list, custom != 0)
    }

    static func setGameSetting(_ titleID: String, _ key: String, _ value: String) throws { try check(rpcs3_ios_set_game_setting(titleID, key, value)) }
    static func resetGameSettings(_ titleID: String) throws { try check(rpcs3_ios_reset_game_settings(titleID)) }
    static func removeGameSettings(_ titleID: String) throws { try check(rpcs3_ios_remove_game_settings(titleID)) }

    static func presets(_ titleID: String) throws -> [Preset] {
        var out: [Preset] = []
        let collect = Box<(UnsafePointer<rpcs3_ios_game_settings_preset_info>) -> Void> { p in
            let i = p.pointee
            out.append(Preset(name: str(i.name), size: i.size, modified: Date(timeIntervalSince1970: TimeInterval(i.modified_time))))
        }
        try withExtendedLifetime(collect) {
            try check(rpcs3_ios_enumerate_game_settings_presets(titleID, { ctx, p in
                guard let p else { return }
                Box<(UnsafePointer<rpcs3_ios_game_settings_preset_info>) -> Void>.from(ctx)?(p)
            }, collect.pointer))
        }
        return out
    }

    static func savePreset(_ titleID: String, _ name: String) throws { try check(rpcs3_ios_save_game_settings_preset(titleID, name)) }
    static func applyPreset(_ titleID: String, _ name: String) throws { try check(rpcs3_ios_apply_game_settings_preset(titleID, name)) }
    static func duplicatePreset(_ titleID: String, _ from: String, _ to: String) throws { try check(rpcs3_ios_duplicate_game_settings_preset(titleID, from, to)) }
    static func renamePreset(_ titleID: String, _ from: String, _ to: String) throws { try check(rpcs3_ios_rename_game_settings_preset(titleID, from, to)) }
    static func deletePreset(_ titleID: String, _ name: String) throws { try check(rpcs3_ios_delete_game_settings_preset(titleID, name)) }
    static func importPreset(_ titleID: String, from path: String, name: String) throws { try check(rpcs3_ios_import_game_settings_preset(titleID, path, name)) }
    static func exportPreset(_ titleID: String, _ name: String, to path: String) throws { try check(rpcs3_ios_export_game_settings_preset(titleID, name, path)) }

    // MARK: RPCN

    static func rpcnConfig() throws -> RPCNConfig {
        var out = RPCNConfig()
        let collect = Box<(UnsafePointer<rpcs3_ios_rpcn_config_info>) -> Void> { c in
            let i = c.pointee
            out = RPCNConfig(hasPassword: i.has_password != 0, hasToken: i.has_token != 0, ipv6: i.ipv6_support != 0,
                             connected: i.connected != 0, authenticated: i.authenticated != 0, username: str(i.username),
                             host: str(i.host), onlineName: str(i.online_name), avatarURL: str(i.avatar_url))
        }
        try withExtendedLifetime(collect) {
            try check(rpcs3_ios_get_rpcn_config({ ctx, c in
                guard let c else { return }
                Box<(UnsafePointer<rpcs3_ios_rpcn_config_info>) -> Void>.from(ctx)?(c)
            }, collect.pointer))
        }
        return out
    }

    static func rpcnServers() throws -> [RPCNServer] {
        var out: [RPCNServer] = []
        let collect = Box<(UnsafePointer<rpcs3_ios_rpcn_server_info>) -> Void> { s in
            let i = s.pointee
            out.append(RPCNServer(selected: i.selected != 0, removable: i.removable != 0, description: str(i.description), host: str(i.host)))
        }
        try withExtendedLifetime(collect) {
            try check(rpcs3_ios_enumerate_rpcn_servers({ ctx, s in
                guard let s else { return }
                Box<(UnsafePointer<rpcs3_ios_rpcn_server_info>) -> Void>.from(ctx)?(s)
            }, collect.pointer))
        }
        return out
    }

    static func setRPCNServer(_ host: String) throws { try check(rpcs3_ios_set_rpcn_server(host)) }
    static func addRPCNServer(_ description: String, _ host: String) throws { try check(rpcs3_ios_add_rpcn_server(description, host)) }
    static func removeRPCNServer(_ description: String, _ host: String) throws { try check(rpcs3_ios_remove_rpcn_server(description, host)) }

    static func setRPCNCredentials(username: String, password: String, token: String, ipv6: Bool) throws {
        try check(rpcs3_ios_set_rpcn_credentials(username, password, token, ipv6 ? 1 : 0))
    }

    static func createRPCNAccount(username: String, password: String, email: String) throws {
        try check(rpcs3_ios_create_rpcn_account(username, password, email))
    }

    static func testRPCNAccount() throws { try check(rpcs3_ios_test_rpcn_account()) }
    static func resendRPCNToken() throws { try check(rpcs3_ios_resend_rpcn_token()) }
    static func requestRPCNPasswordReset(username: String, email: String) throws { try check(rpcs3_ios_request_rpcn_password_reset(username, email)) }
    static func resetRPCNPassword(username: String, token: String, password: String) throws { try check(rpcs3_ios_reset_rpcn_password(username, token, password)) }
    static func deleteRPCNAccount() throws { try check(rpcs3_ios_delete_rpcn_account()) }

    static func rpcnContacts() throws -> [RPCNContact] {
        var out: [RPCNContact] = []
        let collect = Box<(UnsafePointer<rpcs3_ios_rpcn_social_info>) -> Void> { e in
            let i = e.pointee
            out.append(RPCNContact(kind: i.kind, online: i.online != 0, username: str(i.username), presenceTitle: str(i.presence_title),
                                   presenceStatus: str(i.presence_status), comment: str(i.presence_comment)))
        }
        try withExtendedLifetime(collect) {
            try check(rpcs3_ios_enumerate_rpcn_social({ ctx, e in
                guard let e else { return }
                Box<(UnsafePointer<rpcs3_ios_rpcn_social_info>) -> Void>.from(ctx)?(e)
            }, collect.pointer))
        }
        return out
    }

    static func rpcnSocial(_ action: rpcs3_ios_rpcn_social_action, _ username: String) throws {
        try check(rpcs3_ios_perform_rpcn_social_action(action.rawValue, username))
    }

    // MARK: Emulation

    static func setDisplay(layer: UnsafeMutableRawPointer?, width: UInt32, height: UInt32, refresh: Float) throws {
        guard let layer else {
            try check(rpcs3_ios_set_display_surface(nil))
            return
        }
        var surface = rpcs3_ios_display_surface(struct_size: UInt32(MemoryLayout<rpcs3_ios_display_surface>.size),
                                                 width: width, height: height, refresh_rate: refresh, metal_layer: layer)
        try check(rpcs3_ios_set_display_surface(&surface))
    }

    static func boot(_ titleID: String, savestate: String?) throws {
        try check(rpcs3_ios_boot_game(titleID, savestate ?? ""))
    }

    static func bootXMB() throws { try check(rpcs3_ios_boot_vsh()) }
    static func bootBigPicture() throws { try check(rpcs3_ios_boot_big_picture_mode()) }
    static func pause() throws { try check(rpcs3_ios_pause_emulation()) }
    static func resume() throws { try check(rpcs3_ios_resume_emulation()) }
    static func stop() throws { try check(rpcs3_ios_stop_emulation()) }

    static func bootProgress() -> (completed: UInt32, total: UInt32, stage: String)? {
        var done: UInt32 = 0, total: UInt32 = 0
        var buffer = [CChar](repeating: 0, count: 256)
        guard rpcs3_ios_get_boot_progress(&done, &total, &buffer, buffer.count) == RPCS3_IOS_OK else { return nil }
        return (done, total, String(cString: buffer))
    }

    static func performance() -> Performance? {
        var m = rpcs3_ios_performance_metrics()
        m.struct_size = UInt32(MemoryLayout<rpcs3_ios_performance_metrics>.size)
        guard rpcs3_ios_get_performance_metrics(&m) == RPCS3_IOS_OK else { return nil }
        let v = m.valid_fields
        func has(_ flag: rpcs3_ios_performance_metric_validity) -> Bool { v & flag.rawValue != 0 }
        return Performance(fps: has(RPCS3_IOS_PERFORMANCE_FPS_VALID) ? m.frames_per_second : nil,
                           cpu: has(RPCS3_IOS_PERFORMANCE_CPU_VALID) ? m.cpu_usage_percent : nil,
                           gpu: has(RPCS3_IOS_PERFORMANCE_GPU_VALID) ? m.gpu_usage_percent : nil,
                           memoryUsed: has(RPCS3_IOS_PERFORMANCE_MEMORY_VALID) ? m.memory_used_bytes : nil,
                           memoryTotal: has(RPCS3_IOS_PERFORMANCE_MEMORY_VALID) ? m.memory_total_bytes : nil)
    }

    static func setPad(_ player: UInt32, _ state: rpcs3_ios_pad_state) {
        var s = state
        s.struct_size = UInt32(MemoryLayout<rpcs3_ios_pad_state>.size)
        _ = rpcs3_ios_set_pad_state(player, &s)
    }

    static func padFeedback(_ player: UInt32) -> (large: UInt32, small: UInt32) {
        var f = rpcs3_ios_pad_feedback()
        f.struct_size = UInt32(MemoryLayout<rpcs3_ios_pad_feedback>.size)
        guard rpcs3_ios_get_pad_feedback(player, &f) == RPCS3_IOS_OK else { return (0, 0) }
        return (f.large_motor, f.small_motor)
    }
}

extension Date {
    /// PS3 RTC: microseconds since 0001-01-01.
    static func fromPS3RTC(_ value: UInt64) -> Date {
        // 0001-01-01 to 1970-01-01: 62135596800 seconds.
        Date(timeIntervalSince1970: TimeInterval(value) / 1_000_000 - 62_135_596_800)
    }
}
