import Foundation

/// 极简日志。
///
/// **默认就写文件**：后台常驻工具出了问题必须有据可查，
/// 靠 `open` 启动时 stderr 是看不见的。
///
/// 位置：`~/Library/Application Support/com.local.paste/paste.log`
/// 超过 512 KB 自动轮转成 `paste.log.1`。
///
/// 想改路径（比如临时调试）就设环境变量：
///
///     PASTE_LOG_FILE=/tmp/paste.log open Paste.app
enum Log {
    private static let maxBytes = 512 * 1024

    private static let fileHandle: FileHandle? = {
        let path: String
        if let override = ProcessInfo.processInfo.environment["PASTE_LOG_FILE"] {
            path = override
        } else {
            // 只有真正的 app bundle 才写默认日志文件。
            // 逻辑测试那个二进制没有 bundle id，否则会往应用日志里写测试输出的内容，
            // 排查真问题时会被干扰。
            guard Bundle.main.bundleIdentifier != nil else { return nil }
            guard let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            let directory = base.appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.local.paste",
                isDirectory: true
            )
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            path = directory.appendingPathComponent("paste.log").path
        }

        // 太大就轮转，避免无限增长
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attributes[.size] as? Int,
           size > maxBytes {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }

        FileManager.default.createFile(atPath: path, contents: nil)
        // 日志里会记剪贴板条目的片段，同样收紧到只有本人可读
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path
        )
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }()

    static var filePath: String? {
        if let override = ProcessInfo.processInfo.environment["PASTE_LOG_FILE"] {
            return override
        }
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return fileHandle.map { _ in
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.local.paste")
                .appendingPathComponent("paste.log").path
        } ?? nil
    }

    static func info(_ message: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        let line = Data("[\(stamp)] \(message)\n".utf8)
        FileHandle.standardError.write(line)
        fileHandle?.write(line)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

/// 仅用于开发验证的开关，全部通过环境变量控制，正常使用不会碰到。
enum DebugFlags {
    /// 干跑模式：假装有「辅助功能」权限，走完自动粘贴的全部后续流程
    /// （包括恢复原剪贴板），但**不真的合成按键**，不会污染当前前台 App。
    ///
    ///     PASTE_DEBUG_DRY_RUN=1 ./Paste.app/Contents/MacOS/Paste
    static var dryRun: Bool {
        ProcessInfo.processInfo.environment["PASTE_DEBUG_DRY_RUN"] == "1"
    }

    /// 每次呼出面板时自动填好的搜索词，用来验证过滤和搜索框渲染。
    ///
    ///     PASTE_DEBUG_QUERY=git ./Paste.app/Contents/MacOS/Paste
    static var query: String? {
        guard let value = ProcessInfo.processInfo.environment["PASTE_DEBUG_QUERY"],
              !value.isEmpty else { return nil }
        return value
    }

    /// 启动时顺带切换「开机自启」，用来在没有 GUI 的环境里验证 SMAppService。
    /// 取值 `enable` / `disable`，其它值只打印当前状态。
    ///
    ///     PASTE_DEBUG_LOGIN_ITEM=enable open Paste.app
    static var loginItemAction: String? {
        ProcessInfo.processInfo.environment["PASTE_DEBUG_LOGIN_ITEM"]
    }

    /// 把面板实际显示的条目打进日志。
    ///
    /// 会把剪贴板内容写进日志文件，所以**默认关闭**，只在排查
    /// 「面板里看不到刚复制的内容」这类问题时临时打开：
    ///
    ///     launchctl setenv PASTE_DEBUG_LOG_CONTENT 1
    ///     open /Applications/Paste.app
    static var logContent: Bool {
        ProcessInfo.processInfo.environment["PASTE_DEBUG_LOG_CONTENT"] == "1"
    }

    /// 按回车提交的**那一刻**把面板渲染存成 PNG。
    ///
    /// 这是排查「选中的行和粘出来的不一致」唯一可靠的办法：
    /// 截图给出「哪一行是高亮的」，日志给出「提交了哪一条」，
    /// 两者一比就知道是选错了还是送错了。
    ///
    ///     launchctl setenv PASTE_DEBUG_SNAPSHOT 1
    ///     open /Applications/Paste.app
    static var snapshotOnCommit: Bool {
        ProcessInfo.processInfo.environment["PASTE_DEBUG_SNAPSHOT"] == "1"
    }

    /// 呼出面板时把选中项直接设成第 N 条（0 基），延迟后自动截图。
    ///
    /// 用来隔离验证「高亮是否跟着 selectedIndex 走」：
    /// 排除了按键时序的干扰，如果高亮还是错位，那就是渲染本身的问题。
    ///
    ///     launchctl setenv PASTE_DEBUG_SELECT 4
    static var selectOnShow: Int? {
        guard let raw = ProcessInfo.processInfo.environment["PASTE_DEBUG_SELECT"],
              let value = Int(raw) else { return nil }
        return value
    }
}
