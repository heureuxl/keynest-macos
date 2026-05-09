import Foundation

/// 记录条目最近一次打开/复制密码的时间（仅存 UUID 与时间戳，不含密钥明文）。
@MainActor
final class EntryUsageStore: ObservableObject {
    private struct FilePayload: Codable {
        var lastAccess: [String: TimeInterval]
    }

    private let fileURL: URL
    private var lastAccess: [UUID: TimeInterval] = [:]

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("KeyNest", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("entry-usage.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(FilePayload.self, from: data)
        else {
            return
        }
        lastAccess = [:]
        for (k, v) in p.lastAccess {
            if let u = UUID(uuidString: k) {
                lastAccess[u] = v
            }
        }
    }

    private func save() {
        var dict: [String: TimeInterval] = [:]
        for (k, v) in lastAccess {
            dict[k.uuidString] = v
        }
        let p = FilePayload(lastAccess: dict)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func recordAccess(id: UUID) {
        lastAccess[id] = Date().timeIntervalSince1970
        save()
    }

    func remove(id: UUID) {
        lastAccess.removeValue(forKey: id)
        save()
    }

    /// 归一化：删除已不存在的条目 id
    func prune(knownIds: Set<UUID>) {
        let before = lastAccess.count
        lastAccess = lastAccess.filter { knownIds.contains($0.key) }
        if lastAccess.count != before { save() }
    }

    func lastAccessTime(for id: UUID) -> TimeInterval? {
        lastAccess[id]
    }

    /// 最近在前；从未访问的排在后面（按标题序由调用方处理）。
    func sortIdsByRecentFirst(_ ids: [UUID]) -> [UUID] {
        ids.sorted { a, b in
            let ta = lastAccess[a] ?? 0
            let tb = lastAccess[b] ?? 0
            if ta != tb { return ta > tb }
            return a.uuidString < b.uuidString
        }
    }
}
