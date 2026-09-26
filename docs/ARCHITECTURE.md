# 架构与实现笔记

这份文档解释这个项目**为什么这么写**，不是复述代码做了什么。
重点放在那些「不这么写就一定出问题」的地方 —— 每一条都是实测踩出来的。

```
共 3943 行：应用 17 个 Swift 文件 2316 行 + 工具 4 个 1008 行 + 脚本 5 个 606 行
（另有 Package.swift 13 行）
```

---

# 第一部分：工程配置

## 1. `Package.swift` —— 13 行，替代整个 Xcode 工程

```swift
// swift-tools-version:5.9
let package = Package(
    name: "Paste",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Paste", path: "Sources/Paste")]
)
```

**要点：这份工程不需要完整 Xcode，只要有 Command Line Tools。**

多数 macOS GUI 教程默认你装 Xcode，但 `swiftc` + macOS SDK 足够编译一个 AppKit/SwiftUI 应用。
实测 `swiftc -target arm64-apple-macos13.0` 能直接链 AppKit、SwiftUI、Carbon、ServiceManagement。

代价是**没有 `xcodebuild`、没有 Interface Builder**，所以：

- 界面全部用代码写（没人画 xib）
- `.app` 目录结构和 `Info.plist` 得手工组装 → 见 `build.sh`

换来的是：构建只要 2–5 秒，整个工程可以 `git clone` 后直接跑，不需要 `.xcodeproj` 那种容易冲突的文件。

## 2. `Resources/Info.plist` —— 三个字段决定了应用的行为

```xml
<key>LSUIElement</key><true/>          <!-- ① 不进 Dock、不进 Cmd+Tab -->
<key>NSHighResolutionCapable</key><true/>
<key>NSAppSleepDisabled</key><true/>   <!-- ② 关掉 App Nap -->
<key>CFBundleIconFile</key><string>AppIcon</string>
```

**① `LSUIElement = true`** 把应用变成「后台应用」（accessory）。
它不出现在 Dock、不出现在 `Cmd+Tab`，只能通过菜单栏图标或全局热键使用。

这是剪贴板工具的**行业惯例**：它是个常驻工具，不是你要切过去的应用。

**② `NSAppSleepDisabled = true`** 是排查很久才发现的。

macOS 的 App Nap 会节流后台应用的**渲染**。这个应用永远不是前台应用，
于是 SwiftUI 的状态变了、画面却不重绘 —— 表现为「方向键移动了选中项，高亮却不动」，
用户按回车时瞄的还是上一行。关掉 App Nap 才稳定。

**③ 图标用 `.icns`** 而不是 asset catalog —— 手工组装的 bundle 没有 `Assets.car` 可放。

## 3. `build.sh` —— 111 行，构建流水线

顺序**不能变**：

```
swift build          ── 编译
    ↓
组装 .app 目录        ── 手工建 Contents/MacOS、Contents/Resources
    ↓
strip -x             ── ⚠️ 必须在签名之前
    ↓
codesign             ── 签名
```

### 为什么 `strip` 必须在签名前

`strip` 会改写二进制。签名是对二进制内容的承诺 —— **先签名再 strip，签名必然失效**。

`strip -x` 去掉的是 `__LINKEDIT` 段里的本地符号表，占了二进制一半以上
（590 KB → 342 KB）。这是个本地工具，不需要调试符号。

### 安装用 `ditto` 而不是 `rm -rf` + `cp`

```bash
# ✗ 曾经这么写，导致「辅助功能」授权反复失效
rm -rf "$DEST"
cp -R "$APP_DIR" "$DEST"

# ✓ 现在这样
ditto "$APP_DIR" "$DEST"
```

**`rm -rf` 会换掉 bundle 的 inode。** macOS 的 TCC（权限数据库）记录的是应用身份，
删掉再建会让授权对不上，用户得反复重新授权 —— 这个坑折腾了好几轮才定位到。

`ditto` 原地更新，bundle 的目录身份保持稳定。实测改代码重新编译后授权依然有效。

