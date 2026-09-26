// ClipItem / ClipStore / ClipboardSnapshot / ClipPersistence / Preferences 的纯逻辑测试。
//
// 环境里只有 Command Line Tools，没有 XCTest，所以用独立可执行文件做断言：
//
//   ./test.sh
//
import AppKit
import Foundation

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)")
    }
}

func section(_ title: String) {
    print("\n\(title)")
}

// ---------------------------------------------------------------- 构造辅助

func snapshot(_ entries: [[String: Data]]) -> ClipboardSnapshot {
    ClipboardSnapshot(contents: entries)
}

func textSnapshot(_ text: String) -> ClipboardSnapshot {
    snapshot([[ClipTypes.string.rawValue: Data(text.utf8)]])
}

func makeItem(_ snapshot: ClipboardSnapshot, at date: Date = Date()) -> ClipItem {
    guard let item = ClipItem.make(from: snapshot, sourceApp: nil, now: date) else {
        fatalError("构造 ClipItem 失败")
    }
    return item
}

func textItem(_ text: String, at date: Date = Date()) -> ClipItem {
    makeItem(textSnapshot(text), at: date)
}

/// 造一张真 PNG，用来测图片路径
func makePNG(width: Int, height: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("无法创建位图") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("无法编码 PNG")
    }
    return png
}

func plistCount(in directory: URL) -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".plist") }.count
}

// ---------------------------------------------------------------- 文本

section("文本条目")
let multiline = textItem("line one\nline two\r\nline three")
expect(multiline.kind == .text, "识别为纯文本")
expect(multiline.preview == "line one ⏎ line two ⏎ line three", "换行折叠为 ⏎")
expect(multiline.text?.count == 28, "能取回原始文本")

let padded = textItem("  \n  hello  \n  ")
expect(padded.preview == "hello", "首尾/中间空行被压掉")
expect(textItem("   \n\t ").isBlankText, "纯空白被识别出来")

let rich = makeItem(snapshot([[
    ClipTypes.string.rawValue: Data("hi".utf8),
    ClipTypes.rtf.rawValue: Data("{\\rtf1}".utf8),
]]))
expect(rich.kind == .richText, "带 RTF 的识别为富文本")

// ---------------------------------------------------------------- 类型检测

section("类型检测")
let pngItem = makeItem(snapshot([[ClipTypes.png.rawValue: makePNG(width: 40, height: 20)]]))
expect(pngItem.kind == .image, "只有 PNG → 图片")

let tiffItem = makeItem(snapshot([[ClipTypes.tiff.rawValue: Data([0x01, 0x02])]]))
expect(tiffItem.kind == .image, "只有 TIFF → 图片")

let fileItem = makeItem(snapshot([[ClipTypes.fileURL.rawValue: Data("file:///tmp/a.txt".utf8)]]))
expect(fileItem.kind == .files, "fileURL → 文件")

let fileWithText = makeItem(snapshot([[
    ClipTypes.fileURL.rawValue: Data("file:///tmp/a.txt".utf8),
    ClipTypes.string.rawValue: Data("/tmp/a.txt".utf8),
]]))
expect(fileWithText.kind == .files, "文件和文本同时存在时优先判为文件")

let other = makeItem(snapshot([["com.example.weird": Data([0x00])]]))
expect(other.kind == .other, "白名单外的类型 → 其他")
expect(other.preview == "其他内容", "其他类型有占位预览")

// ---------------------------------------------------------------- 图片

section("图片处理")
let bigPNG = makePNG(width: 400, height: 200)
let imageItem = makeItem(snapshot([[ClipTypes.png.rawValue: bigPNG]]))
expect(imageItem.preview == "图片 400 × 200", "预览显示尺寸（实测：\(imageItem.preview)）")
expect(imageItem.thumbnail != nil, "生成了缩略图")
if let thumb = imageItem.thumbnail, let image = NSImage(data: thumb) {
    expect(image.size.width <= 128 && image.size.height <= 128, "缩略图被限制在 128px 以内")
    expect(image.size.width > image.size.height, "缩略图保持宽高比")
} else {
    expect(false, "缩略图能被 NSImage 解码")
}

