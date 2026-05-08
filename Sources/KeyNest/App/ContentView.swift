import AppKit
import SwiftUI

/// 带眼睛开关的密码输入：默认圆点掩码，可切换为明文编辑。
private struct PasswordFieldWithReveal: View {
    var placeholder: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
            }
            .buttonStyle(.borderless)
            .help(revealed ? "隐藏密码" : "显示密码")
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var vault: VaultStore

    private var pendingRecoveryPresented: Binding<Bool> {
        Binding(
            get: { vault.pendingRecoveryKeyToDisplay != nil },
            set: { new in
                if !new {
                    vault.acknowledgeRecoveryKeySaved()
                }
            }
        )
    }

    var body: some View {
        Group {
            if vault.isUnlocked {
                MainVaultView()
            } else {
                LockView()
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(isPresented: pendingRecoveryPresented) {
            RecoveryKeySetupSheet(
                recoveryKey: vault.pendingRecoveryKeyToDisplay ?? "",
                onConfirm: { vault.acknowledgeRecoveryKeySaved() }
            )
        }
    }
}

/// 首次创建或从旧版升级后，仅此一次展示恢复密钥。
private struct RecoveryKeySetupSheet: View {
    let recoveryKey: String
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("请保存恢复密钥")
                .font(.title2.bold())
            Text("若忘记主密码，仅凭本地保管库文件无法找回数据。请立即复制下列密钥并保存在安全处（密码管理器打印稿等）。关闭后将不再完整显示。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(recoveryKey)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                .cornerRadius(8)
            HStack {
                Button("复制密钥") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recoveryKey, forType: .string)
                }
                Spacer()
                Button("我已安全保存", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }
}

struct LockView: View {
    @EnvironmentObject private var vault: VaultStore
    @State private var password = ""
    @State private var errorText: String?
    @State private var showRecoverySheet = false

    var body: some View {
        VStack(spacing: 20) {
            Text("KeyNest")
                .font(.largeTitle.bold())
            Text(vault.vaultExists ? "输入主密码以解锁保管库" : "创建主密码以初始化本地加密保管库")
                .foregroundStyle(.secondary)
            PasswordFieldWithReveal(placeholder: "主密码", text: $password)
                .frame(maxWidth: 360)
                .onSubmit(attemptUnlock)
            Button(vault.vaultExists ? "解锁" : "创建并解锁", action: attemptUnlock)
                .keyboardShortcut(.defaultAction)
            if vault.vaultExists {
                Button("忘记主密码？使用恢复密钥") {
                    showRecoverySheet = true
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(40)
        .sheet(isPresented: $showRecoverySheet) {
            RecoveryUnlockSheet(onDone: { showRecoverySheet = false })
                .environmentObject(vault)
        }
    }

    private func attemptUnlock() {
        errorText = nil
        do {
            try vault.unlock(password: password)
            password = ""
        } catch let error as VaultCryptoError where error == .wrongMasterPassword {
            errorText = "主密码不正确"
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct RecoveryUnlockSheet: View {
    @EnvironmentObject private var vault: VaultStore
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void

    @State private var recoveryPhrase = ""
    @State private var newMaster = ""
    @State private var newMaster2 = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("输入当初保存的恢复密钥（Base64 文本），并设置新的主密码。无法连接互联网，数据仍在本地。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("恢复密钥") {
                    TextField("粘贴完整恢复密钥", text: $recoveryPhrase, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.system(.body, design: .monospaced))
                }
                Section("新主密码") {
                    PasswordFieldWithReveal(placeholder: "新主密码", text: $newMaster)
                    PasswordFieldWithReveal(placeholder: "确认新主密码", text: $newMaster2)
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 460, minHeight: 420)
            .navigationTitle("使用恢复密钥")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                        onDone()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("重置并解锁") {
                        submitRecovery()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func submitRecovery() {
        errorText = nil
        guard !recoveryPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorText = "请填写恢复密钥"
            return
        }
        guard newMaster.count >= 8 else {
            errorText = "新主密码至少 8 位"
            return
        }
        guard newMaster == newMaster2 else {
            errorText = "两次输入的新主密码不一致"
            return
        }
        do {
            try vault.unlockWithRecovery(recoveryKeyPhrase: recoveryPhrase, newMasterPassword: newMaster)
            dismiss()
            onDone()
        } catch let e as VaultCryptoError where e == .wrongRecoveryKey {
            errorText = "恢复密钥不正确或保管库尚未升级到支持恢复的格式"
        } catch let e as VaultCryptoError where e == .invalidVaultFormat {
            errorText = "保管库格式过旧：请先回忆主密码成功解锁一次以自动升级"
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct MainVaultView: View {
    @EnvironmentObject private var vault: VaultStore
    @AppStorage("bridgeEnabled") private var bridgeEnabled = true
    @State private var selection: UUID?
    @State private var showingAdd = false
    @State private var editingItem: PasswordItem?

    var body: some View {
        NavigationSplitView {
            List(vault.items, id: \.id, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                    Text(MainVaultView.sidebarSubtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(Optional(item.id))
            }
            .navigationTitle("密码条目")
            .toolbar {
                ToolbarItemGroup {
                    Button("添加", systemImage: "plus") {
                        showingAdd = true
                    }
                    Button("锁定", systemImage: "lock.fill") {
                        vault.lock()
                        selection = nil
                    }
                }
            }
            .frame(minWidth: 240)
        } detail: {
            Group {
                if let id = selection, let item = vault.items.first(where: { $0.id == id }) {
                    ItemDetailView(item: item, onEdit: { editingItem = item })
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "key.horizontal")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("选择一条记录")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    /// 侧栏第二行：用户名与域名对齐展示。
    private static func sidebarSubtitle(for item: PasswordItem) -> String {
        let host = URL(string: item.url)?.host
        if !item.username.isEmpty {
            if let host, !host.isEmpty {
                return "\(item.username) · \(host)"
            }
            return item.username
        }
        if let host, !host.isEmpty { return host }
        let u = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? " " : u
    }
}

struct ItemDetailView: View {
    let item: PasswordItem
    var onEdit: () -> Void
    @State private var passwordRevealed = false

    var body: some View {
        Form {
            Section("条目") {
                LabeledContent("标题") {
                    Text(item.title)
                        .font(.body.weight(.medium))
                }
                LabeledContent("网站") {
                    Group {
                        if item.url.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            Text(item.url)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            Section("账号") {
                LabeledContent("用户名") {
                    Text(item.username.isEmpty ? "—" : item.username)
                        .textSelection(.enabled)
                }
            }

            Section {
                passwordPanel
            } header: {
                Text("密码")
            } footer: {
                Text("密码默认以掩码显示；展开后可复制。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !item.notes.isEmpty {
                Section("备注") {
                    Text(item.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.title)
        .toolbar {
            Button("编辑", action: onEdit)
        }
        .onChange(of: item.id) { _, _ in
            passwordRevealed = false
        }
    }

    private var passwordPanel: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if passwordRevealed {
                    Text(item.password)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                } else if item.password.isEmpty {
                    Text("—")
                        .foregroundStyle(.secondary)
                } else {
                    Text(maskedPasswordDots)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            VStack(spacing: 10) {
                Button {
                    passwordRevealed.toggle()
                } label: {
                    Image(systemName: passwordRevealed ? "eye.slash.fill" : "eye.fill")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .help(passwordRevealed ? "隐藏密码" : "显示密码")

                if !item.password.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.password, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .help("复制密码")
                }
            }
            .padding(.trailing, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var maskedPasswordDots: String {
        let n = item.password.count
        let cap = 32
        return String(repeating: "•", count: min(n, cap)) + (n > cap ? "…" : "")
    }
}

enum ItemEditorMode: Identifiable {
    case add
    case edit(PasswordItem)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let i): return i.id.uuidString
        }
    }
}

struct ItemEditorSheet: View {
    @EnvironmentObject private var vault: VaultStore
    @Environment(\.dismiss) private var dismiss

    let mode: ItemEditorMode

    @State private var title: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var url: String = ""
    @State private var notes: String = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                TextField("用户名", text: $username)
                LabeledContent("密码") {
                    PasswordFieldWithReveal(placeholder: "密码", text: $password)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                TextField("网站 URL（用于自动填充匹配）", text: $url)
                TextField("备注", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420, minHeight: 360)
            .navigationTitle(navTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).keyboardShortcut(.defaultAction)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var navTitle: String {
        switch mode {
        case .add: return "新建条目"
        case .edit: return "编辑条目"
        }
    }

    private func load() {
        switch mode {
        case .add:
            break
        case .edit(let item):
            title = item.title
            username = item.username
            password = item.password
            url = item.url
            notes = item.notes
        }
    }

    private func save() {
        errorText = nil
        do {
            switch mode {
            case .add:
                try vault.add(PasswordItem(title: title, username: username, password: password, url: url, notes: notes))
            case .edit(let original):
                try vault.update(
                    PasswordItem(
                        id: original.id,
                        title: title,
                        username: username,
                        password: password,
                        url: url,
                        notes: notes
                    )
                )
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
