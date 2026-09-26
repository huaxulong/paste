import Foundation

/// 历史持久化：**一条一个二进制 plist**，放在
/// `~/Library/Application Support/com.local.paste/items/<uuid>.plist`
///
/// 之所以不把整个历史写成一个文件：历史里可能有图片，几十 MB 每次复制都全量重写太浪费。
/// 一条一个文件之后，「新增」只写一个文件，「淘汰」只删一个文件。
/// 顺序不靠文件名，而是靠加载后按 `capturedAt` 排序。
final class ClipPersistence {
    private let directory: URL
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(directory: URL) {
        self.directory = directory
        encoder.outputFormat = .binary
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.info("无法创建历史目录：\(error.localizedDescription)")
        }
    }

    /// 默认位置。拿不到 Application Support 时返回 nil（此时退化成不持久化，功能仍可用）。
    static func defaultStore() -> ClipPersistence? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.paste"
        let directory = base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("items", isDirectory: true)
        return ClipPersistence(directory: directory)
    }

    var directoryPath: String { directory.path }

    func load() -> [ClipItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        var loaded: [ClipItem] = []
        for name in names where name.hasSuffix(".plist") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }

            if let item = try? decoder.decode(ClipItem.self, from: data) {
                loaded.append(item)
            } else {
                // 解不出来就删掉，免得每次启动都报一遍
                Log.info("历史文件损坏，已删除：\(name)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        return loaded
    }

    func save(_ item: ClipItem) {
        let url = directory.appendingPathComponent("\(item.id.uuidString).plist")
        do {
            let data = try encoder.encode(item)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.info("保存历史失败：\(error.localizedDescription)")
        }
    }

    func delete(_ id: UUID) {
        let url = directory.appendingPathComponent("\(id.uuidString).plist")
        try? FileManager.default.removeItem(at: url)
    }

    func deleteAll() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
