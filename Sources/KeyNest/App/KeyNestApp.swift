import AppKit
import SwiftUI

@main
struct KeyNestApp: App {
    @StateObject private var vault = VaultStore()
    @StateObject private var bridge = LocalTCPBridge()
    @AppStorage("bridgeEnabled") private var bridgeEnabled = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vault)
                .environmentObject(bridge)
                .onAppear {
                    bridge.attach(vault: vault)
                    syncBridge()
                }
                .onChange(of: vault.isUnlocked) { _, _ in
                    syncBridge()
                }
                .onChange(of: bridgeEnabled) { _, _ in
                    syncBridge()
                }
        }
        .defaultSize(width: 900, height: 600)

        MenuBarExtra("KeyNest", systemImage: "key.horizontal.fill") {
            KeyNestMenuBarExtraContent()
                .environmentObject(vault)
                .environmentObject(bridge)
        }
        .menuBarExtraStyle(.menu)
    }

    private func syncBridge() {
        Self.syncKeyNestBridge(vault: vault, bridge: bridge, bridgeEnabled: bridgeEnabled)
    }

    /// 供主窗口与菜单栏共用，保证桥接状态一致。
    static func syncKeyNestBridge(vault: VaultStore, bridge: LocalTCPBridge, bridgeEnabled: Bool) {
        bridge.attach(vault: vault)
        if vault.isUnlocked && bridgeEnabled {
            bridge.start()
        } else {
            bridge.stop()
        }
    }
}

/// 菜单栏图标下拉内容（运行时常驻于屏幕右上角）。
private struct KeyNestMenuBarExtraContent: View {
    @EnvironmentObject private var vault: VaultStore
    @EnvironmentObject private var bridge: LocalTCPBridge
    @AppStorage("bridgeEnabled") private var bridgeEnabled = true

    var body: some View {
        Group {
            Button("打开主窗口") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                for window in NSApplication.shared.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                }
            }

            Button("锁定保管库") {
                vault.lock()
            }
            .disabled(!vault.isUnlocked)

            Divider()

            Toggle("浏览器桥接（端口 17373）", isOn: $bridgeEnabled)

            Divider()

            Button("退出 KeyNest") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onChange(of: bridgeEnabled) { _, _ in
            KeyNestApp.syncKeyNestBridge(vault: vault, bridge: bridge, bridgeEnabled: bridgeEnabled)
        }
        .onChange(of: vault.isUnlocked) { _, _ in
            KeyNestApp.syncKeyNestBridge(vault: vault, bridge: bridge, bridgeEnabled: bridgeEnabled)
        }
    }
}
