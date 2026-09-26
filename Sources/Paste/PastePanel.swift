import AppKit

/// `.nonactivatingPanel` 是关键：面板能拿到键盘输入，但**不会**把我们的 App 变成前台。
/// 这样面板收起后，原来那个 App 仍是 frontmost，用户按 Cmd+V 才会粘到正确的地方。
final class PastePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        level = .floating
        // 不要加 .transient：它表示「App 失去激活时把窗口从屏幕上移除」，
        // 而我们这个 .accessory App 从来不激活 —— 语义相反，会造成显示不稳定。
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
