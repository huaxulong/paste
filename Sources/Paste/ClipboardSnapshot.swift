import AppKit

/// 剪贴板内容快照：`[每个 item 的 [类型: 数据]]`。
///
/// 存的是**原始数据**而不是 `NSPasteboardItem`，原因是 AppKit 的
/// `NSPasteboardItem` 和剪贴板是一对一绑定的：
///
/// - 从 `pasteboardItems` 拿到的 item 已绑定在原剪贴板上，
///   直接 `writeObjects` 回去会抛
///   `NSInvalidArgumentException: It is already associated with another pasteboard.`
/// - 就算新建 item，写出去一次之后它也被绑定了，再写第二次照样抛异常。
///
/// 存数据、每次写入现造 item，才能既安全又可重复使用。
///
/// 用 `[[String: Data]]` 而不是合并成一个字典，是为了保住多 item 剪贴板
/// （比如从访达一次复制多个文件）。
struct ClipboardSnapshot: Codable, Equatable {
    let contents: [[String: Data]]

    var isEmpty: Bool { contents.isEmpty }

    var totalBytes: Int {
        contents.reduce(0) { total, entry in
            total + entry.values.reduce(0) { $0 + $1.count }
        }
    }

    /// 抓取整块剪贴板，不做类型过滤。
    static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }
        return capture(from: items)
    }

    /// 抓取指定的 item，可只保留白名单里的类型。
    static func capture(
        from items: [NSPasteboardItem],
        allowedTypes: Set<NSPasteboard.PasteboardType>? = nil
    ) -> ClipboardSnapshot? {
        let captured: [[String: Data]] = items.compactMap { item in
            var entry: [String: Data] = [:]
            for type in item.types {
                if let allowedTypes, !allowedTypes.contains(type) { continue }
                if let data = item.data(forType: type) {
                    entry[type.rawValue] = data
                }
            }
            return entry.isEmpty ? nil : entry
        }

        guard !captured.isEmpty else { return nil }
        return ClipboardSnapshot(contents: captured)
    }

    /// 写回剪贴板，返回是否成功。可以重复调用。
    @discardableResult
    func write(to pasteboard: NSPasteboard) -> Bool {
        let freshItems = contents.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects(freshItems)
    }
}
