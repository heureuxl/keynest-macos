import AppKit
import Foundation

/// 若已有 KeyNest 实例在运行，则激活其窗口并返回 false（调用方应退出）。
enum SingleInstanceGuard {
    @discardableResult
    static func activateExistingIfNeeded() -> Bool {
        guard let bid = Bundle.main.bundleIdentifier else { return true }
        let pid = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != pid }
        guard let existing = others.first else { return true }
        existing.activate(options: [.activateAllWindows])
        return false
    }
}
