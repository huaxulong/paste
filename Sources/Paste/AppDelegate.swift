import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: ClipStore
    private let monitor = ClipboardMonitor()
    private let hotKey = HotKeyManager()

    private var panelController: PanelController?
    private var statusItem: NSStatusItem?
    private var statusItemRefreshTimer: Timer?
    private var toggleSignal: DispatchSourceSignal?
    private var commitSignal: DispatchSourceSignal?
    private var snapshotSignal: DispatchSourceSignal?

    override init() {
        store = ClipStore(persistence: ClipPersistence.defaultStore())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()

        let controller = PanelController(store: store, monitor: monitor)
        panelController = controller

        // 1) 剪贴板监听
        monitor.onNewItem = { [weak self] item in
            self?.handleCaptured(item)
        }
        monitor.start()


        // 2) 全局热键 Ctrl+V
        hotKey.onTrigger = { [weak controller] in
            controller?.toggle()
        }
        if hotKey.registerCtrlV() {
            Log.info("Ctrl+V 注册成功")
        } else {
            Log.info("Ctrl+V 注册失败：可能已被其他 App 占用")
        }

        // 3) 菜单栏图标（默认不显示，见 Preferences.showMenuBarIcon）
        if Preferences.showMenuBarIcon {
            setupStatusItem()
            startStatusItemRefreshTimer()
            Log.info("菜单栏图标：显示")
        } else {
            Log.info("菜单栏图标：隐藏（只通过 Ctrl+V 使用；要开回来见 README）")
        }

        // 4) 调试钩子
        installDebugSignalHooks(controller)

        // 5) 调试：无 GUI 环境下切换开机自启
        if let action = DebugFlags.loginItemAction {
            let enable = (action == "enable")
            Log.info("调试：把开机自启设为 \(enable)")
            switch LoginItem.setEnabled(enable) {
            case .success:
                Log.info("调试：设置成功，当前状态 \(LoginItem.statusDescription)")
            case .failure(let error):
                Log.info("调试：设置失败 — \(error.localizedDescription)")
            }
        }

        Log.info("恢复历史 \(store.items.count) 条")
        Log.info("辅助功能权限：\(Accessibility.isTrusted ? "已授权，自动粘贴可用" : "未授权，选中后需手动按 Cmd+V")")
        logBundleSanity()
        Log.info("设置：自动粘贴=\(Preferences.autoPaste)，恢复剪贴板=\(Preferences.restoreClipboard)")
        Log.info("开机自启：\(LoginItem.statusDescription)")
        Log.info("已启动，等待 Ctrl+V")
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        hotKey.unregister()
    }

    /// 检查自己的可执行文件是否还在磁盘上。
    ///
    /// 这不是多余的：如果 bundle 在进程运行期间被删掉，进程会靠已删除的 inode 继续活着，
    /// 而 **TCC 无法校验一个磁盘上不存在的二进制**，于是 `AXIsProcessTrusted()` 永远是 false，
    /// 用户在系统设置里怎么授权都没用，且现象上完全看不出来。
    private func logBundleSanity() {
        let bundle = Bundle.main.bundleURL.path
        let executable = Bundle.main.executablePath ?? ""

        guard FileManager.default.fileExists(atPath: executable) else {
            Log.info("🚨 严重：可执行文件已不在磁盘上，TCC 无法校验本应用 → 辅助功能授权必然失效")
            Log.info("🚨 bundle=\(bundle) executable=\(executable)")
            Log.info("🚨 重新安装即可修复：./build.sh release install")
            return
        }
        Log.info("bundle 自检正常：\(bundle)")
    }

    private func handleCaptured(_ item: ClipItem) {
        let outcome = store.add(item)

        let description: String
        switch outcome {
        case .inserted: description = "新增"
        case .promoted: description = "去重（已有，提到最前）"
        case .duplicateOfNewest: description = "忽略（与最新一条相同）"
        case .rejected: description = "忽略（纯空白）"
        case .evicted(let count): description = "新增并淘汰 \(count) 条"
        }

        let size = item.totalBytes >= 1024
            ? "\(item.totalBytes / 1024) KB"
            : "\(item.totalBytes) B"
        Log.info("捕获 \(item.kind.rawValue) \(size) → \(description)，历史 \(store.items.count) 条")

        // 保险：NSHostingView 的观察在这个场景下不可靠，显式同步一次画面
        panelController?.refreshContent()
    }

    /// 调试用：
    ///   `kill -USR1 <pid>` 等同按一次 Ctrl+V
    ///   `kill -USR2 <pid>` 等同选中最后一条并粘贴
    ///   `kill -WINCH <pid>` 把面板当前渲染结果存成 /tmp/paste-panel.png
    private func installDebugSignalHooks(_ controller: PanelController) {
        signal(SIGUSR1, SIG_IGN)
        let toggle = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        toggle.setEventHandler { [weak controller] in
            Log.info("收到 SIGUSR1（调试触发面板）")
            controller?.toggle()
        }
        toggle.resume()
        toggleSignal = toggle

        signal(SIGUSR2, SIG_IGN)
        let commit = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        commit.setEventHandler { [weak controller] in
            Log.info("收到 SIGUSR2（调试触发粘贴）")
            controller?.debugCommitOldest()
        }
        commit.resume()
        commitSignal = commit

        signal(SIGWINCH, SIG_IGN)
        let snapshot = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        snapshot.setEventHandler { [weak controller] in
            Log.info("收到 SIGWINCH（调试：下移一格并前后各截一张）")
            controller?.debugMoveAndSnapshot()
        }
        snapshot.resume()
        snapshotSignal = snapshot
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        // 每次打开都重建，状态行和勾选才是实时的
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshStatusItemIcon()
    }

    /// 菜单栏图标：缺少「辅助功能」权限时带一个提示点。
    ///
    /// 整个图标保持单色 template，浅色/深色菜单栏都能正确反色。
    private func refreshStatusItemIcon() {
        guard let button = statusItem?.button else { return }

        let needsAttention = Preferences.autoPaste && !Accessibility.isTrusted
        guard let base = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "Paste"
        ) else { return }

        if needsAttention {
            let dotted = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                // 右下角实心小圆点 = 需要注意
                let dot: CGFloat = 5
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: rect.maxX - dot,
                    y: rect.minY,
                    width: dot,
                    height: dot
                )).fill()
                return true
            }
            dotted.isTemplate = true
            button.image = dotted
            button.toolTip = "Paste — 缺少「辅助功能」权限，回车只会复制；点开可去开启"
        } else {
            base.isTemplate = true
            button.image = base
            button.toolTip = Accessibility.isTrusted
                ? "Paste — Ctrl+V 打开剪贴板历史"
                : "Paste — Ctrl+V 打开剪贴板历史（自动粘贴未开启）"
        }
    }

    /// 权限可能在应用运行期间被授予，定时刷新一下图标。
    private func startStatusItemRefreshTimer() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshStatusItemIcon()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusItemRefreshTimer = timer
    }

    @objc private func showPanel() {
        panelController?.show()
    }

    @objc private func clearHistory() {
        store.clear()
        Log.info("历史已清空")
    }

    @objc private func toggleAutoPaste() {
        Preferences.autoPaste.toggle()
        Log.info("自动粘贴 → \(Preferences.autoPaste)")
        if Preferences.autoPaste, !Accessibility.isTrusted {
            Accessibility.requestPermission()
        }
    }

    @objc private func toggleRestoreClipboard() {
        Preferences.restoreClipboard.toggle()
        Log.info("恢复剪贴板 → \(Preferences.restoreClipboard)")
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = !LoginItem.isEnabled
        switch LoginItem.setEnabled(enable) {
        case .success:
            Log.info("开机自启 → \(LoginItem.statusDescription)")
        case .failure(let error):
            Log.info("设置开机自启失败：\(error.localizedDescription)")
        }
    }

    @objc private func openAccessibilitySettings() {
        Accessibility.openSystemSettings()
    }

    @objc private func revealHistoryFolder() {
        guard let persistence = ClipPersistence.defaultStore() else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: persistence.directoryPath))
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    private func populate(_ menu: NSMenu) {
        let autoStatus: String
        if !Preferences.autoPaste {
            autoStatus = "自动粘贴：已关闭"
        } else if Accessibility.isTrusted {
            autoStatus = "自动粘贴：就绪 ✓"
        } else {
            autoStatus = "自动粘贴：需要辅助功能权限"
        }

        menu.addItem(disabled(autoStatus))
        menu.addItem(disabled("历史 \(store.items.count)/\(ClipStore.maxItems) 条 · Ctrl+V 打开"))
        menu.addItem(.separator())

        let auto = checkable("自动粘贴（选中即按 Cmd+V）", #selector(toggleAutoPaste), Preferences.autoPaste)
        menu.addItem(auto)

        let restore = checkable("粘贴后恢复原剪贴板", #selector(toggleRestoreClipboard), Preferences.restoreClipboard)
        menu.addItem(restore)

        let login = checkable("开机自启", #selector(toggleLaunchAtLogin), LoginItem.isEnabled)
        menu.addItem(login)

        menu.addItem(.separator())

        menu.addItem(action("打开辅助功能设置…", #selector(openAccessibilitySettings)))
        menu.addItem(action("打开历史文件夹…", #selector(revealHistoryFolder)))

        menu.addItem(.separator())

        menu.addItem(action("显示历史", #selector(showPanel)))
        menu.addItem(action("清空历史", #selector(clearHistory)))

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 Paste",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func checkable(_ title: String, _ selector: Selector, _ on: Bool) -> NSMenuItem {
        let item = action(title, selector)
        item.state = on ? .on : .off
        return item
    }
}
