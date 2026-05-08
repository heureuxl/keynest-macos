import Foundation

/// 磁盘上的保管库（v1：仅主密码；v2：数据密钥 + 主密码/恢复密钥双重包裹）
struct VaultFile: Codable {
    var version: Int

    /// v1
    var salt: Data?
    var ciphertext: Data?

    /// v2
    var saltMaster: Data?
    var saltRecovery: Data?
    var wrappedDataKeyMaster: Data?
    var wrappedDataKeyRecovery: Data?
    /// v2 下为 VaultPayload 的密文（由随机数据密钥加密）
    var payloadCiphertext: Data?
}

struct VaultPayload: Codable {
    var items: [PasswordItem]
}
