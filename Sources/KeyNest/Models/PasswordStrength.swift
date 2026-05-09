import Foundation

enum PasswordStrength {
    /// 本地启发式：过短、字符类过少视为弱密码。
    static func isWeak(_ password: String) -> Bool {
        let p = password
        if p.isEmpty { return true }
        if p.count < 8 { return true }
        var classes = 0
        if p.range(of: "[a-z]", options: .regularExpression) != nil { classes += 1 }
        if p.range(of: "[A-Z]", options: .regularExpression) != nil { classes += 1 }
        if p.range(of: "[0-9]", options: .regularExpression) != nil { classes += 1 }
        if p.range(of: "[^a-zA-Z0-9]", options: .regularExpression) != nil { classes += 1 }
        return classes < 2
    }
}