let bothImageTypes = snapshot([[
    ClipTypes.png.rawValue: bigPNG,
    ClipTypes.tiff.rawValue: Data(repeating: 0xAB, count: 4096),
]])
let deduped = ClipItem.droppingRedundantImageTypes(bothImageTypes)
expect(deduped.contents[0][ClipTypes.tiff.rawValue] == nil, "有 PNG 时丢掉 TIFF")
expect(deduped.contents[0][ClipTypes.png.rawValue] != nil, "PNG 被保留")
expect(ClipItem.droppingRedundantImageTypes(tiffItem.snapshot).contents[0][ClipTypes.tiff.rawValue] != nil,
       "只有 TIFF 时不动它")

// ---------------------------------------------------------------- 文件

section("文件")
let threeFiles = makeItem(snapshot([
    [ClipTypes.fileURL.rawValue: Data("file:///tmp/a.txt".utf8)],
    [ClipTypes.fileURL.rawValue: Data("file:///tmp/b.txt".utf8)],
    [ClipTypes.fileURL.rawValue: Data("file:///tmp/c.txt".utf8)],
]))
expect(threeFiles.fileURLs.count == 3, "多 item 的文件列表完整保留")
expect(threeFiles.preview == "a.txt, b.txt, c.txt", "预览列出文件名")

let fourFiles = makeItem(snapshot((1...4).map {
    [ClipTypes.fileURL.rawValue: Data("file:///tmp/f\($0).txt".utf8)]
}))
expect(fourFiles.preview.contains("等 4 个文件"), "超过 3 个时折叠（实测：\(fourFiles.preview)）")

// ---------------------------------------------------------------- ClipStore

section("ClipStore 基本行为")
let store = ClipStore()
store.add(textItem("alpha"))
store.add(textItem("beta"))
store.add(textItem("gamma"))
expect(store.items.map(\.preview) == ["gamma", "beta", "alpha"], "最新的排在最前")

expect(store.add(textItem("gamma")) == .duplicateOfNewest, "重复最新一条被识别")
expect(store.items.count == 3, "重复最新一条不产生新条目")

expect(store.add(textItem("alpha")) == .promoted, "重复旧条目被提到最前")
expect(store.items.map(\.preview) == ["alpha", "gamma", "beta"], "提到最前后顺序正确")
expect(store.add(textItem("   \n  ")) == .rejected, "纯空白被拒绝")

section("selection")
expect(store.selectedIndex == 0, "新增后选中回到第一条")
store.moveSelection(by: 1)
expect(store.selectedIndex == 1, "向下移动")
store.moveSelection(by: -5)
expect(store.selectedIndex == 0, "向上移动不越界")
store.moveSelection(by: 99)
expect(store.selectedIndex == store.items.count - 1, "向下移动不越界")
store.select(index: 99)
expect(store.selectedIndex == store.items.count - 1, "非法索引被忽略")

// ---------------------------------------------------------------- 搜索

section("选中项按身份跟，不按下标（回归：插入新条目导致选错）")
let idStore = ClipStore()
idStore.add(textItem("A", at: Date(timeIntervalSince1970: 1)))
idStore.add(textItem("B", at: Date(timeIntervalSince1970: 2)))
idStore.add(textItem("C", at: Date(timeIntervalSince1970: 3)))
// items = [C, B, A]
idStore.select(index: 2)
expect(idStore.selectedItem?.text == "A", "选中第 3 条 = A")

// 模拟「面板开着的时候又复制了新东西」——新条目插到最前面
idStore.add(textItem("D", at: Date(timeIntervalSince1970: 4)))
expect(idStore.selectedItem?.text == "A", "插入新条目后仍然选中 A（不会滑到 B）")
expect(idStore.selectedIndex == 3, "A 的位置相应下移一位")
expect(idStore.items.first?.text == "D", "新条目在最前")

