import AppKit

enum ClipKind: String, Codable {
    case text
    case richText
    case image
    case files
    case other

    var iconName: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "doc.richtext"
        case .image: return "photo"
        case .files: return "folder"
        case .other: return "questionmark.square.dashed"
        }
    }
}

/// 我们愿意保存的剪贴板类型白名单。
///
/// 白名单而不是「全都留」：一块剪贴板上可能有几十种类型
/// （`public.utf16-external-plain-text`、`com.apple.flat-rtfd`……），
/// 全存下来又占地方又没用。
enum ClipTypes {
    static let string = NSPasteboard.PasteboardType.string
    static let rtf = NSPasteboard.PasteboardType.rtf
    static let html = NSPasteboard.PasteboardType.html
    static let png = NSPasteboard.PasteboardType.png
    static let tiff = NSPasteboard.PasteboardType.tiff
    static let fileURL = NSPasteboard.PasteboardType.fileURL

    static let allowed: Set<NSPasteboard.PasteboardType> = [string, rtf, html, png, tiff, fileURL]
}

struct ClipItem: Identifiable, Codable, Equatable {
    /// 单条超过这个大小就不收了
    static let maxItemBytes = 20 * 1024 * 1024

    let id: UUID
    /// 用来排序。被「提到最前」时会更新。
    var capturedAt: Date
    var sourceApp: String?
    let snapshot: ClipboardSnapshot
    let kind: ClipKind
    /// 列表里显示的一行摘要
    let preview: String
    /// 搜索用的小写文本（预先算好存下来，避免每次渲染都重新解析图片）
    let searchText: String
    /// 图片缩略图（PNG），只用于列表渲染，不参与粘贴
    let thumbnail: Data?

    var totalBytes: Int { snapshot.totalBytes }

    var text: String? { Self.plainText(in: snapshot) }
    var fileURLs: [URL] { Self.fileURLs(in: snapshot) }

