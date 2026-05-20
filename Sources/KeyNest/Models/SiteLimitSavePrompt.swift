import Foundation

/// 同一网站账号数已达上限、再保存新用户名时需要用户确认。
struct SiteLimitSavePrompt: Equatable {
    var siteLabel: String
    var maxAccounts: Int
    var currentCount: Int
    var incomingUsername: String
    var evictTitle: String
    var evictUsername: String

    var message: String {
        let incoming = incomingUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "（无用户名）" : incomingUsername
        let evictUser = evictUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "（无用户名）" : evictUsername
        return """
        网站「\(siteLabel)」已保存 \(currentCount) 个不同账号（上限 \(maxAccounts) 个）。

        继续保存账号「\(incoming)」将移除最早条目：
        \(evictTitle)（\(evictUser)）

        是否继续保存？
        """
    }
}

struct BridgeSiteLimitCheck: Codable {
    var needsConfirm: Bool
    var maxAccounts: Int
    var currentCount: Int
    var siteLabel: String
    var evictTitle: String
    var evictUsername: String
    var incomingUsername: String
}
