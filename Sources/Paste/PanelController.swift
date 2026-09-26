import AppKit
import SwiftUI

final class PanelController {
    private let store: ClipStore
    private let monitor: ClipboardMonitor
    private let panel: PastePanel
    /// 自己持有搜索框实例，才能确定地把焦点交给它
    private let searchField = NSSearchField()
    /// 保存起来，必要时手动刷新内容。
    ///
    /// 为什么需要手动刷：`NSHostingView` + `@ObservedObject` 在这个
    /// `.nonactivating` 面板里不可靠 —— 状态变了它不一定会重新求值
    /// （实测 body 完全不再求值，两张间隔 400ms 的截图字节完全相同）。
    /// 结果是方向键移动了选中项、画面上的高亮却纹丝不动，
    /// 用户按回车时瞄的还是旧位置。显式重设 rootView 可以稳定触发重绘。
    private var hosting: NSHostingView<ClipListView>!

    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var didRequestAccessibility = false

    /// 面板弹出时谁在前台 —— 那就是粘贴的目标 App。
    /// 面板是 `.nonactivatingPanel`，所以我们全程不会把它顶掉。
    private var targetApp: NSRunningApplication?

    private static let panelSize = NSSize(width: 400, height: 440)

    init(store: ClipStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor

        let rect = NSRect(origin: .zero, size: Self.panelSize)
        panel = PastePanel(contentRect: rect)

        let root = makeRootView()
        let hosting = NSHostingView(rootView: root)
        hosting.frame = rect
        panel.contentView = hosting
        self.hosting = hosting

        // 点到别处就收起来。orderOut() 之后再触发时 isVisible 已是 false，不会递归。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            Log.info("面板失去焦点，自动关闭")
            self.hide()
        }
    }

    private func makeRootView() -> ClipListView {
        ClipListView(
            store: store,
            searchField: searchField,
            onPick: { [weak self] index in self?.pickAndCommit(index: index) },
            onOpenSettings: { Accessibility.openSystemSettings() }
        )
    }

    /// 把当前状态同步到画面上。
    ///
    /// 改完选中项之后**必须**调用，否则高亮不会动（原因见 hosting 的注释）。
    /// 捕获到新条目后也调一次，作为观察失效时的保险。
    func refreshContent() {
        hosting?.rootView = makeRootView()
    }

    deinit {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// 现在这一刻能不能真的自动粘贴
    private var canAutoPasteNow: Bool {
        Preferences.autoPaste && (Accessibility.isTrusted || DebugFlags.dryRun)
    }

    /// 用户「真的看得见」这个面板吗？
    ///
    /// `isVisible` 只说明窗口被 order in 了 —— 它可能不在当前 Space，
    /// 也可能不是 key window。这种「后台可见」状态下如果按 Ctrl+V 去 hide()，
    /// 用户看到的就是**完全没反应**。
    private var isPanelOnScreen: Bool {
        panel.isVisible && panel.isOnActiveSpace && panel.isKeyWindow
    }

    func toggle() {
        let state = "visible=\(panel.isVisible) onActiveSpace=\(panel.isOnActiveSpace) key=\(panel.isKeyWindow)"
        if isPanelOnScreen {
            Log.info("Ctrl+V → 收起面板（\(state)）")
            hide()
        } else {
            Log.info("Ctrl+V → 呼出面板（之前 \(state)）")
            show()
        }
    }

    func show() {
        // 先把剪贴板的最新状态同步进来。
        // 定时器 0.3 秒一轮，用户复制完立刻按 Ctrl+V 的话，
        // 不刷这一下面板拿到的就是一份不含新内容的旧列表。
        monitor.pollNow()

        guard !store.isEmpty else {
            Log.info("历史为空，忽略本次呼出")
            NSSound.beep()
            return
        }

        // 记下目标 App。之后即使焦点有变化，也粘回这里。
        targetApp = NSWorkspace.shared.frontmostApplication

        store.beginPresentation(autoPasteAvailable: canAutoPasteNow)
        // 调试：直接把选中项设到指定位置，延迟后再截图。
        // 延迟是必须的 —— 刚设完就截，SwiftUI 还没重绘，截到的是旧画面。
        if let target = DebugFlags.selectOnShow {
            // 必须等面板真的显示、SwiftUI 完成一次渲染之后再改选中项 ——
            // 在 makeKeyAndOrderFront 之前改，视图不会跟着重绘，截到的是旧画面。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.store.select(index: target)
                Log.info("调试：把选中项设为 index=\(self.store.selectedIndex)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.debugSnapshotPanel()
                }
            }
        }
        // 显式把搜索框也清掉，避免任何残留的过滤条件把列表藏起来
        searchField.stringValue = ""
        if let debugQuery = DebugFlags.query {
            store.setQuery(debugQuery)
            searchField.stringValue = debugQuery
        }
        positionNearMouse()
        // 刻意不调用 NSApp.activate —— 目标 App 必须保持前台
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()

        // 把键盘焦点交给搜索框。首次显示时视图可能还没布局完，所以补一次。
        let focused = panel.makeFirstResponder(searchField)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panel.makeFirstResponder(self.searchField)
        }

        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知"
        let frame = panel.frame
        Log.info("面板已显示（历史 \(store.items.count) 条，当前列表 \(store.filteredItems.count) 条），目标 App = \(front)，搜索框：聚焦=\(focused) delegate=\(searchField.delegate != nil)")
        Log.info("窗口状态：onActiveSpace=\(panel.isOnActiveSpace) key=\(panel.isKeyWindow) level=\(panel.level.rawValue) frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))")
        // 面板每次呼出都记一次，status.sh 据此判断权限状态是否新鲜
        Log.info("自动粘贴就绪=\(canAutoPasteNow)（辅助功能权限=\(Accessibility.isTrusted)）")

        if DebugFlags.logContent {
            let visible = store.filteredItems
            Log.info("—— 面板实际显示 \(visible.count) 条（搜索词「\(store.query)」）——")
            for (index, item) in visible.prefix(12).enumerated() {
                let preview = item.preview.replacingOccurrences(of: "\n", with: " ")
                let short = preview.count > 24 ? String(preview.prefix(24)) + "…" : preview
                Log.info("  [\(index)] \(item.kind.rawValue) \(short)")
            }
        }
    }

    func hide() {
        removeKeyMonitor()
        panel.orderOut(nil)
        store.clearQuery()
        searchField.stringValue = ""
        Log.info("面板已隐藏")
    }

    // MARK: - 选中 → 粘贴

    /// 提交「当前选中的那一条」。
    ///
    /// 注意这里用的是**条目身份**而不是下标：下标是位置，
    /// 列表前面一旦插入新条目，同一个下标就指到别的条目上去了。
    private func commitSelected() {
        // 用「画面上高亮的那一条」，不是模型里的 —— 两者可能差一格。
        // 用户瞄的是屏幕，所以屏幕上那条才算数。
        guard let item = store.itemToCommit else { return }
        let list = store.filteredItems
        let index = list.firstIndex { $0.id == item.id } ?? -1

        // 记下到底提交了哪一条 —— 但**默认不记内容**。
        //
        // 「选第 10 条却粘出别的」这类问题需要知道内容才能定位，可剪贴板里
        // 可能是密码、token、私人对话，日志文件不该长期留这些。
        // 需要排查时用 PASTE_DEBUG_LOG_CONTENT=1 启动，才会记前 24 字。
        if DebugFlags.logContent {
            let flat = item.preview.replacingOccurrences(of: "\n", with: " ")
            let short = flat.count > 24 ? String(flat.prefix(24)) + "…" : flat
            Log.info("提交 index=\(index)（共 \(list.count) 条）：\(item.kind.rawValue)「\(short)」")
        } else {
            Log.info("提交 index=\(index)（共 \(list.count) 条）：\(item.kind.rawValue) \(item.totalBytes) 字节")
        }

        // 需要时把「按回车那一瞬间的面板」存下来，
        // 用来核对高亮的行和提交的条目是否一致。
        if DebugFlags.snapshotOnCommit {
            debugSnapshotPanel()
        }

        // 覆盖剪贴板之前，先把它当前的内容收进历史。
        // 否则「复制 → 立刻粘贴」时那次复制会被我们的写入盖掉，
        // changeCount 又被记成自身写入，那条内容就永久丢了。
        monitor.pollNow()

        let pasteboard = NSPasteboard.general
        let canAutoPaste = Preferences.autoPaste
            && (Accessibility.isTrusted || DebugFlags.dryRun)

        // 1) 只在「真的会自动粘贴」时才快照原剪贴板。
        //    手动模式下必须把选中内容留在剪贴板上等用户按 Cmd+V，
        //    这时候恢复成旧内容反而是错的。
        let snapshot = (canAutoPaste && Preferences.restoreClipboard)
            ? ClipboardSnapshot.capture(from: pasteboard)
            : nil

        // 2) 写入选中内容
        guard item.snapshot.write(to: pasteboard) else {
            Log.info("写入剪贴板失败，已放弃本次粘贴")
            return
        }

        // 3) 告诉监听器这次变化是我们自己造成的
        monitor.noteSelfWrite(pasteboard.changeCount)

        // 4) 相当于"刚复制过"，提到历史最前
        store.promote(item)

        // 5) 收起面板。顺序不能错：面板还在的话，合成的 Cmd+V 会打到面板自己身上。
        hide()

        guard canAutoPaste else {
            if Preferences.autoPaste {
                Log.info("已写入剪贴板（无辅助功能权限，未自动粘贴；内容保留在剪贴板）")
                // 第一次遇到时响一声并弹系统授权引导，
                // 否则用户按回车只会看到面板消失，完全不知道发生了什么。
                if !didRequestAccessibility {
                    NSSound.beep()
                }
                requestAccessibilityOnce()
            } else {
                Log.info("已写入剪贴板（自动粘贴已关闭，请手动按 Cmd+V）")
            }
            return
        }

        // 6) 目标 App 必须在前台，合成的按键才会落到它身上。
        //    正常情况下它一直没失去焦点，这里是兜底。
        if let target = targetApp, !target.isActive {
            Log.info("重新激活目标 App：\(target.localizedName ?? "未知")")
            target.activate()
        }

        // 7) 收起面板之后必须留够时间，让窗口服务器把 key window 交还给目标 App。
        //
        //    ⚠️ 这里踩过一个坑：`orderOut()` 之后 `panel.isVisible` / `isKeyWindow`
        //    会**立刻**变成 false，但那只是 AppKit 这一侧的状态，窗口服务器完成交接
        //    还需要时间。之前我只检查这两个标志、不加固定延迟，结果按键在 hide() 后
        //    2ms 就发出去了 —— 落到我们已经隐藏的窗口上被丢掉，目标 App 收不到粘贴。
        //    用户随后自己按 Cmd+V 时剪贴板已被恢复成旧内容，粘出来自然「不是选的那条」。
        //
        //    所以：先给一段固定延迟（不依赖那两个标志），再确认一次状态。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.afterPanelReleasesFocus { [weak self] in
                guard let self else { return }

                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知"
                Log.info("发按键前状态：panel.isVisible=\(self.panel.isVisible) isKey=\(self.panel.isKeyWindow) 前台=\(front)")

                let posted = Paster.pressCommandV()
                Log.info("自动粘贴 \(item.kind.rawValue) → \(self.targetApp?.localizedName ?? "未知")（事件已发送: \(posted)）")

                // 8) 恢复原剪贴板。必须等目标 App 读完，否则异步读剪贴板的 App 会拿到旧值。
                //    留长一点余量：抢跑的代价是粘出**错误的内容**，比剪贴板多留一会儿严重得多。
                guard let snapshot else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    guard let self else { return }
                    let restored = snapshot.write(to: NSPasteboard.general)
                    self.monitor.noteSelfWrite(NSPasteboard.general.changeCount)
                    Log.info("恢复原剪贴板（成功: \(restored)）")
                }
            }
        }
    }

    /// 等面板彻底不可见、也不再是 key window 之后再执行 `body`。
    /// 最多等 25 × 20ms = 500ms，超时也照发（免得卡死）。
    private func afterPanelReleasesFocus(attempt: Int = 0, _ body: @escaping () -> Void) {
        if attempt >= 25 {
            Log.info("等面板让出焦点超时，仍继续发送")
            body()
            return
        }
        if panel.isVisible || panel.isKeyWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.afterPanelReleasesFocus(attempt: attempt + 1, body)
            }
            return
        }
        body()
    }

    private func requestAccessibilityOnce() {
        guard !didRequestAccessibility else { return }
        didRequestAccessibility = true
        Log.info("正在请求「辅助功能」权限，请在系统设置里勾选 Paste")
        Accessibility.requestPermission()
    }

    /// 调试用：把面板**当前渲染结果**存成 PNG。
    ///
    /// 应用给自己的窗口截图不需要「屏幕录制」权限，所以这是唯一能直接看到
    /// 「面板到底画成了什么」的办法 —— 排查「标号和高亮对不上」这类问题必需。
    func debugSnapshotPanel(to path: String = "/tmp/paste-panel.png") {
        guard panel.isVisible, let view = panel.contentView else {
            Log.info("面板没显示，无法截图")
            return
        }

        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            Log.info("无法创建位图")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            Log.info("无法编码 PNG")
            return
        }

        do {
            try data.write(to: URL(fileURLWithPath: path))
            Log.info("面板截图已保存：\(path)（\(Int(bounds.width))x\(Int(bounds.height))）")
            Log.info("当前 selectedIndex=\(store.selectedIndex)，列表 \(store.filteredItems.count) 条")
        } catch {
            Log.info("截图写入失败：\(error.localizedDescription)")
        }
    }

    /// 调试用：走和方向键**完全相同**的代码路径下移一格，
    /// 然后立刻截一张、400ms 后再截一张。
    /// 两张若不同，就说明画面比状态慢一拍 —— 这正是「看到第 4 行、提交第 5 行」的成因。
    func debugMoveAndSnapshot() {
        store.moveSelection(by: 1)
        refreshContent()
        Log.info("调试：下移一格 → index=\(store.selectedIndex)")
        debugSnapshotPanel(to: "/tmp/panel-immediate.png")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.debugSnapshotPanel(to: "/tmp/panel-settled.png")
        }
    }

    /// 用户用鼠标点了某一行：先把选中项切过去，再提交。
    private func pickAndCommit(index: Int) {
        store.select(index: index)
        commitSelected()
    }

    /// 调试用：等价于「呼出面板并选中最后一条」。
    ///
    /// 特意选最后一条而不是第一条：这样「被粘贴的内容」和「原剪贴板内容」不同，
    /// 才能从日志上区分「恢复成功」和「恢复失败」。
    func debugCommitOldest() {
        let list = store.filteredItems
        guard !list.isEmpty else {
            Log.info("历史为空，无法调试粘贴")
            return
        }
        // 和 show() 一样记下目标 App，让调试路径尽量贴近真实路径
        targetApp = NSWorkspace.shared.frontmostApplication
        store.select(index: list.count - 1)
        Log.info("调试触发 → 选中第 \(list.count) 条（最旧）")
        commitSelected()
    }

    /// 调试用：直接设置搜索词，用来验证过滤逻辑
    func debugSetQuery(_ text: String) {
        store.setQuery(text)
        searchField.stringValue = text
        Log.info("调试设置搜索词「\(text)」→ 命中 \(store.filteredItems.count)/\(store.items.count) 条")
    }

    var debugFilteredCount: Int { store.filteredItems.count }

    // MARK: - 键盘处理
    //
    // 用「本地事件监听」而不是重写 keyDown / 依赖响应链：
    // 它在事件派发到视图之前就拿到，还能直接吃掉事件，最可靠。
    // 只拦特殊键，其余（包括中文输入法）交给搜索框。

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc：先清搜索，再关闭
            if store.isFiltering {
                store.clearQuery()
                searchField.stringValue = ""
                refreshContent()
            } else {
                hide()
            }
            return true

        case 125: // ↓
            store.moveSelection(by: 1)
            refreshContent()
            return true

        case 126: // ↑
            store.moveSelection(by: -1)
            refreshContent()
            return true

        case 36, 76: // Return / 小键盘 Enter
            commitSelected()
            return true

        case 12: // Q —— 没有菜单栏图标之后，这是界面上唯一的退出方式
            if event.modifierFlags.contains(.command) {
                Log.info("面板里按了 ⌘Q，退出")
                NSApp.terminate(nil)
                return true
            }
            return false

        default:
            break
        }

        // 数字键**不**拦截：左列的数字只是位置标签，不是快捷键。
        //
        // 之前拦了 1-9 做快选，副作用是「搜索词为空时打不出数字」——
        // 想搜 "16" 都打不进去。让它们全部交给搜索框。
        return false
    }

    // MARK: - 定位（多显示器下要按鼠标所在的屏幕算坐标）

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        var x = mouse.x - size.width * 0.5
        var y = mouse.y - size.height - 10

        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