    /// 纯文本/富文本且内容全是空白
    var isBlankText: Bool {
        guard kind == .text || kind == .richText else { return false }
        return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 内容是否相同（忽略来源 App 和时间）
    func hasSameContent(as other: ClipItem) -> Bool {
        snapshot == other.snapshot
    }

    /// 从剪贴板抓一条。
    static func capture(from pasteboard: NSPasteboard, sourceApp: String?, now: Date = Date()) -> ClipItem? {
        guard let raw = ClipboardSnapshot.capture(from: pasteboard.pasteboardItems ?? [],
                                                  allowedTypes: ClipTypes.allowed)
        else { return nil }
        return make(from: droppingRedundantImageTypes(raw), sourceApp: sourceApp, now: now)
    }

    /// 同一张图同时以 PNG 和 TIFF 出现时丢掉 TIFF。
    ///
    /// 从浏览器、预览、截图工具复制图片时很常见：PNG 无损，而且比未压缩的 TIFF
    /// 小一个数量级，留着 TIFF 只会让历史和磁盘白白膨胀。
    static func droppingRedundantImageTypes(_ snapshot: ClipboardSnapshot) -> ClipboardSnapshot {
        let png = ClipTypes.png.rawValue
        let tiff = ClipTypes.tiff.rawValue

        guard snapshot.contents.contains(where: { $0[png] != nil }) else { return snapshot }

        return ClipboardSnapshot(contents: snapshot.contents.map { entry in
            var copy = entry
            copy.removeValue(forKey: tiff)
            return copy
        })
    }

    /// 从快照构造。类型检测、预览、缩略图都在这里算好。
    static func make(from snapshot: ClipboardSnapshot, sourceApp: String?, now: Date = Date()) -> ClipItem? {
        guard !snapshot.isEmpty, snapshot.totalBytes <= maxItemBytes else { return nil }

        let kind = detectKind(snapshot)
        let preview = makePreview(snapshot, kind: kind)

        return ClipItem(
            id: UUID(),
            capturedAt: now,
            sourceApp: sourceApp,
            snapshot: snapshot,
            kind: kind,
            preview: preview,
            searchText: makeSearchText(snapshot, kind: kind, preview: preview),
            thumbnail: kind == .image ? makeThumbnail(snapshot) : nil
        )
    }

    // MARK: - 类型检测

    static func detectKind(_ snapshot: ClipboardSnapshot) -> ClipKind {
        let keys = Set(snapshot.contents.flatMap { $0.keys })

        if keys.contains(ClipTypes.fileURL.rawValue) { return .files }
        if keys.contains(ClipTypes.png.rawValue) || keys.contains(ClipTypes.tiff.rawValue) { return .image }

        let hasRich = keys.contains(ClipTypes.rtf.rawValue) || keys.contains(ClipTypes.html.rawValue)
        if keys.contains(ClipTypes.string.rawValue) { return hasRich ? .richText : .text }
        if hasRich { return .richText }
        return .other
    }

    // MARK: - 内容提取

    static func plainText(in snapshot: ClipboardSnapshot) -> String? {
        for entry in snapshot.contents {
            if let data = entry[ClipTypes.string.rawValue],
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    static func fileURLs(in snapshot: ClipboardSnapshot) -> [URL] {
        snapshot.contents.compactMap { entry in
            guard let data = entry[ClipTypes.fileURL.rawValue],
                  let string = String(data: data, encoding: .utf8) else { return nil }
            return URL(string: string)
        }
    }

    /// 优先 PNG：无损而且比未压缩的 TIFF 小一个数量级。
    static func imageData(in snapshot: ClipboardSnapshot) -> Data? {
        for entry in snapshot.contents {
            if let data = entry[ClipTypes.png.rawValue] { return data }
        }
        for entry in snapshot.contents {
            if let data = entry[ClipTypes.tiff.rawValue] { return data }
        }
        return nil
    }

    // MARK: - 预览 / 搜索 / 缩略图

    private static func makePreview(_ snapshot: ClipboardSnapshot, kind: ClipKind) -> String {
        switch kind {
        case .text, .richText:
            guard let text = plainText(in: snapshot) else {
                return kind == .richText ? "富文本" : "文本"
            }
            return collapse(text)

        case .image:
            if let data = imageData(in: snapshot), let image = NSImage(data: data) {
                let size = image.size
                if size.width > 0, size.height > 0 {
                    return "图片 \(Int(size.width)) × \(Int(size.height))"
                }
            }
            return "图片"

        case .files:
            let names = fileURLs(in: snapshot).map(\.lastPathComponent)
            guard !names.isEmpty else { return "文件" }
            if names.count > 3 {
                return "\(names.prefix(3).joined(separator: ", ")) 等 \(names.count) 个文件"
            }
            return names.joined(separator: ", ")

        case .other:
            return "其他内容"
        }
    }

    /// 把换行折叠成 ⏎，并压掉多余空白。
    static func collapse(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
        return collapsed.isEmpty ? text : collapsed
    }

    private static func makeSearchText(_ snapshot: ClipboardSnapshot, kind: ClipKind, preview: String) -> String {
        var parts = [preview.lowercased()]
        if let text = plainText(in: snapshot) {
            parts.append(text.lowercased())
        }
        parts.append(contentsOf: fileURLs(in: snapshot).map { $0.path.lowercased() })
        parts.append(kind.rawValue.lowercased())
        return parts.joined(separator: "\n")
    }

    static func makeThumbnail(_ snapshot: ClipboardSnapshot, maxDimension: CGFloat = 128) -> Data? {
        guard let data = imageData(in: snapshot), let image = NSImage(data: data) else { return nil }

        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )

        let thumbnail = NSImage(size: target, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(
                in: rect,
                from: NSRect(origin: .zero, size: size),
                operation: .copy,
                fraction: 1
            )
            return true
        }

        guard let tiff = thumbnail.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
