# Paste

<img src="icon-preview.png" width="128" alt="Paste 图标">

macOS 剪贴板历史工具。按 **Ctrl+V** 呼出面板，搜一下、挑一条，**自动粘到原来的位置**。

当前是 **V3**：多类型 + 持久化 + 搜索 + 开机自启。

---

## 快速开始

```bash
./setup-signing-cert.sh     # 可选：建自签名证书，让辅助功能授权在重新编译后不失效
./build.sh                  # 构建出 Paste.app（只用 Command Line Tools）
./build.sh release install  # 顺便装到 /Applications（开机自启需要）
open Paste.app              # 运行
./status.sh                 # 出问题了先跑这个
```

## 它到底在不在跑？

Paste 是个 `.accessory` 后台应用：**没有 Dock 图标、没有窗口**，
所以「进程还在不在」从界面上完全看不出来 —— 而进程一旦没了，
`Ctrl+V` 就彻底没反应，看起来就像「坏了」。

**默认不显示菜单栏图标**（见下），所以判断「在不在跑」主要靠：

- **`./status.sh`**：一眼看全所有状态
- 直接按 `Ctrl+V`：面板出来就说明在跑

如果开启了菜单栏图标，它还能额外提示权限状态：
图标右下角**多一个点**表示缺「辅助功能」权限（回车只会复制）。

```bash
./status.sh            # 检查：应用包 / 进程 / 热键 / 权限 / 自启 / 历史
./status.sh start      # 没在跑就启动
./status.sh restart    # 重启
./status.sh log        # 实时跟踪日志
```

输出长这样：

```
Paste 状态
──────────────────────────────────────────────────
  ✓ 应用包      /Applications/Paste.app（4 个文件，签名有效）
  ✓ 进程         运行中（PID 35749，启动于 …）
  ✓ Ctrl+V 热键  已注册
  ✗ 辅助功能权限 未授权 —— 回车只会复制，不会粘贴
  ✓ 开机自启   已开启（下次登录会自动启动）
  ✓ 历史         16 条，占用 60K
──────────────────────────────────────────────────
下一步：去「辅助功能」里把 /Applications/Paste.app 加上并打开开关
```

**首次使用需要授予「辅助功能」权限**（合成 Cmd+V 必需）：

1. 按一次 `Ctrl+V` 选一条内容，会弹出系统引导框
2. 或者点菜单栏图标 → **打开辅助功能设置…**
3. 在「隐私与安全性 → 辅助功能」里勾选 **Paste**

没授权也能用：内容会放进剪贴板，只是要你自己按 `Cmd+V`。
**这种情况下面板顶部会显示一条橙色提示**，点它直接跳到设置页——
否则你按回车只会看到面板消失，完全不知道发生了什么。

> 授权一次就够：签名用的是固定证书，以后改代码重新编译不会让授权失效。

## 使用方法

| 操作 | 效果 |
|---|---|
| `Ctrl+V` | 在鼠标位置呼出/收起面板 |
| **直接打字** | 实时搜索（支持中文输入法） |
| `↑` `↓` | 上下选择 |
| `Enter` | 粘贴选中项到原 App |
| `Esc` | 有搜索词时先清空，再按一次关闭 |
| `⌘Q` | 退出（没有菜单栏图标时，这是界面上唯一的退出方式） |
| 鼠标点击 | 直接粘贴该条 |
| 点到别处 | 面板自动关闭 |

### 左列的数字

每行最左边的大号数字是**位置标签**，不是快捷键 —— 用来确认「第几条是哪一条」。
数字键会正常输入到搜索框（以前 1-9 被抢去做快选，导致搜 `16` 这样的内容打不进去）。

### 支持的剪贴板类型

| 类型 | 说明 |
|---|---|
| 纯文本 / 富文本 | 保留 RTF、HTML |
| 图片 | 列表里显示缩略图 |
| 文件 | 支持一次复制多个文件（从访达多选） |

两个自动优化：

- **图片同时提供 PNG 和 TIFF 时只留 PNG**。实测同一张图 PNG 2095 字节、TIFF 323390 字节，
  留着 TIFF 会让历史和磁盘白白膨胀 150 倍。
- 单条超过 **20 MB** 不收；历史总量超过 **50 MB** 时从最旧的开始淘汰。
  图片很容易把历史撑爆，光靠「最多 20 条」挡不住。

密码管理器（1Password 等）的内容会带 `org.nspasteboard.ConcealedType` 标记，**会被跳过**。

### 菜单栏

