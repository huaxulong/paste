import AppKit
import Combine
import SwiftUI

struct ClipListView: View {
    @ObservedObject var store: ClipStore
    let searchField: NSSearchField
    var onPick: (Int) -> Void
    var onOpenSettings: () -> Void

    private var list: [ClipItem] { store.filteredItems }

    var body: some View {
        // ⚠️ 这一行不能省，也不要挪进 ForEach 的行闭包里。
        //
        // `selectedItemID` 如果只在行闭包内部被读到，SwiftUI 在 body 求值阶段
        // 就看不到这个依赖 —— 选中项变了它也不会重绘。表现就是：
        // 方向键明明移动了选中项，画面上的高亮却**一动不动**；
        // 用户按回车时瞄的还是旧位置，于是「看到序号 4、粘出序号 5」。
        // （`list` 是在 body 里算的，所以 items 变化一直能正常重绘，只有选中项不行。）
        let selectedID = store.selectedItemID
        // 上报「这次渲染高亮的是哪一条」。提交时用它，而不是模型值 ——
        // 渲染可能落后于模型，而用户认的是屏幕上看到的。
        let _ = store.markRendered(selectedID)

        VStack(spacing: 0) {
            header
            Divider()
            if !store.autoPasteAvailable {
                permissionBanner
                Divider()
            }
            content(selectedID: selectedID)
            Divider()
            footer
        }
        // 用「填满父视图」而不是写死尺寸：面板窗口带了标题栏，
        // 实际高度会比 contentRect 多出 28px，写死高度会在上下留出透明条。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .popover, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 顶部：搜索框 + 计数

    private var header: some View {
        HStack(spacing: 8) {
            SearchFieldView(field: searchField, text: store.query) { text in
                store.setQuery(text)
            }
            .frame(height: 20)

            Text(countText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var countText: String {
        store.isFiltering
            ? "\(list.count)/\(store.items.count)"
            : "\(store.items.count)/\(ClipStore.maxItems)"
    }

    /// 没有「辅助功能」权限时的醒目提示。
    /// 用户按回车只会把内容写进剪贴板，必须在界面上说清楚，否则看起来就是「坏了」。
    private var permissionBanner: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text("未授予辅助功能权限，回车只复制不粘贴")
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                Spacer(minLength: 4)
                Text("去开启 →")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - 列表

    @ViewBuilder
    private func content(selectedID: UUID?) -> some View {
        if store.isEmpty {
            placeholder(title: "还没有历史记录", subtitle: "先复制点什么，再按 Ctrl+V")
        } else if list.isEmpty {
            placeholder(title: "没有匹配的内容", subtitle: "换个关键词试试")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            ClipRow(
                                item: item,
                                index: index,
                                isSelected: item.id == selectedID
                            )
                            // 不要再加 .id(index)：那会把 ForEach 已经设好的
                            // 「条目 UUID」身份覆盖成「数组下标」，LazyVStack 便按位置
                            // 复用行视图，列表一变就可能显示出错位的内容。
                            .onTapGesture { onPick(index) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                // 每次呼出都重建，保证滚动条从最顶上新的一条开始
                .id(store.presentationID)
                .onAppear {
                    // 光靠 .id() 重建并不总能复位滚动位置（实测有时会停在旧位置）。
                    // 一旦选中的第一条跑出可视区，面板上就**看不到任何高亮**，
                    // 用户只能数行数，很容易差一位。这里显式滚回顶部。
                    guard let first = list.first else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
                // 订阅的是**条目身份**而不是下标：列表插入新条目时下标的含义会变，
                // 身份不会。滚动也直接按 UUID 找。
                .onReceive(store.$selectedItemID) { newValue in
                    guard let id = newValue else { return }
                    // anchor 用 nil（「刚好滚到可见」），**不要用 .center**，
                    // 也不要包 withAnimation：.center 会让列表每按一次方向键就大幅滚动一次
                    // 还带动画，用户的视线在追滚动，而高亮是立刻跳的 —— 两者错开就会选错行。
                    proxy.scrollTo(id, anchor: nil)
                }
            }
        }
    }

    private func placeholder(title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Spacer()
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            hint("↑↓", "选择")
            hint("⏎", store.autoPasteAvailable ? "粘贴" : "复制")
            if store.isFiltering {
                hint("esc", "清空搜索")
            } else {
                hint("esc", "关闭")
                hint("⌘Q", "退出")
            }
            Spacer()
            // 调试探针：把视图读到的 selectedIndex 直接画出来。
            // 截图时就能看到「视图认为选中了第几条」，用来区分
            // 「模型状态不对」还是「视图没跟上」。
            // 探针：把**视图自己**读到的选中状态画出来。
            // 截图里这个数字和日志里的 selectedIndex 一比，就能确定
            // 是「视图拿到的状态是旧的」还是「高亮逻辑本身错了」。
            if DebugFlags.logContent {
                Text("sel=\(store.selectedIndex) id=\(store.selectedItemID?.uuidString.prefix(4) ?? "-")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(label)
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            // 序号放在最前面、等宽字体、字号加大。
            // 以前它混在下面那行灰色小字里（"4 · Sublime Text · 2 字符"），
            // 太小、太容易看漏 —— 用户没法确认自己在第几条，只能数行数，一数就错。
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 24, alignment: .trailing)

            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.system(size: 12.5))
                    .foregroundColor(primaryColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(meta)
                    .font(.system(size: 9.5))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Self.selectionColor : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// 不用 `Color.accentColor`：我们的面板是 `.nonactivating`，
    /// 宿主 App 永远不是 active 状态，这种情况下系统强调色会退化成灰色，
    /// 选中行几乎看不出来 —— 用户就只能靠数行数，很容易差一位。
    static let selectionColor = Color(red: 0.196, green: 0.510, blue: 0.980)

    @ViewBuilder
    private var leading: some View {
        ZStack {
            if let thumbnail = item.thumbnail, let image = NSImage(data: thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: item.kind.iconName)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
                    .frame(width: 30, height: 30)
            }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let app = item.sourceApp, !app.isEmpty {
            parts.append(app)
        }
        switch item.kind {
        case .text, .richText:
            if let count = item.text?.count {
                parts.append("\(count) 字符")
            }
        case .image:
            parts.append(sizeText)
        case .files:
            parts.append("\(item.fileURLs.count) 个文件")
        case .other:
            break
        }
        parts.append(Self.timeFormatter.string(from: item.capturedAt))
        return parts.joined(separator: " · ")
    }

    private var sizeText: String {
        let bytes = item.totalBytes
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
        }
        return "\(max(1, bytes / 1024)) KB"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var primaryColor: Color { isSelected ? .white : .primary }
    private var secondaryColor: Color { isSelected ? .white.opacity(0.72) : .secondary }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
