import ServiceManagement

/// 开机自启。
///
/// `SMAppService.mainApp` 要求 macOS 13+（我们的最低版本就是 13）。
/// App 如果不在 `/Applications` 或者签名不完整，`register()` 可能抛错，
/// 所以调用方要把失败信息打到日志里，而不是假装成功。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已开启"
        case .notRegistered: return "未开启"
        case .notFound: return "找不到 App（挪到「应用程序」里再试）"
        case .requiresApproval: return "需要在「登录项」里批准"
        @unknown default: return "未知状态"
        }
    }

    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