- 自动粘贴状态（就绪 / 需要权限 / 已关闭）
- 历史条数
- 自动粘贴 / 粘贴后恢复原剪贴板 / 开机自启 三个开关
- 打开辅助功能设置… / 打开历史文件夹…
- 显示历史 / 清空历史 / 退出

## ⚠️ 关于 Ctrl+V 这个键位

macOS 里 `Ctrl+V` 有两个既有含义：

- Cocoa 文本框的 Emacs 绑定 **向下翻页**
- 终端里 readline 的 `quoted-insert`

本工具通过 `RegisterEventHotKey` 注册，会**全局抢占**这个组合键，上面两个功能会失效。
想换键位就改 `Sources/Paste/HotKeyManager.swift` 的 `registerCtrlV()`：

```swift
// Ctrl+Shift+V
register(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey))
```

## ⚠️ 重新编译会导致授权失效（一条命令解决）

`build.sh` 默认用 ad-hoc 签名（`codesign --sign -`）。**二进制一变，签名哈希就变，
macOS 会认为这是一个全新的 App**，之前勾选的「辅助功能」就作废了。

原因在于签名的 **designated requirement**（macOS 识别 App 身份的依据）：

| 签名方式 | designated requirement | 重新编译后 |
|---|---|---|
| ad-hoc | `cdhash H"91cd0f4b..."` | **每次都变** → 授权失效 |
| 自签名证书 | `identifier "com.local.paste" and certificate leaf = H"916d77e1..."` | **只跟证书绑定** → 不变 |

所以建一个固定的自签名证书就行：

```bash
./setup-signing-cert.sh
```

之后 `./build.sh` 会**自动发现并使用**这个证书，不需要改脚本。
要撤销就 `./setup-signing-cert.sh --remove`。

实测验证过：改动源码重新编译后 CDHash 从 `427552b7…` 变成 `ed91145f…`，
而 DR 一字不差。

脚本做的事和踩过的坑：

- 生成 RSA-2048 + `extendedKeyUsage=codeSigning` 的证书，导入登录钥匙串
- **只授权 `/usr/bin/codesign` 使用私钥**，不是 `-A` 对所有程序放开
- 信任设置走**用户域**（`security add-trusted-cert` 不加 `-d`），不需要管理员密码
- ⚠️ OpenSSL 3.x 默认的 PKCS#12 加密 macOS 的 `security` 认不了，会报
  `MAC verification failed during PKCS12 import`，必须退回 SHA1/3DES；
  **而且密码不能为空**，空密码报同样的错
- 可重复执行，已就绪就跳过；如果上次在「导入成功、设信任」之间中断，
  重跑只补信任而不会重复导入（避免出现两张同名证书）

<details>
<summary>手工做法（不想跑脚本的话）</summary>

1. 打开「钥匙串访问」→ 菜单「钥匙串访问 → 证书助理 → 创建证书…」
2. 名称填 `Paste Self Signed`，身份类型选「自签名根证书」，证书类型选「代码签名」
3. 把 `build.sh` 里的签名那行改成
   `codesign --force --sign "Paste Self Signed" "$APP_DIR"`

</details>

## 菜单栏图标

**默认不显示。** Paste 只通过 `Ctrl+V` 使用，界面上唯一的东西就是那个面板。

关掉图标是有代价的，清楚这些再决定：

| 失去的东西 | 替代方式 |
|---|---|
| 一眼看出它在不在运行 | `./status.sh` |
| 点菜单改设置（自动粘贴 / 恢复剪贴板 / 开机自启） | `defaults write`（见下） |
| 点菜单退出 | 面板里按 **`⌘Q`**，或 `./status.sh stop` |
| 缺权限时的图标提示点 | 面板顶部的橙色提示条 |

### 开回来

关掉之后菜单就点不到了，**包括那个开关本身** —— 所以只能用终端：

```bash
./status.sh icon on      # 显示图标（会重启应用）
./status.sh icon off     # 再隐藏
./status.sh icon         # 看当前设置
```

### 其他设置

```bash
defaults write com.local.paste autoPaste -bool false          # 关自动粘贴
defaults write com.local.paste restoreClipboard -bool false   # 不恢复剪贴板
./status.sh restart    # 改完重启生效
```

## 体积

`Paste.app` **784 KB**，打成的 dmg **963 KB**。

菜单栏工具没必要占用几 MB，所以做了三件事：