另外脚本会对比新旧二进制的哈希，**变化时主动提示**「可能需要重新授权」。

## 4. `setup-signing-cert.sh` —— 让授权不受重新编译影响

### 要解决的问题

ad-hoc 签名（`codesign --sign -`）的 **designated requirement（DR）** 是：

```
designated => cdhash H"91cd0f4b..."      ← 直接绑定二进制哈希
```

也就是「这个应用的身份 = 这份二进制」。**每次编译哈希都变，macOS 就认为是个全新应用**，
之前授予的权限作废。

用自己的证书签名后，DR 变成：

```
designated => identifier "com.local.paste" and certificate leaf = H"916d77e1..."
```

只跟证书绑定。实测改动源码重新编译后 CDHash 从 `427552b7` 变成 `ed91145f`，
**而 DR 一字不差**。

### 脚本里三个真实的坑

**① OpenSSL 3.x 的 PKCS#12 加密 macOS 认不了**

```
MAC verification failed during PKCS12 import
```

必须退回旧算法：

```bash
-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
```

**② p12 密码不能为空。** 空密码报**同样**的错误 —— 改了加密参数仍然失败，
很容易误判成「加密问题没解决」。

**③ 幂等与中断恢复。** 脚本要能重复执行；如果上次在「导入成功、设信任」之间中断，
重跑要能识别出「证书在但没信任」，只补信任，**而不是重新导入**（那会产生两张同名证书）。

## 5. `package.sh` —— 打包成 dmg

产物 963 KB，重点是**内容只有 784 KB、dmg 却有 963 KB** —— 磁盘映像本身有约 250 KB 开销。
所以压缩格式的选择很重要：

| 格式 | 大小 | 能否挂载 |
|---|---|---|
| `UDZO`（zlib，默认） | 1.03 MB | ✓ |
| `UDBZ`（bzip2） | **0.96 MB** | ✓ |
| `ULMO`（lzfse） | 0.82 MB | **✗ 挂不上** |

**试过 `ULMO` 能压到 0.82 MB，但 `hdiutil attach` 报「资源暂时不可用」。**
压得再小、挂不上也是废的 —— 所以每个候选格式都实际挂载验证过，不是只看文件大小。

## 6. `status.sh` —— 224 行，最实用的一个脚本

这个应用**没有 Dock 图标、默认也没有菜单栏图标**。所以「它到底在不在跑」
从界面上完全看不出来 —— 而进程一旦没了，`Ctrl+V` 就彻底没反应，看起来像坏了。

脚本把状态一次说清：应用包完整性、进程、热键、辅助功能权限、菜单栏图标、开机自启、历史条数。

**两个细节：**

- 只在真终端里上色（`[ -t 1 ]`），管道输出时保持纯文本，否则重定向到文件全是乱码
- 最后一行**根据实际状态给出最该做的那件事**，而不是罗列一堆信息让人自己判断

## 7. `test.sh` + `Tools/LogicTest/` —— 没有 XCTest 的测试

只用 Command Line Tools 时，`swift test` 用不了（XCTest 路径解析失败）：

```
xcrun: error: unable to lookup item 'PlatformPath'
```

所以测试是一个**独立可执行文件**，手写断言：

```swift
func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if condition { print("  ✓ \(label)") }
    else { failures += 1; print("  ✗ \(label)") }
}
```

用 `swiftc` 把被测源码和测试一起编译：

```bash
swiftc -o "$OUT" Tools/LogicTest/main.swift \
  Sources/Paste/ClipItem.swift Sources/Paste/ClipStore.swift ...
```

**关键约束：被测代码不能依赖 GUI 或系统状态。** 这条约束反过来推动了架构 ——
见下面 `ClipStore` 的依赖注入。

> ⚠️ 一个坑：`swiftc` 只允许 **`main.swift`** 里有顶层代码。
> 测试和演示数据生成器都因此放在 `Tools/Xxx/main.swift`。

---

# 第二部分：应用架构

## 数据流

