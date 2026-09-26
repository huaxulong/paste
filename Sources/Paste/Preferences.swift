import Foundation

/// 用户偏好。
///
/// `store` 可替换，方便测试时用独立的 UserDefaults suite，不污染真实配置。
enum Preferences {
    static var store: UserDefaults = .standard

    private enum Key {
        static let autoPaste = "autoPaste"
        static let restoreClipboard = "restoreClipboard"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    static func registerDefaults() {
        store.register(defaults: [
            Key.autoPaste: true,
            Key.restoreClipboard: true,
            // 默认**不显示**菜单栏图标：Paste 只通过 Ctrl+V 使用。
            // 想开回来（需要在终端里执行，因为没图标就点不到菜单）：
            //   defaults write com.local.paste showMenuBarIcon -bool true
            // 然后重启应用。
            Key.showMenuBarIcon: false,
        ])
    }

    /// 选中后自动合成 Cmd+V（需要「辅助功能」权限）
    static var autoPaste: Bool {
        get { store.bool(forKey: Key.autoPaste) }
        set { store.set(newValue, forKey: Key.autoPaste) }
    }

    /// 是否在菜单栏显示图标。
    ///
    /// 默认关闭。**注意：关掉之后菜单就点不到了**，包括这个开关本身 ——
    /// 所以只能用 `defaults write` 在终端里改回来。
    static var showMenuBarIcon: Bool {
        get { store.bool(forKey: Key.showMenuBarIcon) }
        set { store.set(newValue, forKey: Key.showMenuBarIcon) }
    }

    /// 粘贴完成后，把剪贴板恢复成用户原来的内容
    static var restoreClipboard: Bool {
        get { store.bool(forKey: Key.restoreClipboard) }
        set { store.set(newValue, forKey: Key.restoreClipboard) }
    }
}