| 手段 | 效果 |
|---|---|
| 签名前 `strip -x` 去掉符号表 | 二进制 590 KB → 342 KB（`__LINKEDIT` 段占了一大半） |
| 图标不生成 1024×1024 | `.icns` 1014 KB → 431 KB。这一张只在 Quick Look / 大图标预览里用到，对菜单栏工具没意义；`Tools/make_icon.swift` 里的 `includeMaximumSize` 可以开回来 |
| dmg 用 `UDBZ`（bzip2）而非默认的 `UDZO`（zlib） | 1.03 MB → 0.96 MB |

> 试过 `ULMO`（lzfse）能压到 0.82 MB，但 `hdiutil attach` 挂不上
> （报「资源暂时不可用」）—— **压得再小、挂不上也没用**，所以没用它。

顺带一个观察：系统自带 App 的图标只有 **37–49 KB**（计算器 48.7 KB、便签 37.0 KB），
因为它们的画面更「平」，PNG 压得动；我们这个**平滑渐变是 PNG 的最坏情况**，
所以图标占了整个包的 55%。要再小就得改图标设计，不是工程问题了。

## 数据存在哪

```
~/Library/Application Support/com.local.paste/items/<uuid>.plist
```

**一条一个文件**，不是整个历史写一个文件——历史里可能有图片，几十 MB 每次复制都全量重写太浪费。
顺序不靠文件名，而是加载后按时间排序。

菜单里有「打开历史文件夹…」。删掉整个目录就等于清空历史。

## 验证状态

自动化验证过：

- 构建、`.app` 组装、ad-hoc 签名
- `Ctrl+V` 全局热键注册
- 文本 / 富文本 / 图片 / 多文件 四种类型的捕获
- **PNG + TIFF 同时存在时只保留 PNG**（实测 2095 B vs 323390 B）
- 去重、纯空白过滤、`ConcealedType` 跳过
- 条数上限 20、总量上限 50 MB 的淘汰与文件删除
- **面板弹出后前台 App 不变**（焦点不被抢走，这是整个设计的基石）
- 自动粘贴全流程：写入 → 收面板 → 发按键 → 延迟恢复原剪贴板
- 自身写入被精确跳过，不会把「粘贴 → 恢复」当成用户复制
- 搜索过滤（大小写不敏感、首尾空白、无命中、选中项越界）
- 搜索框聚焦与 delegate 接线（实测 `聚焦=true delegate=true`）
- 持久化：跨重启恢复、淘汰删文件、清空、损坏文件自愈
- 图片与多 item 写回剪贴板
- 开机自启：`sfltool dumpbtm` 里能看到已注册的项，
  `Disposition: [enabled, allowed, visible, notified]`，URL 指向 `/Applications/Paste.app/`
- 签名稳定性：改动源码重新编译后 CDHash 变了、designated requirement 一字不差
- 面板 显示/隐藏 循环不崩溃、失焦自动关闭

跑逻辑测试（**79 项断言**，不需要 XCTest）：

```bash
./test.sh
```

### 修过的真实崩溃与 bug

两个 AppKit 剪贴板 API 的坑，都在「有权限时才走到」的路径上：

1. 从 `pasteboardItems` 拿到的 `NSPasteboardItem` 绑定在原剪贴板上，
   直接 `writeObjects` 回去抛 `NSInvalidArgumentException` 并终止进程。
2. 就算新建 `NSPasteboardItem`，写出去一次后也被绑定，**第二次恢复照样崩溃**。

所以 `ClipboardSnapshot` 存的是**原始数据**，每次写入现场造新 item。
`test.sh` 里有对应的回归断言。

还有一个**已修的 bug**：「复制完立刻按 Ctrl+V，看不到刚复制的内容」。
根因是 0.3s 轮询赶不上用户的动作，日志里能直接看出顺序反了：

```
（修复前）面板已显示（历史 4 条）  →  捕获…历史 5 条      ← 打开时新内容还不在
（修复后）捕获…历史 6 条          →  面板已显示（历史 6 条）
```

`test.sh` 里有 `pollNow()` 的回归断言。

仍需你手动确认：**打字搜索的输入法体验**、面板外观、按键手感。

## 设计要点

几个不踩就会翻车的地方：

1. **剪贴板没有通知 API**，只能轮询 `NSPasteboard.changeCount`（当前 0.3s）。
   先比 `changeCount` 再读内容，否则大图会被反复复制。
   **而且光有定时器不够**：用户「复制 → 立刻按 Ctrl+V」的间隔常常短于 0.3s，
   面板会拿到一份不含刚复制内容的旧列表。所以两个时机必须主动同步刷一次
   （`ClipboardMonitor.pollNow()`）：**呼出面板之前**、**覆盖剪贴板之前**。
   后者还防了一个更隐蔽的丢失——粘贴时我们的写入会把那次复制盖掉，
   而 `changeCount` 又被记成自身写入，那条内容就再也进不了历史。
