import AppKit
import Combine

/// `add` 的结果，用于日志和测试断言。
enum AddOutcome: Equatable {
    case inserted
    case promoted
    case duplicateOfNewest
    case rejected
    case evicted(Int)
}

/// 剪贴板历史。
final class ClipStore: ObservableObject {
    /// 条数上限
    static let maxItems = 20
    /// 总大小上限。图片很容易把历史撑爆，条数限制挡不住。
    static let maxTotalBytes = 50 * 1024 * 1024

    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var query: String = ""
    /// 当前选中的**条目身份**（UUID），而不是下标。
    ///
    /// 用下标会出事：列表前面一旦插入新条目（用户又复制了东西、或粘贴后把条目提到最前），
    /// 所有条目下移一位，同一个下标就指向了**另一条**内容 ——
    /// 用户看到的是第 4 行，程序提交的却是第 5 行。
    /// 换成 UUID 之后，插入多少条都不会跟丢。
    @Published private(set) var selectedItemID: UUID?
    /// 每次呼出面板都换一个新值，用来强制重建列表视图。
    ///
    /// 不这么做的话滚动位置会被沿用：`show()` 里把 selectedIndex 归零时面板还没显示，
    /// 此时 `scrollTo` 对不可见的 ScrollView 未必生效，面板重现时会停在旧位置——
    /// 结果就是最新的几条被挤出可视区，看起来像「刚复制的内容不在列表里」。
    @Published private(set) var presentationID = UUID()

    /// **画面上**当前高亮的那一条。
    ///
    /// 和 `selectedItemID` 的区别是关键：`selectedItemID` 是模型状态，
    /// 而 SwiftUI 的渲染可能落后于它（实测这个 `.nonactivating` 面板里
    /// `NSHostingView` 的观察并不可靠）。用户按回车时瞄的是**屏幕上**的高亮，
    /// 所以提交必须用这个值 —— 否则就会出现「看到序号 4、粘出序号 5」。
    ///
    /// 刻意不加 `@Published`：它是在 body 求值期间写入的，
    /// 发布出去会造成渲染循环。
    private(set) var renderedItemID: UUID?

    /// 由视图在每次渲染时调用，记下这次高亮的是哪一条。
    func markRendered(_ id: UUID?) {
        renderedItemID = id
    }

    /// 回车时真正该提交的那一条：优先用画面上的，退回到模型。
    var itemToCommit: ClipItem? {
        let id = renderedItemID ?? selectedItemID
        guard let id else { return filteredItems.first }
        return filteredItems.first { $0.id == id } ?? filteredItems.first
    }
    /// 当前是否真的能自动粘贴（需要「辅助功能」权限）。
    /// 面板据此显示提示 —— 否则用户按回车只会「悄悄写进剪贴板」，
    /// 完全看不出为什么不粘贴。
    @Published private(set) var autoPasteAvailable = false

    private let persistence: ClipPersistence?
    /// 条数上限（测试时可注入更小的值）
    private let capacity: Int
    /// 总大小上限（测试时可注入更小的值）
    private let byteBudget: Int

    init(
        persistence: ClipPersistence? = nil,
        capacity: Int = ClipStore.maxItems,
        byteBudget: Int = ClipStore.maxTotalBytes
    ) {
        self.persistence = persistence
        self.capacity = capacity
        self.byteBudget = byteBudget

        guard let persistence else { return }
        items = persistence.load()
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(capacity)
            .map { $0 }
    }

    // MARK: - 查询 / 选择

    /// 搜索过滤后的列表。`selectedIndex` 指的是这个数组。
    var filteredItems: [ClipItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { $0.searchText.contains(needle) }
    }

    var isEmpty: Bool { items.isEmpty }
    var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 选中项在当前列表中的位置（只用于滚动和日志，不是状态的真相）
    var selectedIndex: Int {
        guard let id = selectedItemID else { return 0 }
        return filteredItems.firstIndex { $0.id == id } ?? 0
    }

    var selectedItem: ClipItem? {
        guard let id = selectedItemID else { return filteredItems.first }
        return filteredItems.first { $0.id == id } ?? filteredItems.first
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        // 过滤条件变了，原来的选中项可能已经不在列表里 —— 退回第一条
        selectedItemID = filteredItems.first?.id
    }

    /// 准备展示：清掉搜索、选中第一条、换一个 presentationID 让列表视图重建。
    ///
    /// `autoPasteAvailable` 由调用方注入 —— 模型层不该去碰「辅助功能」权限这种系统状态。
    func beginPresentation(autoPasteAvailable: Bool) {
        query = ""
        presentationID = UUID()
        self.autoPasteAvailable = autoPasteAvailable
        selectedItemID = filteredItems.first?.id
        renderedItemID = nil   // 等这一轮渲染重新记录
    }

    func clearQuery() {
        setQuery("")
    }

    func moveSelection(by delta: Int) {
        let list = filteredItems
        guard !list.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), list.count - 1)
        selectedItemID = list[next].id
    }

    func select(index: Int) {
        let list = filteredItems
        guard list.indices.contains(index) else { return }
        selectedItemID = list[index].id
    }

    // MARK: - 增删

    @discardableResult
    func add(_ item: ClipItem) -> AddOutcome {
        guard !item.isBlankText else { return .rejected }

        if let newest = items.first, newest.hasSameContent(as: item) {
            return .duplicateOfNewest
        }

        // 复制了历史里已有的内容 → 提到最前，而不是产生重复项
        if let index = items.firstIndex(where: { $0.hasSameContent(as: item) }) {
            var existing = items.remove(at: index)
            existing.capturedAt = item.capturedAt
            if let app = item.sourceApp { existing.sourceApp = app }
            items.insert(existing, at: 0)
            persistence?.save(existing)
            return .promoted
        }

        items.insert(item, at: 0)
        persistence?.save(item)

        // 之前没有选中项（比如面板刚开、列表还空）就落到最新一条。
        // 有选中项时**不要动它** —— 那正是用户正在挑的那条，插入新条目不能被抢走。
        if selectedItemID == nil {
            selectedItemID = filteredItems.first?.id
        }

        let evicted = enforceLimits()
        return evicted == 0 ? .inserted : .evicted(evicted)
    }

    /// 把内容已经在历史里的条目提到最前（粘贴之后调用）。
    func promote(_ item: ClipItem) {
        add(item)
    }

    func clear() {
        items.removeAll()
        query = ""
        selectedItemID = nil
        persistence?.deleteAll()
    }

    /// 返回被淘汰的条数
    @discardableResult
    private func enforceLimits() -> Int {
        var evicted = 0

        while items.count > capacity {
            evictLast()
            evicted += 1
        }

        var total = items.reduce(0) { $0 + $1.totalBytes }
        while total > byteBudget, items.count > 1 {
            total -= items[items.count - 1].totalBytes
            evictLast()
            evicted += 1
        }

        return evicted
    }

    private func evictLast() {
        let removed = items.removeLast()
        persistence?.delete(removed.id)
    }
}
