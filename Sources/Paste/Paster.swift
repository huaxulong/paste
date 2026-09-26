import AppKit

/// 合成 Cmd+V。
///
/// 没有「辅助功能」权限时系统会静默丢弃这些事件，所以调用前必须先查权限。
enum Paster {
    private static let vKeyCode: CGKeyCode = 0x09 // kVK_ANSI_V

    @discardableResult
    static func pressCommandV() -> Bool {
        guard Accessibility.isTrusted else { return false }
        // 干跑模式不发真实按键
        guard !DebugFlags.dryRun else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // 走 HID 事件流，交给当前前台 App。
        // 调用时面板必须已经收起，否则按键会打到面板自己身上。
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
