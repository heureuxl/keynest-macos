import Foundation

/// 任意键值扩展字段（银行卡附加信息、API、密保等），保存在保管库密文中。
struct CustomField: Identifiable, Codable, Equatable {
    var id: UUID
    var label: String
    var value: String

    init(id: UUID = UUID(), label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}
