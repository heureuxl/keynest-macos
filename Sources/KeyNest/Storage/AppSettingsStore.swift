import Foundation

/// 本地应用设置（明文 JSON，不含保管库密钥）。与 Windows 版 `settings.json` 字段一致。
@MainActor
final class AppSettingsStore: ObservableObject {
    private struct SettingsFile: Codable {
        var maxAccountsPerSiteHost: Int = 3
        var distinguishHostsByIp: Bool = true
    }

    static let minMaxAccounts = 1
    static let maxMaxAccounts = 99

    @Published private(set) var maxAccountsPerSiteHost: Int = 3
    @Published private(set) var distinguishHostsByIp: Bool = true

    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KeyNest", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("settings.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dto = try? JSONDecoder().decode(SettingsFile.self, from: data)
        else { return }
        maxAccountsPerSiteHost = Self.clampMaxAccounts(dto.maxAccountsPerSiteHost)
        distinguishHostsByIp = dto.distinguishHostsByIp
    }

    func save(maxAccountsPerSiteHost: Int, distinguishHostsByIp: Bool) {
        self.maxAccountsPerSiteHost = Self.clampMaxAccounts(maxAccountsPerSiteHost)
        self.distinguishHostsByIp = distinguishHostsByIp
        let dto = SettingsFile(
            maxAccountsPerSiteHost: self.maxAccountsPerSiteHost,
            distinguishHostsByIp: self.distinguishHostsByIp
        )
        if let data = try? JSONEncoder().encode(dto) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func clampMaxAccounts(_ value: Int) -> Int {
        min(max(value, minMaxAccounts), maxMaxAccounts)
    }
}
