import AppKit
import ApplicationServices

/// 「辅助功能」权限。
///
/// 只有**自动粘贴**需要它（合成 Cmd+V 会被系统拦下）。
/// 全局热键走的是 Carbon，不需要任何权限；只有合成按键才需要「辅助功能」。
/// 所以没授权时应用依然可用，只是粘贴那一步要你自己按 Cmd+V。
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹系统引导对话框「Paste 想要控制这台电脑」。
    /// 同一进程内系统只会真正弹一次，多调无副作用。
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 直接跳到「系统设置 → 隐私与安全性 → 辅助功能」
    static func openSystemSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