2. **`.nonactivatingPanel` 是整个设计的基石**。普通窗口一弹出就会激活我们的 App，
   目标 App 失焦，用户随后的 `Cmd+V` 就打到我们身上了。
3. **自动粘贴的顺序不能错**：写剪贴板 → **先收起面板** → 延迟 60ms → 发 `Cmd+V`。
4. **恢复剪贴板要再延迟 400ms**：有些 App 是异步读剪贴板的，恢复太快它会拿到旧值。
5. **手动模式下不能恢复剪贴板**：那时选中内容必须留着等用户按 `Cmd+V`。
6. **自己写剪贴板要精确标记**：用具体的 `changeCount` 记账，而不是「一段时间内全部忽略」——
   时间窗口会误吞用户在这个窗口里真正复制的内容。
7. **搜索框用 AppKit 的 `NSSearchField` 而不是 SwiftUI 的 `TextField`**：
   需要能确定地 `makeFirstResponder`（非激活面板里 SwiftUI 焦点不可靠），
   而且原生输入框中文输入法才正常。
8. **本地键盘监听只拦特殊键**（↑↓ Enter Esc 和无限定符的数字），
   其余交给搜索框，否则输入法会被打断。
9. **多显示器定位**要按鼠标所在的 `NSScreen` 算坐标。
10. **Carbon `RegisterEventHotKey` 不需要任何权限**，只有合成按键才需要「辅助功能」。

## 项目结构

```
Package.swift
setup-signing-cert.sh         自签名代码签名证书（创建 / 删除）
build.sh                      构建 + 组装 .app + 签名（可 install 到 /Applications）
status.sh                     状态检查 / start / stop / restart / log / icon
test.sh                       纯逻辑测试（79 项断言）
Resources/Info.plist          LSUIElement=true（只驻留菜单栏，不进 Dock）
Sources/Paste/
  main.swift                  入口，setActivationPolicy(.accessory)
  AppDelegate.swift           装配模块、菜单栏、调试钩子
  ClipboardMonitor.swift      轮询 changeCount、过滤受保护内容、跳过自身写入
  ClipStore.swift             历史列表：去重 / 上限 / 搜索过滤 / 选中项
  ClipItem.swift              条目模型：类型检测、预览、搜索文本、缩略图
  ClipPersistence.swift       一条一个 plist 的磁盘存储
  ClipboardSnapshot.swift     剪贴板原始数据的快照与写回
  HotKeyManager.swift         Carbon 全局热键（零权限）
  PastePanel.swift            非激活 NSPanel（不抢焦点）
  PanelController.swift       显示/隐藏、定位、键盘、粘贴流程
  Paster.swift                合成 Cmd+V
  SearchFieldView.swift       包装 NSSearchField
  Accessibility.swift         辅助功能权限检查与引导
  LoginItem.swift             开机自启（SMAppService）
  Preferences.swift           用户偏好（UserDefaults）
  ClipListView.swift          SwiftUI 列表 UI
  Log.swift                   日志 + 调试开关
Tools/
  LogicTest/main.swift        全部逻辑断言
  make_icon.swift             程序化生成 App 图标（可出变体对比图和小尺寸检查图）
  pasteboard_probe.swift      往剪贴板塞 文本/图片/多文件/伪装密码 内容
```

## 图标

图标是**用代码画的**（`Tools/make_icon.swift`），不是一张位图：

- 超椭圆（squircle）底，指数 5，模拟 macOS 的连续圆角
- 紫→蓝对角渐变 + 顶部淡淡的高光
- 居中的白色 V（Ctrl+V 的 V），圆头笔画

```bash
swift Tools/make_icon.swift            # 生成 Resources/AppIcon.icns
swift Tools/make_icon.swift --sheet    # 三种变体并排，用来挑设计
swift Tools/make_icon.swift --small    # 16/32/64px 最近邻放大，检查小尺寸可辨性
```

每个尺寸都从矢量重画（不是从 1024 缩下来的），小尺寸不会糊。
实测 16px 下 V 依然清晰可辨。