```
                  ┌──────────────────┐
   系统剪贴板  ───→ │ ClipboardMonitor │ 轮询 changeCount
                  └────────┬─────────┘
                           │ ClipItem
                           ▼
                  ┌──────────────────┐      ┌──────────────────┐
                  │    ClipStore     │ ───→ │ ClipPersistence  │ 磁盘（一条一个 plist）
                  │  items / 选中项   │      └──────────────────┘
                  └────────┬─────────┘
                           │ @Published
                           ▼
                  ┌──────────────────┐
                  │   ClipListView   │ SwiftUI
                  └────────┬─────────┘
                           │ 用户按回车
                           ▼
                  ┌──────────────────┐
                  │ PanelController  │ 写剪贴板 → 收面板 → 合成 Cmd+V
                  └──────────────────┘
```

## 1. `ClipboardSnapshot` —— 最先要理解的数据结构

```swift
struct ClipboardSnapshot: Codable, Equatable {
    let contents: [[String: Data]]   // [每个 item 的 [类型: 数据]]
}
```

用 `[[String: Data]]` 而不是合并成一个字典，是为了保住**多 item 剪贴板** ——
从访达一次复制多个文件时，剪贴板里是多个 item，每个带一个 `.fileURL`。

**这里踩过两次崩溃，都跟 AppKit 的 `NSPasteboardItem` 有关：**

```swift
// 崩溃 1：从剪贴板拿到的 item 已绑定在原 pasteboard 上
let items = pasteboard.pasteboardItems!
pasteboard.writeObjects(items)
// NSInvalidArgumentException: It is already associated with another pasteboard.

// 崩溃 2：新建的 item 写出去一次后也被绑定，第二次照样崩
```

**所以这个类型存的是原始 `Data`，每次写入现场造新 item。**

这两个崩溃都在「有权限时才走到」的路径上 —— 没有辅助功能权限时根本走不到恢复逻辑，
所以第一次测试完全没暴露。`test.sh` 里有对应的回归断言。

## 2. `ClipItem` —— 采集、识别、预览

```swift
struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    var capturedAt: Date
    var sourceApp: String?
    let snapshot: ClipboardSnapshot
    let kind: ClipKind          // text / richText / image / files / other
    let preview: String         // 列表里显示的一行
    let searchText: String      // 预先算好的小写搜索索引
    let thumbnail: Data?        // 图片缩略图（PNG）
}
```

**几个设计决定：**

- **`preview` / `searchText` / `thumbnail` 在采集时算好并存下来**，不是每次渲染再算。
  图片解码和文本折叠都不便宜，而列表会频繁重绘。
- **类型白名单**（`ClipTypes.allowed`）只留 6 种：`public.utf8-plain-text`、`public.rtf`、
  `public.html`、`public.png`、`public.tiff`、`public.file-url`。
  一块剪贴板上可能有几十种类型（`com.apple.flat-rtfd`、各种私有格式），全存又占地方又没用。
- **图片同时有 PNG 和 TIFF 时丢掉 TIFF**。实测同一张图 PNG 2095 字节、TIFF 323390 字节 ——
  TIFF 通常未压缩，留着让历史和磁盘膨胀 150 倍。

## 3. `ClipboardMonitor` —— 轮询与「自身写入」

**macOS 没有剪贴板变更通知 API**，只能轮询：

```swift
guard pb.changeCount != lastChangeCount else { return }
let changeCount = pb.changeCount
lastChangeCount = changeCount
```

**核心难点：区分「用户复制」和「我们自己写的」。**

自动粘贴要写两次剪贴板（写入选中内容、粘贴后恢复原内容）。
如果这两次都被当成用户复制，历史就被搞乱了。

```swift
private var selfWrites: Set<Int> = []

func noteSelfWrite(_ changeCount: Int) { selfWrites.insert(changeCount) }
```

**用精确的 `changeCount` 记账，而不是「一段时间内全部忽略」——
时间窗口会误吞用户在那个窗口里真正复制的内容。**

### 轮询之外的两次同步刷新