// 再来一次：连续插入两条
idStore.add(textItem("E", at: Date(timeIntervalSince1970: 5)))
idStore.add(textItem("F", at: Date(timeIntervalSince1970: 6)))
expect(idStore.selectedItem?.text == "A", "连续插入后依然选中 A")
expect(idStore.selectedIndex == 5, "位置下移两位")

// 方向键仍然按位置移动
idStore.moveSelection(by: -1)
expect(idStore.selectedItem?.text == "B", "向上移动一格到 B")
idStore.moveSelection(by: 1)
expect(idStore.selectedItem?.text == "A", "再向下回到 A")

// 被淘汰的条目不能让选中项悬空
let shrink = ClipStore(capacity: 3)
for i in 0..<6 { shrink.add(textItem("item-\(i)", at: Date(timeIntervalSince1970: Double(i)))) }
shrink.select(index: 2)
expect(shrink.selectedItem != nil, "淘汰之后选中项仍然有效")

section("提交的是「画面上高亮的那一条」")
let commitStore = ClipStore()
commitStore.add(textItem("A", at: Date(timeIntervalSince1970: 1)))
commitStore.add(textItem("B", at: Date(timeIntervalSince1970: 2)))
commitStore.add(textItem("C", at: Date(timeIntervalSince1970: 3)))
// items = [C, B, A]
commitStore.select(index: 0)
expect(commitStore.selectedItem?.text == "C", "模型选中 C")
expect(commitStore.itemToCommit?.text == "C", "还没渲染时退回模型值")

// 模拟「画面渲染慢了一格」：模型已是 C，但屏幕上高亮的是 B
commitStore.markRendered(commitStore.items[1].id)
expect(commitStore.itemToCommit?.text == "B", "提交用画面上的 B，而不是模型的 C")

// 渲染追上来之后，两者一致
commitStore.markRendered(commitStore.items[0].id)
expect(commitStore.itemToCommit?.text == "C", "渲染追上后提交 C")

// 换面板时清掉渲染记录，避免用到上一轮的
commitStore.beginPresentation(autoPasteAvailable: true)
expect(commitStore.renderedItemID == nil, "呼出面板时清掉上一轮的渲染记录")

section("搜索过滤")
let searchStore = ClipStore()
searchStore.add(textItem("git rebase --interactive"))
searchStore.add(textItem("npm run build"))
searchStore.add(textItem("git status --short"))

searchStore.setQuery("git")
expect(searchStore.filteredItems.count == 2, "命中 2 条")
expect(searchStore.isFiltering, "处于过滤状态")
expect(searchStore.selectedIndex == 0, "改搜索词后选中重置")

searchStore.setQuery("GIT")
expect(searchStore.filteredItems.count == 2, "大小写不敏感")

searchStore.setQuery("  git  ")
expect(searchStore.filteredItems.count == 2, "首尾空白被忽略")

searchStore.setQuery("npm")
expect(searchStore.filteredItems.count == 1, "命中 1 条")
expect(searchStore.selectedItem?.preview == "npm run build", "选中项跟着过滤列表走")

searchStore.setQuery("找不到的东西")
expect(searchStore.filteredItems.isEmpty, "无命中")
searchStore.moveSelection(by: 1)
expect(searchStore.selectedIndex == 0, "空列表时移动选择不越界")
expect(searchStore.selectedItem == nil, "空列表时没有选中项")

searchStore.clearQuery()
expect(searchStore.filteredItems.count == 3, "清空搜索后恢复全部")

let imageSearch = ClipStore()
imageSearch.add(makeItem(snapshot([[ClipTypes.png.rawValue: makePNG(width: 10, height: 10)]])))
imageSearch.add(textItem("普通文本"))
imageSearch.setQuery("图片")
expect(imageSearch.filteredItems.count == 1, "可以按类型名搜到图片")
imageSearch.setQuery("普通")
expect(imageSearch.filteredItems.count == 1, "可以搜到文本")

// ---------------------------------------------------------------- 上限

section("条数上限")
let capped = ClipStore(capacity: 3)
for i in 0..<5 {
    capped.add(textItem("item-\(i)", at: Date(timeIntervalSince1970: Double(i))))
}
expect(capped.items.count == 3, "裁剪到 3 条")
expect(capped.items.first?.preview == "item-4", "保留最新的")
expect(capped.items.last?.preview == "item-2", "挤掉最旧的")