改了图标记得重新 `./build.sh release install`。
如果 Finder 里还是旧图标，是系统的图标缓存，用
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Paste.app`
刷一下注册即可。

> 菜单栏图标目前是 SF Symbol `doc.on.clipboard`，没有跟着换成 V。
> 菜单栏图标需要是单色 template image 才能正确适配浅色/深色菜单栏，
> 直接塞彩色图标会很难看。


## 调试

**看日志。** 直接跑二进制能看到 stderr：

```bash
./Paste.app/Contents/MacOS/Paste 2>&1 | tee /tmp/paste.log
```

用 `open` 启动时 stderr 看不见，改用文件：

```bash
launchctl setenv PASTE_LOG_FILE /tmp/paste.log
open Paste.app
launchctl unsetenv PASTE_LOG_FILE
```

**不敲快捷键也能触发**：

```bash
kill -USR1 $(pgrep -x Paste)   # 等同按一次 Ctrl+V
kill -USR2 $(pgrep -x Paste)   # 等同选中最后一条并粘贴
kill -WINCH $(pgrep -x Paste)  # 选中项下移一格，并前后各截一张面板图
```

**把面板的渲染结果存成 PNG**（排查「高亮位置不对」这类问题时最有用）：

```bash
kill -WINCH $(pgrep -x Paste)
open /tmp/panel-immediate.png   # 状态变更后立刻截的
open /tmp/panel-settled.png     # 400ms 后截的
```

> 应用给自己的窗口截图**不需要「屏幕录制」权限**，这是唯一能直接看到
> 「面板到底画成了什么」的办法。两张图若字节完全相同，说明视图根本没重绘。

**打印面板实际显示的完整列表**——每条的下标和内容：

```bash
launchctl setenv PASTE_DEBUG_LOG_CONTENT 1
open /Applications/Paste.app
launchctl unsetenv PASTE_DEBUG_LOG_CONTENT
```
此时面板右下角会多出一行红色小字 `sel=N id=XXXX`，是**视图自己**读到的选中状态。
截图里这个数字和日志里的 `当前 selectedIndex` 一比，就能区分
「视图拿到的是旧状态」还是「高亮逻辑本身错了」。

**按回车那一刻自动截面板**——用来核对「高亮的是哪条」和「提交的是哪条」：

```bash
launchctl setenv PASTE_DEBUG_SNAPSHOT 1
open /Applications/Paste.app
launchctl unsetenv PASTE_DEBUG_SNAPSHOT
# 结果在 /tmp/paste-panel.png
```

**呼出面板时直接设好选中项**（会延迟 0.8 秒再设，等第一次渲染完成）：

```bash
launchctl setenv PASTE_DEBUG_SELECT 4
open /Applications/Paste.app
launchctl unsetenv PASTE_DEBUG_SELECT
```

**干跑模式**——走完自动粘贴的全部流程但不真的发按键，不污染当前前台 App：

```bash
PASTE_DEBUG_DRY_RUN=1 ./Paste.app/Contents/MacOS/Paste
```

**预置搜索词**——用来验证过滤：

```bash
PASTE_DEBUG_QUERY=git ./Paste.app/Contents/MacOS/Paste
```

**往剪贴板塞测试内容**：

```bash
swift Tools/pasteboard_probe.swift image 400 200
swift Tools/pasteboard_probe.swift files /tmp/a.txt /tmp/b.txt
swift Tools/pasteboard_probe.swift concealed "SECRET"   # 应该被跳过
```

## 推荐：装到 /Applications

```bash
./build.sh release install
open /Applications/Paste.app
```

**开机自启需要 App 在 `/Applications` 里。** 放在项目目录里 `SMAppService` 会报
`notFound`，菜单里会提示「挪到「应用程序」里再试」。

装好之后就从 `/Applications/Paste.app` 用，项目目录里的那份只是构建产物。
以后改完代码重新 `./build.sh release install` 即可。

> ⚠️ 移动或删除 `/Applications/Paste.app` 会让开机自启项失效。
> 想关掉就在菜单里取消勾选「开机自启」。

## 已知限制

- 恢复剪贴板对「源 App 惰性提供的数据」（promised data）不可靠，
  源 App 退出后可能恢复不回去。
- 只保留白名单里的 6 种类型，其它类型（如自定义私有格式）不保存。
- 没有做加密，历史以明文 plist 存在磁盘上。
- 开机自启注册的是启动时的那个 bundle 路径，所以务必先用 `install` 装到
  `/Applications` 再开启。

### 一个容易忽略的权限细节

从终端启动的进程会**继承父进程的 TCC 授权**，所以
`./Paste.app/Contents/MacOS/Paste` 可能显示「已授权」，
而 `open Paste.app` 显示「未授权」——因为后者的权限归属是它自己。

**以 `open Paste.app` 的状态为准。**