定时器 0.3 秒一轮，而用户「复制 → 立刻按 Ctrl+V」的间隔常常比这短。所以两个时机必须主动刷一次：

| 时机 | 不刷会怎样 |
|---|---|
| **呼出面板之前** | 面板显示的是一份不含刚复制内容的旧列表 |
| **覆盖剪贴板之前** | 那次复制被我们的写入盖掉，`changeCount` 又被记成自身写入，**内容永久丢失** |

```swift
func pollNow() { poll() }   // 就是把私有的 poll() 暴露出来
```

### 过滤密码管理器

```swift
private let concealedTypes: Set<NSPasteboard.PasteboardType> = [
    NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    NSPasteboard.PasteboardType("com.agilebits.onepassword"),
]
```

这是 nspasteboard.org 的约定，1Password 之类的密码管理器会给内容打上标记。
**不处理的话，你的密码会被存进剪贴板历史。**

## 4. `ClipStore` —— 状态中枢，也是测试的主战场

```swift
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var query: String = ""
    @Published private(set) var selectedItemID: UUID?   // ← 注意不是 index
    private(set) var renderedItemID: UUID?               // ← 不是 @Published，见下
    ...
}
```

### 原则一：选中项按「身份」跟，不按「位置」跟

**这是用户发现的一个真 bug。** 原来存的是 `selectedIndex: Int`：

```
面板打开时：  [A, B, C, D, E]   用户选了 index 3 = D
插入新条目后：[X, A, B, C, D]   所有条目下移一位
             index 3 现在指向 C ← 用户按回车，粘出来的是 C
```

**下标是位置，不是身份。** 一旦列表前面插入新条目（用户又复制了东西、或粘贴后把条目提到最前），
同一个下标就指向了**另一条**内容。

改成 `UUID` 之后，插入多少条都不会跟丢 —— 高亮停在用户选的那条上，只是往下挪一格。

```swift
var selectedIndex: Int {   // 保留一个计算属性，只用于滚动和日志
    guard let id = selectedItemID else { return 0 }
    return filteredItems.firstIndex { $0.id == id } ?? 0
}
```

### 原则二：提交「画面上高亮的那一条」

`renderedItemID` 和 `selectedItemID` 的区别是这份代码里最微妙的地方：

| | 含义 |
|---|---|
| `selectedItemID` | **模型**状态 —— 按键处理完就更新了 |
| `renderedItemID` | **画面上**实际高亮的那条 —— 由视图在渲染时上报 |

**SwiftUI 的渲染可能滞后于模型。** 用户的眼睛认的是屏幕上那条，所以提交必须以它为准：

```swift
var itemToCommit: ClipItem? {
    let id = renderedItemID ?? selectedItemID
    guard let id else { return filteredItems.first }
    return filteredItems.first { $0.id == id } ?? filteredItems.first
}
```

视图每次渲染时上报：

```swift
var body: some View {
    let selectedID = store.selectedItemID
    let _ = store.markRendered(selectedID)   // ← 在 body 求值阶段记录
    ...
}
```

`renderedItemID` **刻意不加 `@Published`** —— 它是在 body 求值期间写入的，
发布出去会造成渲染循环。

### 原则三：依赖注入，让模型层不碰系统状态

```swift
func beginPresentation(autoPasteAvailable: Bool) { ... }
```

「有没有辅助功能权限」是系统状态，`ClipStore` 不去查，由 `PanelController` 注入。

**这条不只是洁癖**：`ClipStore` 一旦引用了 `Accessibility`，逻辑测试就编译不过 ——
测试的文件列表里没有 `Accessibility.swift`，`Accessibility` 会被解析成**系统同名模块**，
报 `module 'Accessibility' has no member 'isTrusted'`。这个错误真实发生过。

### 上限与淘汰

```swift
static let maxItems = 20
static let maxTotalBytes = 50 * 1024 * 1024
```

条数上限挡不住图片。两张 Retina 截图就能超过 50 MB，所以还要有总量预算，从最旧的开始淘汰。
两个上限都做成了可注入的构造参数，测试时用 `capacity: 3, byteBudget: 250` 就能廉价验证淘汰逻辑。

