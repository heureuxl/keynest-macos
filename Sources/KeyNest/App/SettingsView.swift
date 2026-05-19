import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var maxAccountsText = ""
    @State private var distinguishByIp = true
    @State private var errorText: String?
    @State private var confirmRotateRecovery = false
    @State private var rotatedRecoveryKey: String?
    @State private var mergeNotice: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("同一网站（主机名）下最多保留的不同用户名账号数")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("上限", text: $maxAccountsText)
                        .frame(maxWidth: 120)
                    Text("范围 \(AppSettingsStore.minMaxAccounts)–\(AppSettingsStore.maxMaxAccounts)；保存后对保管库立即生效。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } header: {
                    Text("保管库")
                }

                Section {
                    Toggle("按 hosts / DNS 解析 IP 区分同一域名", isOn: $distinguishByIp)
                    Text("开启后：同一域名指向不同 IP 时，账号分开保存与填充；修改 hosts 后会自动匹配对应环境。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("测试环境（hosts）")
                }

                Section {
                    Button("合并重复条目") {
                        runMergeDuplicates()
                    }
                    .disabled(!vault.isUnlocked)

                    Button("更换恢复密钥") {
                        confirmRotateRecovery = true
                    }
                    .disabled(!vault.isUnlocked)

                    Text("更换恢复密钥后，旧密钥立即失效，请务必保存新密钥。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("整理与安全")
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 440, minHeight: 420)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: saveSettings).keyboardShortcut(.defaultAction)
                }
            }
            .onAppear {
                maxAccountsText = String(settings.maxAccountsPerSiteHost)
                distinguishByIp = settings.distinguishHostsByIp
            }
            .confirmationDialog("更换恢复密钥", isPresented: $confirmRotateRecovery, titleVisibility: .visible) {
                Button("确定更换", role: .destructive) { rotateRecovery() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("更换成功后，旧恢复密钥将立即失效。请务必保存即将展示的新密钥。")
            }
            .alert("整理结果", isPresented: Binding(
                get: { mergeNotice != nil },
                set: { if !$0 { mergeNotice = nil } }
            )) {
                Button("好", role: .cancel) { mergeNotice = nil }
            } message: {
                Text(mergeNotice ?? "")
            }
            .sheet(isPresented: Binding(
                get: { rotatedRecoveryKey != nil },
                set: { if !$0 { rotatedRecoveryKey = nil } }
            )) {
                RecoveryKeySetupSheet(
                    recoveryKey: rotatedRecoveryKey ?? "",
                    headline: "请保存新的恢复密钥",
                    detail: "旧的恢复密钥已失效，找回主密码仅能使用下列新密钥。",
                    onConfirm: { rotatedRecoveryKey = nil }
                )
            }
        }
    }

    private func saveSettings() {
        errorText = nil
        guard let n = Int(maxAccountsText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorText = "请输入有效整数。"
            return
        }
        settings.save(
            maxAccountsPerSiteHost: n,
            distinguishHostsByIp: distinguishByIp
        )
        if vault.isUnlocked {
            do {
                try vault.enforceLimitsAndPersist()
            } catch {
                errorText = error.localizedDescription
                return
            }
        }
        dismiss()
    }

    private func runMergeDuplicates() {
        guard vault.isUnlocked else {
            errorText = "请先解锁保管库。"
            return
        }
        errorText = nil
        do {
            let n = try vault.mergeDuplicateHostUsernames()
            mergeNotice = n > 0
                ? "已合并删除 \(n) 条重复条目。"
                : "当前没有可合并的重复条目。"
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func rotateRecovery() {
        errorText = nil
        do {
            rotatedRecoveryKey = try vault.rotateRecoveryKey()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
