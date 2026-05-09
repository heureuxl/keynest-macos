import CryptoKit
import Foundation

enum VaultStoreError: Error, LocalizedError {
    case notUnlocked
    case loadFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notUnlocked: return "保管库未解锁"
        case .loadFailed(let e): return "加载失败：\(e.localizedDescription)"
        }
    }
}

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var items: [PasswordItem] = []
    @Published var isUnlocked: Bool = false
    @Published var lastError: String?

    /// 新建保管库或从 v1 升级后仅展示一次；用户确认保存后由界面清空
    @Published var pendingRecoveryKeyToDisplay: String?

    private var masterPassword: String?
    /// 会话内数据密钥（32 字节 AES），不落盘
    private var sessionDataKey: SymmetricKey?

    private var vaultSaltMaster: Data?
    private var vaultSaltRecovery: Data?
    private var vaultWrappedRecovery: Data?

    private let vaultURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let newDir = appSupport.appendingPathComponent("KeyNest", isDirectory: true)
        let oldDir = appSupport.appendingPathComponent("TwoPassword", isDirectory: true)
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        let newVault = newDir.appendingPathComponent("vault.keynest")
        let oldVault = oldDir.appendingPathComponent("vault.twopw")
        if !fm.fileExists(atPath: newVault.path), fm.fileExists(atPath: oldVault.path) {
            do {
                try fm.copyItem(at: oldVault, to: newVault)
            } catch {
                NSLog("KeyNest: 无法从旧版路径迁移保管库 — \(error)")
            }
        }
        vaultURL = newVault
    }

    var vaultExists: Bool {
        FileManager.default.fileExists(atPath: vaultURL.path)
    }

    func acknowledgeRecoveryKeySaved() {
        pendingRecoveryKeyToDisplay = nil
    }

    func lock() {
        masterPassword = nil
        sessionDataKey = nil
        vaultSaltMaster = nil
        vaultSaltRecovery = nil
        vaultWrappedRecovery = nil
        items = []
        isUnlocked = false
    }

    /// 首次创建保管库
    func unlock(password: String) throws {
        if vaultExists {
            try loadExistingVault(masterPassword: password)
        } else {
            try createNewVault(password: password)
        }
        isUnlocked = true
    }

    /// 忘记主密码时使用恢复密钥解锁并设置新主密码（保管库须为 v2）
    func unlockWithRecovery(recoveryKeyPhrase: String, newMasterPassword: String) throws {
        let normalizedRecovery = normalizeRecoveryInput(recoveryKeyPhrase)
        guard !normalizedRecovery.isEmpty else {
            throw VaultCryptoError.wrongRecoveryKey
        }
        let data = try Data(contentsOf: vaultURL)
        let outer = try JSONDecoder().decode(VaultFile.self, from: data)
        guard outer.version == 2,
              let saltR = outer.saltRecovery,
              let saltM = outer.saltMaster,
              let wR = outer.wrappedDataKeyRecovery,
              outer.wrappedDataKeyMaster != nil,
              let pc = outer.payloadCiphertext
        else {
            throw VaultCryptoError.invalidVaultFormat
        }

        let kr = try VaultCrypto.deriveKey(password: normalizedRecovery, salt: saltR)
        let dkBytes: Data
        do {
            dkBytes = try VaultCrypto.decrypt(ciphertext: wR, key: kr)
        } catch {
            throw VaultCryptoError.wrongRecoveryKey
        }

        let dataKey = try VaultCrypto.symmetricKeyFromBytes(dkBytes)
        let plain = try VaultCrypto.decrypt(ciphertext: pc, key: dataKey)
        let payload = try JSONDecoder().decode(VaultPayload.self, from: plain)

        masterPassword = newMasterPassword
        sessionDataKey = dataKey
        vaultSaltMaster = saltM
        vaultSaltRecovery = saltR
        vaultWrappedRecovery = wR
        items = payload.items

        try persistVaultV2()
        isUnlocked = true
    }

    func changeMasterPassword(to newPassword: String) throws {
        masterPassword = newPassword
        try persistVaultV2()
    }

    /// 在已解锁状态下生成新的恢复密钥短语；旧短语立即失效（与 Windows 版行为一致）。
    func rotateRecoveryKey() throws -> String {
        guard masterPassword != nil,
              let dataKey = sessionDataKey,
              vaultSaltMaster != nil,
              vaultSaltRecovery != nil,
              vaultWrappedRecovery != nil
        else {
            throw VaultStoreError.notUnlocked
        }
        let recoveryPhrase = VaultCrypto.generateRecoveryKeyPhrase()
        let saltR = VaultCrypto.randomSalt()
        let kr = try VaultCrypto.deriveKey(password: recoveryPhrase, salt: saltR)
        let dkBytes = VaultCrypto.symmetricKeyBytes(dataKey)
        let wR = try VaultCrypto.encrypt(plaintext: dkBytes, key: kr)
        vaultSaltRecovery = saltR
        vaultWrappedRecovery = wR
        try persistVaultV2()
        return recoveryPhrase
    }

    /// 同一主机（域名或 IP，不含路径）下最多保存 3 个**不同用户名**；相同主机 + 相同用户名则覆盖（保留 id、备注）。
    /// 网站字段为空时不受「每主机三条」限制。
    func add(_ item: PasswordItem) throws {
        try addOrReplaceBySiteHost(item)
    }

    private func normalizedUsernameKey(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func addOrReplaceBySiteHost(_ item: PasswordItem) throws {
        guard let hostKey = Self.normalizedSiteHostKey(item.url) else {
            items.append(item)
            try persistVaultV2()
            return
        }
        let userKey = normalizedUsernameKey(item.username)
        let group = items.enumerated().filter { Self.normalizedSiteHostKey($0.element.url) == hostKey }

        if let hit = group.first(where: { normalizedUsernameKey($0.element.username) == userKey }) {
            var merged = hit.element
            merged.title = item.title
            merged.username = item.username
            merged.password = item.password
            merged.url = item.url
            merged.notes = item.notes
            items[hit.offset] = merged
            let dupIds = group.filter { $0.offset != hit.offset && normalizedUsernameKey($0.element.username) == userKey }.map(\.element.id)
            items.removeAll { dupIds.contains($0.id) }
            try persistVaultV2()
            return
        }

        if group.count >= 3 {
            guard let oldest = group.min(by: { $0.offset < $1.offset }) else {
                items.append(item)
                try persistVaultV2()
                return
            }
            items.removeAll { $0.id == oldest.element.id }
        }
        items.append(item)
        try persistVaultV2()
    }

    /// 与 `add`、扩展填充一致：仅用**主机名**（域名或 IP，小写）作为站点键，不含路径、查询、端口。
    static func normalizedSiteHostKey(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var s = t
        if !s.contains("://") {
            s = "https://" + s
        }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else {
            return nil
        }
        return host.lowercased()
    }

    private static func hostsMatch(pageHost: String, credentialHost: String) -> Bool {
        pageHost == credentialHost
            || pageHost.hasSuffix("." + credentialHost)
            || credentialHost.hasSuffix("." + pageHost)
    }

    func update(_ item: PasswordItem) throws {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        try persistVaultV2()
    }

    func remove(id: UUID) throws {
        items.removeAll { $0.id == id }
        try persistVaultV2()
    }

    /// 浏览器扩展保存：当前页与用户名对应的条目已存在且密码一致时无需再次写入。
    func shouldSkipBridgeSave(pageURL: String, username: String, password: String) -> Bool {
        let uk = normalizedUsernameKey(username)
        let hits = matches(forPageURL: pageURL).filter { normalizedUsernameKey($0.username) == uk }
        guard let hit = hits.first else { return false }
        return hit.password == password
    }

    /// 按当前页与条目「网站」字段的**主机名**（域名或 IP）匹配；支持子域与根域的互相包含关系。
    func matches(forPageURL pageURL: String) -> [PasswordItem] {
        guard let pageHost = Self.normalizedSiteHostKey(pageURL) else {
            return []
        }
        let matched = items.filter { item in
            guard !item.url.isEmpty, let h = Self.normalizedSiteHostKey(item.url) else {
                return false
            }
            return Self.hostsMatch(pageHost: pageHost, credentialHost: h)
        }
        return matched.sorted {
            $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }
    }

    // MARK: - Private

    private func normalizeRecoveryInput(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createNewVault(password: String) throws {
        let recoveryPhrase = VaultCrypto.generateRecoveryKeyPhrase()
        let saltM = VaultCrypto.randomSalt()
        let saltR = VaultCrypto.randomSalt()
        let dkBytes = VaultCrypto.randomSalt()
        let dataKey = try VaultCrypto.symmetricKeyFromBytes(dkBytes)

        let km = try VaultCrypto.deriveKey(password: password, salt: saltM)
        let kr = try VaultCrypto.deriveKey(password: recoveryPhrase, salt: saltR)
        let wM = try VaultCrypto.encrypt(plaintext: dkBytes, key: km)
        let wR = try VaultCrypto.encrypt(plaintext: dkBytes, key: kr)

        let payload = VaultPayload(items: [])
        let plain = try JSONEncoder().encode(payload)
        let pc = try VaultCrypto.encrypt(plaintext: plain, key: dataKey)

        masterPassword = password
        sessionDataKey = dataKey
        vaultSaltMaster = saltM
        vaultSaltRecovery = saltR
        vaultWrappedRecovery = wR
        items = []

        let outer = VaultFile(
            version: 2,
            salt: nil,
            ciphertext: nil,
            saltMaster: saltM,
            saltRecovery: saltR,
            wrappedDataKeyMaster: wM,
            wrappedDataKeyRecovery: wR,
            payloadCiphertext: pc
        )
        try writeVaultFile(outer)
        pendingRecoveryKeyToDisplay = recoveryPhrase
    }

    private func loadExistingVault(masterPassword password: String) throws {
        let data = try Data(contentsOf: vaultURL)
        let outer = try JSONDecoder().decode(VaultFile.self, from: data)

        if outer.version == 1, let salt = outer.salt, let ct = outer.ciphertext {
            try migrateFromV1(masterPassword: password, salt: salt, ciphertext: ct)
            return
        }

        guard outer.version == 2,
              let saltM = outer.saltMaster,
              let saltR = outer.saltRecovery,
              let wM = outer.wrappedDataKeyMaster,
              let wR = outer.wrappedDataKeyRecovery,
              let pc = outer.payloadCiphertext
        else {
            throw VaultCryptoError.invalidVaultFormat
        }

        let km = try VaultCrypto.deriveKey(password: password, salt: saltM)
        let dkBytes: Data
        do {
            dkBytes = try VaultCrypto.decrypt(ciphertext: wM, key: km)
        } catch {
            throw VaultCryptoError.wrongMasterPassword
        }

        let dataKey = try VaultCrypto.symmetricKeyFromBytes(dkBytes)
        let plain = try VaultCrypto.decrypt(ciphertext: pc, key: dataKey)
        let payload = try JSONDecoder().decode(VaultPayload.self, from: plain)

        masterPassword = password
        sessionDataKey = dataKey
        vaultSaltMaster = saltM
        vaultSaltRecovery = saltR
        vaultWrappedRecovery = wR
        items = payload.items
    }

    private func migrateFromV1(masterPassword password: String, salt: Data, ciphertext: Data) throws {
        let km = try VaultCrypto.deriveKey(password: password, salt: salt)
        let plain = try VaultCrypto.decrypt(ciphertext: ciphertext, key: km)
        let payload = try JSONDecoder().decode(VaultPayload.self, from: plain)

        let recoveryPhrase = VaultCrypto.generateRecoveryKeyPhrase()
        let saltM = VaultCrypto.randomSalt()
        let saltR = VaultCrypto.randomSalt()
        let dkBytes = VaultCrypto.randomSalt()
        let dataKey = try VaultCrypto.symmetricKeyFromBytes(dkBytes)

        let kmNew = try VaultCrypto.deriveKey(password: password, salt: saltM)
        let kr = try VaultCrypto.deriveKey(password: recoveryPhrase, salt: saltR)
        let wM = try VaultCrypto.encrypt(plaintext: dkBytes, key: kmNew)
        let wR = try VaultCrypto.encrypt(plaintext: dkBytes, key: kr)

        let body = try JSONEncoder().encode(payload)
        let pc = try VaultCrypto.encrypt(plaintext: body, key: dataKey)

        masterPassword = password
        sessionDataKey = dataKey
        vaultSaltMaster = saltM
        vaultSaltRecovery = saltR
        vaultWrappedRecovery = wR
        items = payload.items

        let outer = VaultFile(
            version: 2,
            salt: nil,
            ciphertext: nil,
            saltMaster: saltM,
            saltRecovery: saltR,
            wrappedDataKeyMaster: wM,
            wrappedDataKeyRecovery: wR,
            payloadCiphertext: pc
        )
        try writeVaultFile(outer)
        pendingRecoveryKeyToDisplay = recoveryPhrase
    }

    private func persistVaultV2() throws {
        dedupeSameHostSameUsername()
        enforceMaxAccountsPerSiteURL()
        guard let password = masterPassword,
              let dataKey = sessionDataKey,
              let saltM = vaultSaltMaster,
              let saltR = vaultSaltRecovery,
              let wR = vaultWrappedRecovery
        else {
            throw VaultStoreError.notUnlocked
        }

        let dkBytes = VaultCrypto.symmetricKeyBytes(dataKey)
        let km = try VaultCrypto.deriveKey(password: password, salt: saltM)
        let wM = try VaultCrypto.encrypt(plaintext: dkBytes, key: km)

        let payload = VaultPayload(items: items)
        let plain = try JSONEncoder().encode(payload)
        let pc = try VaultCrypto.encrypt(plaintext: plain, key: dataKey)

        let outer = VaultFile(
            version: 2,
            salt: nil,
            ciphertext: nil,
            saltMaster: saltM,
            saltRecovery: saltR,
            wrappedDataKeyMaster: wM,
            wrappedDataKeyRecovery: wR,
            payloadCiphertext: pc
        )
        try writeVaultFile(outer)
    }

    private func writeVaultFile(_ outer: VaultFile) throws {
        let data = try JSONEncoder().encode(outer)
        try data.write(to: vaultURL, options: .atomic)
    }

    /// 合并重复条目：同一主机键 + 同一用户名只保留**最后一次出现**（有 URL 主机时才参与；网站为空的条目互不合并）。
    private func dedupeSameHostSameUsername() {
        var keyToLastIndex: [String: Int] = [:]
        for (idx, it) in items.enumerated() {
            guard let hk = Self.normalizedSiteHostKey(it.url) else { continue }
            let uk = normalizedUsernameKey(it.username)
            let key = hk + "\u{1f}" + uk
            keyToLastIndex[key] = idx
        }
        var removeIds = Set<UUID>()
        for (idx, it) in items.enumerated() {
            guard let hk = Self.normalizedSiteHostKey(it.url) else { continue }
            let uk = normalizedUsernameKey(it.username)
            let key = hk + "\u{1f}" + uk
            if let keepIdx = keyToLastIndex[key], keepIdx != idx {
                removeIds.insert(it.id)
            }
        }
        if !removeIds.isEmpty {
            items.removeAll { removeIds.contains($0.id) }
        }
    }

    /// 落盘前收紧：同一主机（域名或 IP）最多 3 条不同用户名；同用户名保留最后一次出现。
    private func enforceMaxAccountsPerSiteURL() {
        let snapshot = items
        var groups: [String: [PasswordItem]] = [:]
        var keyOrder: [String] = []
        for it in snapshot {
            guard let k = Self.normalizedSiteHostKey(it.url) else { continue }
            if groups[k] == nil { keyOrder.append(k) }
            groups[k, default: []].append(it)
        }
        var keep = Set<UUID>()
        for k in keyOrder {
            guard let g = groups[k] else { continue }
            var pick: [PasswordItem] = []
            for it in g {
                let uk = normalizedUsernameKey(it.username)
                if let i = pick.firstIndex(where: { normalizedUsernameKey($0.username) == uk }) {
                    pick[i] = it
                } else if pick.count < 3 {
                    pick.append(it)
                }
            }
            pick.forEach { keep.insert($0.id) }
        }
        for it in snapshot where Self.normalizedSiteHostKey(it.url) == nil {
            keep.insert(it.id)
        }
        let next = snapshot.filter { keep.contains($0.id) }
        if next.count != items.count || Set(next.map(\.id)) != Set(items.map(\.id)) {
            items = next
        }
    }
}