## 5. `ClipPersistence` —— 一条一个 plist

```
~/Library/Application Support/com.local.paste/items/<uuid>.plist
```

**为什么不把整个历史写成一个文件：** 历史里可能有图片，几十 MB 每次复制都全量重写太浪费。
一条一个文件之后，「新增」只写一个文件，「淘汰」只删一个文件。

**顺序不靠文件名**，而是加载后按 `capturedAt` 排序 —— 文件名保持 UUID，简洁且不冲突。

**文件权限是 `0700`/`0600`：** 剪贴板历史里可能有密码、token、私人对话。
默认的 `0755`/`0644` 会让同机其他用户也能读。读取旧文件时顺手修正存量权限（迁移）。

## 6. `PastePanel` + `PanelController` —— 最难的部分

### `.nonactivatingPanel` 是整个设计的基石

```swift
final class PastePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

初始化时用 `styleMask: [.nonactivatingPanel, ...]`。

**普通窗口一弹出就会激活我们的应用，目标 App 失焦** —— 用户随后的 `Cmd+V`
（以及我们合成的 `Cmd+V`）就打到我们自己身上了。

实测确认：面板弹出后 `NSWorkspace.frontmostApplication` 仍是原来那个 App（比如微信）。

### 自动粘贴的顺序不能错

```swift
1. 解析要粘贴哪一条（在 pollNow 之前，否则下标会错位）
2. pollNow()                    // 把当前剪贴板内容收进历史
3. 快照原剪贴板（用于稍后恢复）
4. 写入选中内容
5. noteSelfWrite()              // 告诉监听器这是自己写的
6. store.promote(item)          // 提到历史最前
7. hide()                       // ← 必须先收面板
8. 等面板真的让出 key window
9. 合成 Cmd+V
10. 延迟 750ms 再恢复原剪贴板
```

**第 7 步为什么关键：** 面板还在的话，合成的 `Cmd+V` 会打进**我们自己的搜索框**，
目标 App 收不到粘贴。用户随后自己按 `Cmd+V` 时剪贴板已被恢复成旧内容，
粘出来自然「不是选的那条」。

**第 8 步踩过一个坑。** 最初写的是：

```swift
// ✗ 看起来合理，实际等于没有等待
if panel.isVisible || panel.isKeyWindow { 等一会儿 } else { 立刻发送 }
```

`orderOut()` 之后 `panel.isVisible` / `isKeyWindow` 在 **AppKit 这一侧立刻就变成 false**，
但这个检查每次都直接通过 —— 结果按键在 `hide()` 之后 **2ms** 就发出去了，
而窗口服务器完成 key window 交接是**异步**的。

现在改成「先给一段固定延迟（不依赖那两个标志），再确认状态」：

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    self.afterPanelReleasesFocus { ... }
}
```

日志里加了时间戳，实测稳定在 315ms（之前是 2ms）。

**第 10 步的延迟：** 有些 App 是**异步**读剪贴板的，恢复太快它会拿到旧值。
抢跑的代价是粘出**错误的内容**，比剪贴板多留一会儿严重得多，所以给到 750ms。

## 7. `ClipListView` —— SwiftUI 上的三个坑

### 坑一：`.id()` 会覆盖 `ForEach` 的身份

```swift
// ✗ 曾经这么写
ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
    ClipRow(...)
    .id(index)          // ← 把身份从「条目 UUID」改成「数组下标」
}
```

`ForEach` 已经用条目的 UUID 做身份，`.id(index)` 又把它改成数组下标。
**`LazyVStack` 正是靠身份来回收复用行视图的** —— 身份被改成位置之后，
列表一变，行视图按位置复用，显示的内容和那个下标就可能不是同一条。

`.id()` 应当只用于**没有其它身份来源**的视图（比如这里的 `ScrollView`，
用 `presentationID` 强制重建以复位滚动位置）。

### 坑二：身份读在哪个阶段，决定了会不会重绘

