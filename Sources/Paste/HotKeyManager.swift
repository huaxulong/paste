import Carbon.HIToolbox
import Foundation

/// 用 Carbon 的 `RegisterEventHotKey` 注册全局热键。
///
/// 选它而不是 CGEventTap 的原因：不需要「辅助功能」或「输入监控」权限，
/// 而且能抢占前台 App 的按键（这正是我们想要的）。
final class HotKeyManager {
    /// C 回调不能捕获上下文，因此用静态转发口把事件送回实例。
    fileprivate static var dispatch: (() -> Void)?

    private static let signature: OSType = 0x50535445 // 'PSTE'
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var onTrigger: (() -> Void)?

    /// 注册 Ctrl+V
    @discardableResult
    func registerCtrlV() -> Bool {
        register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey))
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        HotKeyManager.dispatch = { [weak self] in self?.onTrigger?() }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }

                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                guard status == noErr,
                      pressed.signature == HotKeyManager.signature,
                      pressed.id == HotKeyManager.hotKeyID
                else {
                    return OSStatus(eventNotHandledErr)
                }

                HotKeyManager.dispatch?()
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        guard installStatus == noErr else {
            Log.info("InstallEventHandler 失败: \(installStatus)")
            return false
        }

        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            Log.info("RegisterEventHotKey 失败: \(status)")
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = handlerRef {
            RemoveEventHandler(handler)
            handlerRef = nil
        }
        HotKeyManager.dispatch = nil
    }

    deinit { unregister() }
}