section("体积上限")
let budgeted = ClipStore(capacity: 20, byteBudget: 250)
for i in 0..<5 {
    // 每条 100 字节
    budgeted.add(textItem(String(repeating: "\(i)", count: 100),
                          at: Date(timeIntervalSince1970: Double(i))))
}
let totalBytes = budgeted.items.reduce(0) { $0 + $1.totalBytes }
expect(totalBytes <= 250, "总大小被压到预算内（实测 \(totalBytes) 字节）")
expect(budgeted.items.count == 2, "只留下 2 条")
expect(budgeted.items.first?.preview.hasPrefix("4") == true, "留下的是最新的")

// ---------------------------------------------------------------- 持久化

section("持久化")
let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("paste-logictest-\(UUID().uuidString)", isDirectory: true)
let persistence = ClipPersistence(directory: tempDir)

let writing = ClipStore(persistence: persistence, capacity: 20)
writing.add(textItem("one", at: Date(timeIntervalSince1970: 1000)))
writing.add(textItem("two", at: Date(timeIntervalSince1970: 2000)))
writing.add(makeItem(snapshot([[ClipTypes.png.rawValue: bigPNG]]),
                     at: Date(timeIntervalSince1970: 3000)))
expect(plistCount(in: tempDir) == 3, "三条各写了一个文件")

let reloaded = ClipStore(persistence: persistence, capacity: 20)
expect(reloaded.items.count == 3, "重启后恢复 3 条")
expect(reloaded.items.map(\.preview) == ["图片 400 × 200", "two", "one"], "恢复后按时间倒序")
expect(reloaded.items[2].text == "one", "文本内容完整往返")
expect(reloaded.items[0].thumbnail != nil, "缩略图也能往返")
expect(reloaded.items[0].snapshot.contents[0][ClipTypes.png.rawValue] != nil, "图片数据完整往返")

section("持久化 · 淘汰会删文件")
let evictDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("paste-logictest-\(UUID().uuidString)", isDirectory: true)
let evictPersistence = ClipPersistence(directory: evictDir)
let evicting = ClipStore(persistence: evictPersistence, capacity: 2)
for i in 0..<4 {
    evicting.add(textItem("item-\(i)", at: Date(timeIntervalSince1970: Double(i))))
}
expect(plistCount(in: evictDir) == 2, "淘汰后目录里只剩 2 个文件（实测 \(plistCount(in: evictDir))）")

section("持久化 · 清空")
evicting.clear()
expect(plistCount(in: evictDir) == 0, "清空历史会删掉磁盘上的文件")
expect(ClipStore(persistence: evictPersistence).items.isEmpty, "重新加载也是空的")

section("持久化 · 损坏文件会被清掉")
let brokenDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("paste-logictest-\(UUID().uuidString)", isDirectory: true)
let brokenPersistence = ClipPersistence(directory: brokenDir)
try? Data("not a plist".utf8).write(to: brokenDir.appendingPathComponent("broken.plist"))
expect(ClipStore(persistence: brokenPersistence).items.isEmpty, "损坏文件不会让加载失败")
expect(plistCount(in: brokenDir) == 0, "损坏文件被删除，不会每次启动都报错")

// ---------------------------------------------------------------- ClipboardSnapshot

section("ClipboardSnapshot 快照与恢复")
let pb = NSPasteboard.general
// 先存下你当前的剪贴板，测完还回去
let userClipboard = ClipboardSnapshot.capture(from: pb)

pb.clearContents()
pb.setString("原始内容", forType: .string)
let captured = ClipboardSnapshot.capture(from: pb)
expect(captured != nil, "能抓到快照")

pb.clearContents()
pb.setString("别的内容", forType: .string)
let wrote = captured?.write(to: pb) ?? false
expect(wrote, "写回返回成功")
expect(pb.string(forType: .string) == "原始内容", "写回后内容正确")

