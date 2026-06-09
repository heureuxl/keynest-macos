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
    private let settings: AppSettingsStore

    init(settings: AppSettingsStore) {
        self.settings = settings
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

    /// 新增用户名且已达站点上限时返回确认信息；更新已有用户名或未满则不返回。
    func siteLimitSavePrompt(for item: PasswordItem, pageURL: String? = nil) -> SiteLimitSavePrompt? {
        guard isUnlocked else { return nil }
        var copy = item
        applyAutoSiteEndpoint(&copy, pageURL: pageURL)
        guard let siteKey = siteIdentityKey(for: copy) else { return nil }

        let userKey = normalizedUsernameKey(copy.username)
        let group = items.filter { siteIdentityKey(for: $0) == siteKey }
        if group.contains(where: { normalizedUsernameKey($0.username) == userKey }) {
            return nil
        }
        let maxN = settings.maxAccountsPerSiteHost
        let distinctCount = distinctUsernameCount(in: group)
        if distinctCount < maxN {
            return nil
        }
        guard let oldest = items.enumerated()
            .filter({ siteIdentityKey(for: $0.element) == siteKey })
            .min(by: { $0.offset < $1.offset })
        else { return nil }

        return SiteLimitSavePrompt(
            siteLabel: SiteIdentityService.formatGroupTitle(siteKey),
            maxAccounts: maxN,
            currentCount: distinctCount,
            incomingUsername: copy.username,
            evictTitle: oldest.element.title.isEmpty ? "未命名" : oldest.element.title,
            evictUsername: oldest.element.username
        )
    }

    /// 扩展查询站点上限；始终返回当前设置的上限与已存不同用户名数量。
    func bridgeSiteLimitCheck(pageURL: String, username: String) -> BridgeSiteLimitCheck {
        let maxN = settings.maxAccountsPerSiteHost
        var probe = PasswordItem(title: "", username: username, password: "x", url: pageURL)
        applyAutoSiteEndpoint(&probe, pageURL: pageURL)
        let siteKey = siteIdentityKey(for: probe)
        let distinctCount: Int
        if let siteKey {
            let group = items.filter { siteIdentityKey(for: $0) == siteKey }
            distinctCount = distinctUsernameCount(in: group)
        } else {
            distinctCount = 0
        }
        if let prompt = siteLimitSavePrompt(for: probe, pageURL: pageURL) {
            return BridgeSiteLimitCheck(
                needsConfirm: true,
                maxAccounts: prompt.maxAccounts,
                currentCount: prompt.currentCount,
                siteLabel: prompt.siteLabel,
                evictTitle: prompt.evictTitle,
                evictUsername: prompt.evictUsername,
                incomingUsername: prompt.incomingUsername
            )
        }
        return BridgeSiteLimitCheck(
            needsConfirm: false,
            maxAccounts: maxN,
            currentCount: distinctCount,
            siteLabel: siteKey.map { SiteIdentityService.formatGroupTitle($0) } ?? "",
            evictTitle: "",
            evictUsername: "",
            incomingUsername: username
        )
    }

    /// 同一站点环境（可选按 hosts IP 区分）下最多保存 N 个**不同用户名**；相同站点 + 相同用户名则覆盖。
    /// 网站字段为空时不受「每站点上限」限制。达上限且未确认时返回 `false`。
    @discardableResult
    func add(_ item: PasswordItem, pageURL: String? = nil, allowEvictOldest: Bool = false) throws -> Bool {
        var copy = item
        applyAutoSiteEndpoint(&copy, pageURL: pageURL)
        return try mergeIncomingBySiteHost(copy, allowEvictOldest: allowEvictOldest)
    }

    func reorderItems(visibleIdsInOrder: [UUID]) throws {
        let idSet = Set(visibleIdsInOrder)
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var next = visibleIdsInOrder.compactMap { map[$0] }
        next.append(contentsOf: items.filter { !idSet.contains($0.id) })
        items = next
        try persistVaultV2()
    }

    func update(_ item: PasswordItem) throws {
        var copy = item
        applyAutoSiteEndpoint(&copy)
        guard let i = items.firstIndex(where: { $0.id == copy.id }) else { return }
        items[i] = copy
        try persistVaultV2()
    }

    /// 设置变更后按当前规则收紧每站点账号上限并落盘。
    func enforceLimitsAndPersist() throws {
        guard isUnlocked else { throw VaultStoreError.notUnlocked }
        dedupeSameHostSameUsername()
        enforceMaxAccountsPerSiteURL()
        try persistVaultV2WithoutLimitsPass()
    }

    private func normalizedUsernameKey(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 同一站点环境下已保存的不同用户名个数（与 enforceMaxAccountsPerSiteURL 一致）。
    private func distinctUsernameCount(in group: [PasswordItem]) -> Int {
        Set(group.map { normalizedUsernameKey($0.username) }).count
    }

    private func siteIdentityKey(for item: PasswordItem) -> String? {
        SiteIdentityService.getIdentityKey(
            url: item.url,
            siteEndpoint: item.siteEndpoint,
            distinguishByIp: settings.distinguishHostsByIp
        )
    }

    private func applyAutoSiteEndpoint(_ item: inout PasswordItem, pageURL: String? = nil) {
        guard settings.distinguishHostsByIp else { return }
        if let ep = SiteIdentityService.normalizeEndpoint(item.siteEndpoint), !ep.isEmpty { return }
        let resolved = SiteIdentityService.resolveEndpointForUrl(pageURL ?? item.url)
        if let resolved, !resolved.isEmpty {
            item.siteEndpoint = resolved
        }
    }

    /// `@Published` 对数组下标赋值不会触发界面刷新，桥接保存后需整表替换。
    private func publishItemsMutation() {
        items = items
    }

    @discardableResult
    private func mergeIncomingBySiteHost(_ item: PasswordItem, allowEvictOldest: Bool) throws -> Bool {
        guard let siteKey = siteIdentityKey(for: item) else {
            items.append(item)
            try persistVaultV2()
            publishItemsMutation()
            return true
        }
        let userKey = normalizedUsernameKey(item.username)
        let group = items.enumerated().filter { siteIdentityKey(for: $0.element) == siteKey }

        if let hit = group.first(where: { normalizedUsernameKey($0.element.username) == userKey }) {
            var merged = hit.element
            merged.title = item.title
            merged.username = item.username
            merged.password = item.password
            merged.url = item.url
            merged.siteEndpoint = item.siteEndpoint
            merged.notes = item.notes
            if !item.customFields.isEmpty {
                merged.customFields = item.customFields
            }
            merged.isFavorite = item.isFavorite
            items[hit.offset] = merged
            let dupIds = group.filter { $0.offset != hit.offset && normalizedUsernameKey($0.element.username) == userKey }.map(\.element.id)
            items.removeAll { dupIds.contains($0.id) }
            try persistVaultV2()
            publishItemsMutation()
            return true
        }

        let maxN = settings.maxAccountsPerSiteHost
        if distinctUsernameCount(in: group.map(\.element)) >= maxN {
            if !allowEvictOldest {
                return false
            }
            guard let oldest = group.min(by: { $0.offset < $1.offset }) else {
                items.append(item)
                try persistVaultV2()
                publishItemsMutation()
                return true
            }
            items.removeAll { $0.id == oldest.element.id }
        }
        items.append(item)
        try persistVaultV2()
        publishItemsMutation()
        return true
    }

    /// 与 `add`、扩展填充一致：仅用**主机名**（域名或 IP，小写）作为站点键，不含路径、查询、端口。
    static func normalizedSiteHostKey(_ raw: String) -> String? {
        SiteIdentityService.normalizedHost(raw)
    }

    private static func canonicalHostForMatch(_ host: String) -> String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.hasPrefix("www.") { return String(h.dropFirst(4)) }
        return h
    }

    private static func approxRegistrableDomain(_ host: String) -> String? {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2]).\(parts[parts.count - 1])"
    }

    static func hostsMatch(pageHost: String, credentialHost: String) -> Bool {
        let p = canonicalHostForMatch(pageHost)
        let i = canonicalHostForMatch(credentialHost)
        if p == i { return true }
        if p.hasSuffix("." + i) || i.hasSuffix("." + p) { return true }
        if let rp = approxRegistrableDomain(p), let ri = approxRegistrableDomain(i), rp == ri {
            return true
        }
        return false
    }

    func remove(id: UUID) throws {
        items.removeAll { $0.id == id }
        try persistVaultV2()
    }

    func toggleFavorite(id: UUID) throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isFavorite.toggle()
        try persistVaultV2()
    }

    /// 同一主机 + 同一用户名仅保留一条（保留最后一次）。返回合并删除的条数。
    func mergeDuplicateHostUsernames() throws -> Int {
        let before = items.count
        dedupeSameHostSameUsername()
        guard items.count != before else { return 0 }
        try persistVaultV2()
        return before - items.count
    }

    /// 浏览器扩展保存：当前页与用户名对应的条目已存在且密码一致时无需再次写入。
    func shouldSkipBridgeSave(pageURL: String, username: String, password: String) -> Bool {
        let uk = normalizedUsernameKey(username)
        let hits = matches(forPageURL: pageURL).filter { normalizedUsernameKey($0.username) == uk }
        guard let hit = hits.first else { return false }
        if hit.password == password { return true }
        // 曾误存极短密码时，允许扩展用更长明文覆盖
        if hit.password.count <= 2, password.count > hit.password.count { return false }
        return false
    }

    /// 按当前页与条目网站匹配；开启 IP 区分时还要求 hosts 解析环境一致。
    func matches(forPageURL pageURL: String) -> [PasswordItem] {
        guard Self.normalizedSiteHostKey(pageURL) != nil else { return [] }
        let matched = items.filter { item in
            guard !item.url.isEmpty else { return false }
            return SiteIdentityService.contextsMatch(
                pageUrl: pageURL,
                itemUrl: item.url,
                itemSiteEndpoint: item.siteEndpoint,
                distinguishByIp: settings.distinguishHostsByIp,
                hostsMatch: Self.hostsMatch
            )
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
        try persistVaultV2WithoutLimitsPass()
    }

    private func persistVaultV2WithoutLimitsPass() throws {
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

    /// 合并重复条目：同一站点身份 + 同一用户名只保留**最后一次出现**。
    private func dedupeSameHostSameUsername() {
        var keyToLastIndex: [String: Int] = [:]
        for (idx, it) in items.enumerated() {
            guard let sk = siteIdentityKey(for: it) else { continue }
            let uk = normalizedUsernameKey(it.username)
            let key = sk + "\u{1f}" + uk
            keyToLastIndex[key] = idx
        }
        var removeIds = Set<UUID>()
        for (idx, it) in items.enumerated() {
            guard let sk = siteIdentityKey(for: it) else { continue }
            let uk = normalizedUsernameKey(it.username)
            let key = sk + "\u{1f}" + uk
            if let keepIdx = keyToLastIndex[key], keepIdx != idx {
                removeIds.insert(it.id)
            }
        }
        if !removeIds.isEmpty {
            items.removeAll { removeIds.contains($0.id) }
        }
    }

    /// 落盘前收紧：同一站点环境最多 N 条不同用户名；同用户名保留最后一次出现。
    private func enforceMaxAccountsPerSiteURL() {
        let snapshot = items
        let maxN = settings.maxAccountsPerSiteHost
        var groups: [String: [PasswordItem]] = [:]
        var keyOrder: [String] = []
        for it in snapshot {
            guard let k = siteIdentityKey(for: it) else { continue }
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
                } else if pick.count < maxN {
                    pick.append(it)
                }
            }
            pick.forEach { keep.insert($0.id) }
        }
        for it in snapshot where siteIdentityKey(for: it) == nil {
            keep.insert(it.id)
        }
        let next = snapshot.filter { keep.contains($0.id) }
        if next.count != items.count || Set(next.map(\.id)) != Set(items.map(\.id)) {
            items = next
        }
    }
}