`NSHostingView` + `@ObservedObject` 在这个 `.nonactivating` 面板里**不可靠** ——
状态变了它不一定重新求值。实测两张间隔 400ms 的面板截图**字节完全相同**，
`body` 日志显示它根本没再求值过。

```swift
// 现在：状态改完就显式同步画面
func refreshContent() {
    hosting.rootView = makeRootView()   // 重设 rootView，稳定触发重绘
}
```

方向键、清除搜索、捕获新条目之后都调一次。实测**同一 tick 内就生效**，没有延迟。

### 坑三：`.center` 锚点让视线追不上

```swift
// ✗ 每按一次方向键，列表大幅滚动一次 + 120ms 动画
withAnimation(.easeOut(duration: 0.12)) {
    proxy.scrollTo(id, anchor: .center)
}

// ✓ 只在选中行快出界时才滚，且不做动画
proxy.scrollTo(id, anchor: nil)
```

`.center` 让列表**每一步都重新居中**，用户的视线在跟着滚动的列表跑，
而高亮是立刻跳的 —— 两者错开就会选错行。

## 8. `HotKeyManager` —— Carbon，零权限

```swift
RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey),
                    id, GetApplicationEventTarget(), 0, &hotKeyRef)
```

**选 Carbon 而不是 `CGEventTap` 的原因：不需要任何权限。**

- `RegisterEventHotKey`：零权限，能抢占前台 App 的按键
- `CGEventTap`：需要「输入监控」+「辅助功能」双权限，还要处理 tap 超时被系统禁用
- `NSEvent.addGlobalMonitorForEvents`：只能旁听、不能吞事件，不适用

**技术点：C 回调不能捕获上下文**，所以用静态转发口把事件送回实例：

```swift
fileprivate static var dispatch: (() -> Void)?

// 回调里（无捕获）：
HotKeyManager.dispatch?()
```

## 9. `Accessibility` / `Paster` / `LoginItem` —— 三个小模块

```swift
// 权限：只有合成按键需要它
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }
}

// 合成 Cmd+V
enum Paster {
    static func pressCommandV() -> Bool {
        guard Accessibility.isTrusted else { return false }
        // 走 HID 事件流，交给当前前台 App
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

// 开机自启
enum LoginItem {
    static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        try SMAppService.mainApp.register()   // macOS 13+
    }
}
```

三个都是 `enum` + `static` —— **不需要实例的无状态命名空间**，比 `struct` + `private init()`
更直白地表达「这只是命名空间」。

## 10. `Log` 与 `DebugFlags` —— 一个后台工具必须有日志

**这是个后台应用，用 `open` 启动时 stderr 是看不见的**，所以日志**默认就写文件**：

```
~/Library/Application Support/com.local.paste/paste.log
```

超过 512 KB 自动轮转成 `paste.log.1`，文件权限 `0600`。

**隐私考量：默认不记剪贴板内容。** 只记类型和字节数：

```
提交 index=19（共 20 条）：image 251206 字节
```

需要排查「选错行」这类问题才开 `PASTE_DEBUG_LOG_CONTENT=1`，那时才记内容前 24 字。

`DebugFlags` 集中管理所有调试开关：

```swift
enum DebugFlags {
    static var dryRun: Bool          // 走完流程但不真发按键
    static var query: String?        // 预置搜索词
    static var logContent: Bool      // 记录面板完整列表
    static var snapshotOnCommit: Bool // 回车瞬间截面板
    static var selectOnShow: Int?    // 把选中项设到第 N 条
    static var loginItemAction: String?
}
```

## 11. `AppDelegate` + `main.swift` —— 装配与调试钩子

```swift
// main.swift（9 行）
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不进 Dock、不进 Cmd+Tab
app.run()
```

`AppDelegate` 只负责**装配**：创建 monitor / store / panelController / hotKey，接线，然后不管了。

**调试钩子用信号，不需要 GUI 就能驱动：**

