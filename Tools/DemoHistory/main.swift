// 生成一份**演示用**的剪贴板历史，用来给 README 截图。
//
// 为什么不直接截真实历史：里面有用户真实的剪贴板内容。
//
// 用法：
//   swiftc -o /tmp/make_demo \
//     Tools/DemoHistory/main.swift \
//     Sources/Paste/ClipItem.swift Sources/Paste/ClipboardSnapshot.swift \
//     Sources/Paste/ClipPersistence.swift Sources/Paste/Log.swift
//   /tmp/make_demo <items 目录>
//
// （文件必须叫 main.swift —— swiftc 只允许 main.swift 里有顶层代码）
//
import AppKit
import Foundation

struct Demo {
    let text: String
    let app: String
    /// 距离现在多少分钟
    let minutesAgo: Double
}

let demos: [Demo] = [
    Demo(text: "https://github.com/huaxulong/paste", app: "Safari", minutesAgo: 1),
    Demo(text: "git rebase -i HEAD~3", app: "Terminal", minutesAgo: 3),
    Demo(text: "这周的周报我已经发到群里了，有问题随时找我", app: "微信", minutesAgo: 6),
    Demo(text: "let store = ClipStore(persistence: .defaultStore())", app: "Xcode", minutesAgo: 9),
    Demo(text: "SELECT id, content FROM items WHERE created_at > ? ORDER BY created_at DESC LIMIT 20;",
         app: "DataGrip", minutesAgo: 14),
    Demo(text: "/Users/me/Library/Application Support/com.local.paste/items", app: "访达", minutesAgo: 18),
    Demo(text: "{\"name\":\"paste\",\"version\":\"0.1.0\",\"private\":true}", app: "VS Code", minutesAgo: 23),
    Demo(text: "hdxlonger@126.com", app: "邮件", minutesAgo: 31),
    Demo(text: "npm run build --filter web", app: "Terminal", minutesAgo: 38),
    Demo(text: "#4A90D9", app: "Figma", minutesAgo: 45),
    Demo(text: "会议改到周四下午三点，会议室换到 12 楼", app: "微信", minutesAgo: 52),
    Demo(text: "sudo security add-trusted-cert -d -r trustRoot -p codeSign", app: "Terminal", minutesAgo: 61),
]

let args = CommandLine.arguments
guard args.count > 1 else {
    print("用法: make_demo <items 目录>")
    exit(1)
}
let directory = URL(fileURLWithPath: args[1])

// 清空目标目录，避免和真实历史混在一起
if let existing = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
    for name in existing {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

let persistence = ClipPersistence(directory: directory)
let now = Date()
var written = 0

for demo in demos {
    let snapshot = ClipboardSnapshot(contents: [[
        ClipTypes.string.rawValue: Data(demo.text.utf8),
    ]])
    guard let item = ClipItem.make(
        from: snapshot,
        sourceApp: demo.app,
        now: now.addingTimeInterval(-demo.minutesAgo * 60)
    ) else { continue }
    // make() 生成的是纯文本；保持原样即可
    _ = item
    persistence.save(item)
    written += 1
}

print("已写入 \(written) 条演示历史 → \(directory.path)")
