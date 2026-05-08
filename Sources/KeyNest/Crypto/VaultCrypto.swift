import Crypto
import CryptoExtras
import CryptoKit
import Foundation
import Security

enum VaultCryptoError: Error, LocalizedError, Equatable {
    case invalidVaultFormat
    case decryptionFailed
    case wrongMasterPassword
    case wrongRecoveryKey

    var errorDescription: String? {
        switch self {
        case .invalidVaultFormat: return "保管库文件格式无效"
        case .decryptionFailed: return "解密失败"
        case .wrongMasterPassword: return "主密码不正确"
        case .wrongRecoveryKey: return "恢复密钥不正确"
        }
    }
}

enum VaultCrypto {
    /// OWASP 建议级别：约 31 万次 PBKDF2-SHA256（可按机器性能调整）
    static let pbkdf2Iterations: UInt32 = 310_000
    static let saltLength = 32

    static func randomSalt() -> Data {
        var data = Data(count: saltLength)
        let status = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, ptr.baseAddress!)
        }
        precondition(status == errSecSuccess)
        return data
    }

    static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        try KDF.Insecure.PBKDF2.deriveKey(
            from: Array(password.utf8),
            salt: salt,
            using: .sha256,
            outputByteCount: 32,
            rounds: Int(pbkdf2Iterations)
        )
    }

    static func encrypt(plaintext: Data, key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw VaultCryptoError.decryptionFailed
        }
        return combined
    }

    static func decrypt(ciphertext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }

    /// 生成高熵恢复密钥（URL 安全 Base64，解码时需使用同一字符串）
    static func generateRecoveryKeyPhrase() -> String {
        let bytes = randomSalt()
        return Data(bytes).base64EncodedString()
    }

    static func symmetricKeyBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func symmetricKeyFromBytes(_ data: Data) throws -> SymmetricKey {
        guard [16, 24, 32].contains(data.count) else {
            throw VaultCryptoError.invalidVaultFormat
        }
        return SymmetricKey(data: data)
    }
}
