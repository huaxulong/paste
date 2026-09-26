import AppKit
import SwiftUI

/// 包一个 AppKit 的 `NSSearchField`。
///
/// 不用 SwiftUI 的 `TextField`，是为了能**确定地**把焦点交给它
/// （`panel.makeFirstResponder(searchField)`），而不依赖 SwiftUI 焦点系统
/// 在「非激活面板」里的行为——那正是这个面板最特殊的地方。
///
/// 另一个好处是 `NSSearchField` 是原生输入框，中文输入法能正常工作。
struct SearchFieldView: NSViewRepresentable {
    let field: NSSearchField
    let text: String
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSSearchField {
        field.delegate = context.coordinator
        field.placeholderString = "输入以搜索"
        field.focusRingType = .none
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.onChange = onChange
        // 只在真的不一致时才写回，否则会打断用户正在输入的输入法候选
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            onChange(field.stringValue)
        }
    }
}