// 回归测试：曾经这里因为复用了绑定在原剪贴板上的 NSPasteboardItem
// 而抛 NSInvalidArgumentException 直接崩掉进程。
expect(captured?.write(to: pb) ?? false, "能重复写回（item 可复用）")

let typeFiltered = ClipboardSnapshot.capture(
    from: [{
        let item = NSPasteboardItem()
        item.setString("keep", forType: .string)
        item.setData(Data([0x01]), forType: NSPasteboard.PasteboardType("com.example.drop"))
        return item
    }()],
    allowedTypes: [ClipTypes.string]
)
expect(typeFiltered?.contents[0].count == 1, "allowedTypes 能过滤掉不需要的类型")
expect(typeFiltered?.contents[0][ClipTypes.string.rawValue] != nil, "白名单内的类型被保留")

section("图片与多 item 写回剪贴板")
let imagePNG = makePNG(width: 60, height: 30)
snapshot([[ClipTypes.png.rawValue: imagePNG]]).write(to: pb)
expect(pb.data(forType: .png) == imagePNG, "PNG 字节原样写回剪贴板")
if let restored = NSImage(data: pb.data(forType: .png) ?? Data()) {
    expect(Int(restored.size.width) == 60 && Int(restored.size.height) == 30, "写回的图片能解码且尺寸正确")
} else {
    expect(false, "写回的图片能解码")
}

let multiFiles = snapshot([
    [ClipTypes.fileURL.rawValue: Data("file:///tmp/x.txt".utf8)],
    [ClipTypes.fileURL.rawValue: Data("file:///tmp/y.txt".utf8)],
])
multiFiles.write(to: pb)
expect(pb.pasteboardItems?.count == 2, "多 item 剪贴板写回后仍是 2 个 item（实测 \(pb.pasteboardItems?.count ?? -1)）")

section("立即轮询（修「复制完立刻按 Ctrl+V 看不到」）")
// 回归测试：定时器 0.3 秒一轮，通过 pollNow() 同步刷新才能保证
// 面板打开的瞬间就能看到刚复制的内容。
let raceMonitor = ClipboardMonitor()
var raceCaptured: ClipItem?
raceMonitor.onNewItem = { raceCaptured = $0 }

pb.clearContents()
pb.setString("just-copied", forType: .string)
raceMonitor.pollNow()
expect(raceCaptured?.text == "just-copied", "pollNow 同步捕获，不用等定时器")

// changeCount 没变时不应该重复上报
raceCaptured = nil
raceMonitor.pollNow()
expect(raceCaptured == nil, "剪贴板没变时不会重复上报")

if let userClipboard {
    userClipboard.write(to: pb)
    print("  · 已还原你原来的剪贴板")
}

// ---------------------------------------------------------------- Preferences

section("Preferences")
let suiteName = "com.local.paste.logictest"
let testDefaults = UserDefaults(suiteName: suiteName)!
testDefaults.removePersistentDomain(forName: suiteName)
Preferences.store = testDefaults
Preferences.registerDefaults()

expect(Preferences.autoPaste == true, "自动粘贴默认开启")
expect(Preferences.restoreClipboard == true, "恢复原剪贴板默认开启")

Preferences.autoPaste = false
expect(Preferences.autoPaste == false, "写入后读回一致")
Preferences.autoPaste = true
expect(Preferences.autoPaste == true, "能再次打开")

expect(Preferences.showMenuBarIcon == false, "菜单栏图标默认不显示")

// 默认值只在「键不存在」时生效，显式写入的 false 不能被默认值覆盖
Preferences.restoreClipboard = false
Preferences.registerDefaults()
expect(Preferences.restoreClipboard == false, "显式关闭不会被默认值覆盖")

// ---------------------------------------------------------------- 清理与汇总

try? FileManager.default.removeItem(at: tempDir)
try? FileManager.default.removeItem(at: evictDir)
try? FileManager.default.removeItem(at: brokenDir)

print("\n----------------------------------------")
if failures == 0 {
    print("全部通过：\(checks) 项断言")
    exit(0)
} else {
    print("失败 \(failures) / \(checks) 项断言")
    exit(1)
}