| 信号 | 作用 |
|---|---|
| `kill -USR1` | 等同按一次 `Ctrl+V` |
| `kill -USR2` | 等同选中最后一条并粘贴 |
| `kill -WINCH` | 选中项下移一格 + 前后各截一张面板图 |

第二行那个是本项目最重要的调试手段：

**应用给自己的窗口截图，不需要「屏幕录制」权限。**

```swift
view.cacheDisplay(in: bounds, to: rep)   // 把面板渲染结果存成 PNG
```

我的 shell 没有屏幕录制权限，`screencapture` 只能截到壁纸 —— 所以很长一段时间
只能靠日志推测面板长什么样，绕了很多弯路。让应用自己截图之后，问题一次就看清楚了。

---

# 第三部分：贯穿全局的原则

## 1. 用户看到的才算数

`itemToCommit` 取「画面上高亮的那条」而不是模型值，是这条原则最直接的体现。
**当渲染和模型可能不一致时，以用户感知到的那一侧为准。**

## 2. 精确记账，不用时间窗口

`selfWrites` 用具体的 `changeCount` 而不是「0.5 秒内全部忽略」。
时间窗口看起来更简单，但会吞掉用户在窗口内真正做的操作。

## 3. 顺序即正确性

写剪贴板 → 收面板 → 等焦点交还 → 发按键 → 延迟恢复。
这些步骤少一步或换个顺序都会出错，所以代码里每一步都写了「为什么是这个顺序」。

## 4. 依赖注入换可测性

凡是碰系统状态（权限、剪贴板、时钟）的地方，都从外部注入。
`ClipStore` 因此可以脱离 GUI 做单元测试，93 项断言全部不需要界面。

## 5. 注释解释「为什么」，不解释「是什么」

```swift
// ✗ 「把选中项设为 nil」
// ✓ 「等这一轮渲染重新记录」
```

反直觉的地方一定写下踩过的坑，包括**崩溃的原始报错信息**：

```swift
// 直接 writeObjects 回去会抛
// NSInvalidArgumentException: It is already associated with another pasteboard.
```

## 6. 不信任「看起来对」的东西

- 每个 dmg 压缩格式都**实际挂载验证**，而不是只看文件大小（`ULMO` 就是因此被否掉的）
- 发 Release 前**重新下载**比对 SHA256，而不是看 API 返回成功
- 记忆里的行为都写进日志用时间戳验证（`hide()` → 发按键从 2ms 变成 315ms 就是这样发现的）

## 7. 破坏性操作先备份

- 重写 git 历史前先 `git bundle create --all`
- 截图前先备份用户的真实剪贴板历史，截完原样恢复

---

# 附：文件速查

| 文件 | 行数 | 职责 |
|---|---|---|
| `main.swift` | 9 | 进程入口，设为 accessory |
| `AppDelegate.swift` | 319 | 装配各模块 + 菜单栏 + 调试钩子 |
| `ClipboardMonitor.swift` | 88 | 轮询 changeCount，过滤受保护内容 |
| `ClipboardSnapshot.swift` | 68 | 剪贴板原始数据的快照与写回 |
| `ClipItem.swift` | 240 | 条目模型：类型识别、预览、缩略图 |
| `ClipPersistence.swift` | 108 | 磁盘存储（一条一个 plist） |
| `ClipStore.swift` | 212 | 历史列表、去重、上限、搜索、选中 |
| `PanelController.swift` | 478 | 面板生命周期 + 粘贴流程 |
| `PastePanel.swift` | 36 | 非激活面板（不抢焦点） |
| `ClipListView.swift` | 319 | SwiftUI 列表界面 |
| `SearchFieldView.swift` | 49 | 包装 `NSSearchField` |
| `HotKeyManager.swift` | 104 | Carbon 全局热键 |
| `Paster.swift` | 28 | 合成 `Cmd+V` |
| `Accessibility.swift` | 28 | 辅助功能权限 |
| `LoginItem.swift` | 35 | 开机自启 |
| `Preferences.swift` | 47 | 用户偏好 |
| `Log.swift` | 148 | 日志 + 调试开关 |
