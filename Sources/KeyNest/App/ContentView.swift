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

/// 首次创建 / 从旧版升级 / 手动更换恢复密钥后展示。
struct RecoveryKeySetupSheet: View {
    let recoveryKey: String
    var headline: String = "请保存恢复密钥"
    var detail: String =
        "若忘记主密码，仅凭本地保管库文件无法找回数据。请立即复制下列密钥并保存在安全处（密码管理器打印稿等）。关闭后将不再完整显示。"
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(headline)
                .font(.title2.bold())
            Text(detail)
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

struct ItemDetailView: View {
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var settings: AppSettingsStore
    @EnvironmentObject private var usage: EntryUsageStore

    let item: PasswordItem
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var passwordRevealed = false
    @State private var showDeleteConfirm = false

    var body: some View {
        Form {
            Section("条目") {
                LabeledContent("标题") {
                    Text(item.title.isEmpty ? "未命名" : item.title)
                        .font(.body.weight(.medium))
                }
                LabeledContent("网站") {
                    Group {
                        if item.url.isEmpty {
                            Text("—")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else if settings.distinguishHostsByIp,
                                  let ep = SiteIdentityService.normalizeEndpoint(item.siteEndpoint),
                                  !ep.isEmpty {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(item.url)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                                Text("环境 IP：\(ep)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            Text(item.url)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity, alignment: .trailing)
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

            if !item.customFields.isEmpty {
                Section("自定义字段") {
                    ForEach(item.customFields) { field in
                        LabeledContent(field.label.isEmpty ? "（未命名）" : field.label) {
                            HStack {
                                Text(field.value.isEmpty ? "—" : field.value)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                if !field.value.isEmpty {
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(field.value, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("复制")
                                }
                            }
                        }
                    }
                }
            }

            if !item.notes.isEmpty {
                Section("备注") {
                    Text(item.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            if PasswordStrength.isWeak(item.password) {
                Section {
                    Text("根据本地规则，当前密码偏短或字符类型较少，建议在网站修改后在此更新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("弱密码提示")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.title.isEmpty ? "未命名" : item.title)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    try? vault.toggleFavorite(id: item.id)
                } label: {
                    Label(item.isFavorite ? "取消收藏" : "收藏", systemImage: item.isFavorite ? "star.fill" : "star")
                }
                .help(item.isFavorite ? "取消收藏" : "加入收藏")
                Button("编辑", action: onEdit)
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .help("删除此条目")
            }
        }
        .confirmationDialog(
            "删除「\(item.title)」？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从本地保管库中移除该条目，且无法撤销。")
        }
        .onAppear {
            usage.recordAccess(id: item.id)
        }
        .onChange(of: item.id) { _, _ in
            passwordRevealed = false
            usage.recordAccess(id: item.id)
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
                        usage.recordAccess(id: item.id)
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
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    let mode: ItemEditorMode
    var onSiteLimitRequired: ((SiteLimitSavePrompt, PasswordItem) -> Void)? = nil

    @State private var siteLimitPrompt: SiteLimitSavePrompt?
    @State private var pendingAddItem: PasswordItem?
    @State private var title: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var url: String = ""
    @State private var siteEndpoint: String = ""
    @State private var notes: String = ""
    @State private var customFields: [CustomField] = []
    @State private var isFavorite: Bool = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("收藏（侧栏优先展示）", isOn: $isFavorite)
                }
                Section("账号") {
                    TextField("标题", text: $title)
                    TextField("用户名", text: $username)
                    LabeledContent("密码") {
                        PasswordFieldWithReveal(placeholder: "密码", text: $password)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    TextField("网站（域名或完整 URL；填充时按主机名匹配）", text: $url)
                        .multilineTextAlignment(.trailing)
                    if settings.distinguishHostsByIp {
                        TextField("环境 IP（hosts 解析，可留空自动填入）", text: $siteEndpoint)
                            .font(.system(.body, design: .monospaced))
                        Button("从网站解析当前 IP") {
                            siteEndpoint = SiteIdentityService.resolveEndpointForUrl(url) ?? ""
                        }
                        .font(.caption)
                    }
                }
                Section {
                    ForEach($customFields) { $field in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            TextField("字段名", text: $field.label)
                                .frame(minWidth: 88)
                            TextField("内容", text: $field.value)
                            Button(role: .destructive) {
                                removeField(id: field.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .help("删除此行")
                        }
                    }
                    Button {
                        customFields.append(CustomField(label: "", value: ""))
                    } label: {
                        Label("添加字段", systemImage: "plus.circle")
                    }
                } header: {
                    Text("自定义字段")
                } footer: {
                    Text("适用于银行卡附加信息、API Key、密保问答等；浏览器扩展填充仍使用上方的用户名与密码。")
                        .font(.caption)
                }

                Section {
                    Menu("插入字段模板") {
                        Button("银行卡（卡号 / 有效期 / CVV / 持卡人）") { applyBankCardTemplate() }
                        Button("API 密钥（Client ID / Secret / Endpoint）") { applyApiTemplate() }
                        Button("密保问题（三组问答）") { applySecurityQATemplate() }
                    }
                }

                Section("备注") {
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 460, minHeight: 420)
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
            .confirmationDialog(
                "站点账号已达上限",
                isPresented: Binding(
                    get: { siteLimitPrompt != nil },
                    set: { if !$0 { siteLimitPrompt = nil; pendingAddItem = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("继续保存", role: .destructive) {
                    confirmLimitAndSave()
                }
                Button("取消", role: .cancel) {
                    siteLimitPrompt = nil
                    pendingAddItem = nil
                }
            } message: {
                Text(siteLimitPrompt?.message ?? "")
            }
        }
    }

    private func confirmLimitAndSave() {
        guard let item = pendingAddItem else { return }
        do {
            if try vault.add(item, allowEvictOldest: true) {
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
        siteLimitPrompt = nil
        pendingAddItem = nil
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
            siteEndpoint = item.siteEndpoint ?? ""
            notes = item.notes
            customFields = item.customFields
            isFavorite = item.isFavorite
        }
    }

    private func removeField(id: UUID) {
        customFields.removeAll { $0.id == id }
    }

    private func appendFieldsIfAbsent(_ pairs: [(String, String)]) {
        for (label, value) in pairs {
            let exists = customFields.contains {
                $0.label.trimmingCharacters(in: .whitespacesAndNewlines) == label
            }
            if !exists {
                customFields.append(CustomField(label: label, value: value))
            }
        }
    }

    private func applyBankCardTemplate() {
        appendFieldsIfAbsent([
            ("卡号", ""),
            ("有效期", ""),
            ("CVV", ""),
            ("持卡人", ""),
        ])
    }

    private func applyApiTemplate() {
        appendFieldsIfAbsent([
            ("Client ID", ""),
            ("Secret", ""),
            ("Endpoint", ""),
        ])
    }

    private func applySecurityQATemplate() {
        appendFieldsIfAbsent([
            ("问题 1", ""),
            ("答案 1", ""),
            ("问题 2", ""),
            ("答案 2", ""),
            ("问题 3", ""),
            ("答案 3", ""),
        ])
    }

    private func save() {
        errorText = nil
        let trimmedFields = customFields.map {
            CustomField(id: $0.id, label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines), value: $0.value)
        }.filter { !$0.label.isEmpty || !$0.value.isEmpty }
        var ep = siteEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.distinguishHostsByIp, ep.isEmpty, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ep = SiteIdentityService.resolveEndpointForUrl(url) ?? ""
        }
        let endpointStored: String? = ep.isEmpty ? nil : ep
        do {
            switch mode {
            case .add:
                let item = PasswordItem(
                    title: title,
                    username: username,
                    password: password,
                    url: url,
                    siteEndpoint: endpointStored,
                    notes: notes,
                    customFields: trimmedFields,
                    isFavorite: isFavorite
                )
                if let prompt = vault.siteLimitSavePrompt(for: item) {
                    if let cb = onSiteLimitRequired {
                        cb(prompt, item)
                        return
                    }
                    siteLimitPrompt = prompt
                    pendingAddItem = item
                    return
                }
                guard try vault.add(item) else {
                    if let prompt = vault.siteLimitSavePrompt(for: item) {
                        siteLimitPrompt = prompt
                        pendingAddItem = item
                    } else {
                        errorText = "保存失败：未能写入保管库（请检查站点账号上限设置）。"
                    }
                    return
                }
            case .edit(let original):
                try vault.update(
                    PasswordItem(
                        id: original.id,
                        title: title,
                        username: username,
                        password: password,
                        url: url,
                        siteEndpoint: endpointStored,
                        notes: notes,
                        customFields: trimmedFields,
                        isFavorite: isFavorite
                    )
                )
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
