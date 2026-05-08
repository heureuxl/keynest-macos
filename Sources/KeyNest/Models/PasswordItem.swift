import Foundation

struct PasswordItem: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var username: String
    var password: String
    /// 用于自动填充匹配，例如 https://example.com/
    var url: String
    var notes: String

    init(
        id: UUID = UUID(),
        title: String,
        username: String,
        password: String,
        url: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.notes = notes
    }
}
