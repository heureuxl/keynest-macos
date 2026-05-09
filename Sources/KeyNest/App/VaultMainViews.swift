import AppKit
import SwiftUI

private enum VaultListFilter: String, CaseIterable {
    case all = "全部"
    case favorites = "收藏"
    case recent = "最近使用"
    case emptyPassword = "空密码"
    case weakPassword = "弱密码"
}

private enum VaultListLayoutMode: String, CaseIterable {
    case flat = "列表"
    case byHost = "按域名分组"
}

struct MainVaultView: View {
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var usage: EntryUsageStore

    @AppStorage("bridgeEnabled") private var bridgeEnabled = true
    @State private var selection: UUID?
    @State private var showingAdd = false
    @State private var editingItem: PasswordItem?
    @State private var deleteError: String?
    @State private var confirmRotateRecovery = false
    @State private var rotatedRecoveryKeyToShow: String?
    @State private var rotateRecoveryError: String?
    @State private var searchText = ""
    @State private var listFilter: VaultListFilter = .all
    @State private var layoutMode: VaultListLayoutMode = .flat
    @State private var mergeNotice: String?

    private var searchTokens: [String] {
        searchText.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    private func sortPair(_ a: PasswordItem, _ b: PasswordItem) -> Bool {
        if a.isFavorite != b.isFavorite { return a.isFavorite && !b.isFavorite }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    private var baseFiltered: [PasswordItem] {
        let all = vault.items
        switch listFilter {
        case .all: return all
        case .favorites: return all.filter(\.isFavorite)
        case .recent: return all
        case .emptyPassword: return all.filter { $0.password.isEmpty }
        case .weakPassword: return all.filter { PasswordStrength.isWeak($0.password) }
        }
    }

    private var displayItems: [PasswordItem] {
        var list = baseFiltered
        if !searchTokens.isEmpty {
            list = list.filter { $0.matchesSearchTokens(searchTokens) }
        }
        if listFilter == .recent {
            let order = usage.sortIdsByRecentFirst(list.map(\.id))
            let map = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            return order.compactMap { map[$0] }
        }
        return list.sorted(by: sortPair)
    }

    private var groupedSections: [(hostKey: String, title: String, items: [PasswordItem])] {
        let items = displayItems
        var dict: [String: [PasswordItem]] = [:]
        var order: [String] = []
        for it in items {
            let key = VaultStore.normalizedSiteHostKey(it.url) ?? "__none__"
            if dict[key] == nil { order.append(key) }
            dict[key, default: []].append(it)
        }
        return order.map { k in
            let title = k == "__none__" ? "无网站" : k
            let sorted = dict[k]!.sorted(by: sortPair)
            return (hostKey: k, title: title, items: sorted)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                filterBar
                Group {
                    if layoutMode == .byHost {
                        hostGroupedList
                    } else {
                        flatList
                    }
                }
            }
            .navigationTitle("密码条目")
            .searchable(text: $searchText, prompt: "搜索标题、用户名、网站、备注、扩展字段…")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .help("添加条目")

                    Menu("整理", systemImage: "arrow.3.trianglepath") {
                        Button("合并重复（同站点同用户名）") {
                            runMergeDuplicates()
                        }
                    }
                    .help("批量整理")

                    Button {
                        confirmRotateRecovery = true
                    } label: {
                        Label("更换恢复密钥", systemImage: "key.rotate.fill")
                    }
                    .help("生成新恢复密钥短语，旧短语立即作废")

                    Button {
                        vault.lock()
                        selection = nil
                    } label: {
                        Label("锁定", systemImage: "lock.fill")
                    }
                    .help("锁定保管库")
                }
            }
            .confirmationDialog(
                "更换恢复密钥",
                isPresented: $confirmRotateRecovery,
                titleVisibility: .visible
            ) {
                Button("确定更换", role: .destructive) {
                    rotateRecoveryError = nil
                    do {
                        let phrase = try vault.rotateRecoveryKey()
                        rotatedRecoveryKeyToShow = phrase
                    } catch {
                        rotateRecoveryError = error.localizedDescription
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("更换成功后，旧恢复密钥将立即失效，无法再用于找回主密码。请务必保存即将展示的新密钥。")
            }
            .alert("删除失败", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("好", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .alert("更换恢复密钥失败", isPresented: Binding(
                get: { rotateRecoveryError != nil },
                set: { if !$0 { rotateRecoveryError = nil } }
            )) {
                Button("好", role: .cancel) { rotateRecoveryError = nil }
            } message: {
                Text(rotateRecoveryError ?? "")
            }
            .alert("整理结果", isPresented: Binding(
                get: { mergeNotice != nil },
                set: { if !$0 { mergeNotice = nil } }
            )) {
                Button("好", role: .cancel) { mergeNotice = nil }
            } message: {
                Text(mergeNotice ?? "")
            }
            .frame(minWidth: 280)
        } detail: {
            Group {
                if let id = selection, let item = vault.items.first(where: { $0.id == id }) {
                    ItemDetailView(item: item, onEdit: { editingItem = item }, onDelete: { deleteEntry(id: item.id) })
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "key.horizontal")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("选择一条记录")
                            .foregroundStyle(.secondary)
                        Text("提示：在列表中用上/下键选择，按回车复制密码")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: Binding(
            get: { rotatedRecoveryKeyToShow != nil },
            set: { if !$0 { rotatedRecoveryKeyToShow = nil } }
        )) {
            RecoveryKeySetupSheet(
                recoveryKey: rotatedRecoveryKeyToShow ?? "",
                headline: "请保存新的恢复密钥",
                detail: "旧的恢复密钥已失效，找回主密码仅能使用下列新密钥。请立即复制并妥善保管。",
                onConfirm: { rotatedRecoveryKeyToShow = nil }
            )
        }
        .sheet(isPresented: $showingAdd) {
            ItemEditorSheet(mode: .add)
        }
        .sheet(item: $editingItem) { item in
            ItemEditorSheet(mode: .edit(item))
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Toggle("允许浏览器扩展连接本机端口 17373", isOn: $bridgeEnabled)
                    .toggleStyle(.switch)
                    .font(.caption)
                Spacer()
                Text("仅在解锁时监听；凭据不离开本机。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onAppear {
            usage.prune(knownIds: Set(vault.items.map(\.id)))
            ensureSelectionValid()
        }
        .onChange(of: vault.items.count) { _, _ in
            usage.prune(knownIds: Set(vault.items.map(\.id)))
            ensureSelectionValid()
        }
        .onChange(of: listFilter) { _, _ in ensureSelectionValid() }
        .onChange(of: layoutMode) { _, _ in ensureSelectionValid() }
        .onChange(of: searchText) { _, _ in ensureSelectionValid() }
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("范围", selection: $listFilter) {
                    ForEach(VaultListFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 148)

                Picker("布局", selection: $layoutMode) {
                    ForEach(VaultListLayoutMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 120)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Text(filterCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
    }

    private var filterCaption: String {
        switch listFilter {
        case .all:
            return "共 \(displayItems.count) 条"
        case .favorites:
            return "收藏 \(displayItems.count) 条"
        case .recent:
            return "按最近打开/复制排序 · \(displayItems.count) 条"
        case .emptyPassword:
            return "密码为空的条目 · \(displayItems.count) 条"
        case .weakPassword:
            return "本地规则判定为弱密码 · \(displayItems.count) 条"
        }
    }

    private var flatList: some View {
        List(selection: $selection) {
            ForEach(displayItems) { item in
                sidebarRow(for: item)
                    .tag(Optional(item.id))
                    .contextMenu {
                        Button("切换收藏") {
                            toggleFavorite(item)
                        }
                        Button("复制密码") {
                            copyPassword(for: item.id)
                        }
                        Divider()
                        Button("删除", systemImage: "trash", role: .destructive) {
                            deleteEntry(id: item.id)
                        }
                    }
            }
            .onDelete(perform: deleteItemsAtOffsets)
        }
        .listStyle(.sidebar)
        .focusable()
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.return) {
            copyPasswordForSelection()
            return .handled
        }
    }

    private var hostGroupedList: some View {
        List(selection: $selection) {
            ForEach(groupedSections, id: \.hostKey) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        sidebarRow(for: item)
                            .tag(Optional(item.id))
                            .contextMenu {
                                Button("切换收藏") {
                                    toggleFavorite(item)
                                }
                                Button("复制密码") {
                                    copyPassword(for: item.id)
                                }
                                Divider()
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    deleteEntry(id: item.id)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .focusable()
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.return) {
            copyPasswordForSelection()
            return .handled
        }
    }

    @ViewBuilder
    private func sidebarRow(for item: PasswordItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                toggleFavorite(item)
            } label: {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavorite ? .yellow : .secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(item.isFavorite ? "取消收藏" : "收藏")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.isEmpty ? "未命名" : item.title)
                    .font(.headline)
                if !item.username.isEmpty {
                    Text(item.username)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let site = Self.sidebarSiteAddress(for: item)
            if !site.isEmpty {
                Text(site)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 200, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private func toggleFavorite(_ item: PasswordItem) {
        do {
            try vault.toggleFavorite(id: item.id)
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func runMergeDuplicates() {
        do {
            let n = try vault.mergeDuplicateHostUsernames()
            mergeNotice =
                n > 0 ? "已合并删除 \(n) 条重复条目（同站点同用户名仅保留最新一条）。" : "当前没有可合并的重复条目。"
        } catch {
            mergeNotice = error.localizedDescription
        }
    }

    private func ensureSelectionValid() {
        let ids = Set(displayItems.map(\.id))
        if let s = selection, ids.contains(s) { return }
        selection = displayItems.first?.id
    }

    private func moveSelection(_ delta: Int) {
        let ids = displayItems.map(\.id)
        guard !ids.isEmpty else { return }
        if let s = selection, let idx = ids.firstIndex(of: s) {
            let next = max(0, min(ids.count - 1, idx + delta))
            selection = ids[next]
        } else {
            selection = ids.first
        }
    }

    private func copyPasswordForSelection() {
        guard let id = selection else { return }
        copyPassword(for: id)
    }

    private func copyPassword(for id: UUID) {
        guard let item = vault.items.first(where: { $0.id == id }),
              !item.password.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.password, forType: .string)
        usage.recordAccess(id: id)
    }

    private func deleteEntry(id: UUID) {
        do {
            try vault.remove(id: id)
            usage.remove(id: id)
            if selection == id {
                selection = nil
            }
            ensureSelectionValid()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func deleteItemsAtOffsets(_ offsets: IndexSet) {
        let snapshot = displayItems
        for index in offsets {
            guard snapshot.indices.contains(index) else { continue }
            deleteEntry(id: snapshot[index].id)
        }
    }

    private static func sidebarSiteAddress(for item: PasswordItem) -> String {
        let trimmed = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var s = trimmed
        if !s.contains("://") {
            s = "https://" + s
        }
        if let host = URL(string: s)?.host, !host.isEmpty {
            return host
        }
        return trimmed
    }
}
