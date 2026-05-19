import Foundation

struct PasswordItem: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var username: String
    var password: String
    /// 用于自动填充匹配，例如 https://example.com/
    var url: String
    /// 绑定解析 IP（hosts/DNS），同一域名不同环境独立存储；空表示不区分 IP（旧条目兼容）。
    var siteEndpoint: String?
    var notes: String
    /// 银行卡附加字段、API Key、密保问答等
    var customFields: [CustomField]
    /// 置顶收藏
    var isFavorite: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, username, password, url, siteEndpoint, notes, customFields, isFavorite
    }

    init(
        id: UUID = UUID(),
        title: String,
        username: String,
        password: String,
        url: String = "",
        siteEndpoint: String? = nil,
        notes: String = "",
        customFields: [CustomField] = [],
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.password = password
        self.url = url
        self.siteEndpoint = siteEndpoint
        self.notes = notes
        self.customFields = customFields
        self.isFavorite = isFavorite
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        username = try c.decode(String.self, forKey: .username)
        password = try c.decode(String.self, forKey: .password)
        url = try c.decode(String.self, forKey: .url)
        siteEndpoint = try c.decodeIfPresent(String.self, forKey: .siteEndpoint)
        notes = try c.decode(String.self, forKey: .notes)
        customFields = try c.decodeIfPresent([CustomField].self, forKey: .customFields) ?? []
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(username, forKey: .username)
        try c.encode(password, forKey: .password)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(siteEndpoint, forKey: .siteEndpoint)
        try c.encode(notes, forKey: .notes)
        try c.encode(customFields, forKey: .customFields)
        try c.encode(isFavorite, forKey: .isFavorite)
    }
}
