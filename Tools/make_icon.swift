// 生成 Paste 的 App 图标（.icns）。
//
//   swift Tools/make_icon.swift            # 生成正式图标
//   swift Tools/make_icon.swift --sheet    # 只出一张变体对比图，用来挑设计
//
// 设计：圆角超椭圆底 + 蓝紫渐变 + 居中白色 V（Ctrl+V 的 V）。
// 用代码画而不是塞一张位图，是为了可复现、可微调，而且每个尺寸都从矢量重画，
// 小尺寸不会糊。
//
import AppKit
import Foundation

// ---------------------------------------------------------------- 设计参数

let canvas: CGFloat = 1024
/// 圆角矩形相对画布的内缩（macOS 图标惯例是 824/1024）
let bodyInset: CGFloat = 100
/// 超椭圆指数。越大约接近正方形，Apple 的圆角大致相当于 5
let cornerExponent: CGFloat = 5

let gradientTop = NSColor(srgbRed: 0.451, green: 0.361, blue: 1.000, alpha: 1)     // 紫
let gradientBottom = NSColor(srgbRed: 0.204, green: 0.510, blue: 0.980, alpha: 1)  // 蓝

enum IconVariant: String, CaseIterable {
    /// 干净的白色 V
    case clean
    /// V 后面有两层淡淡的回声，暗示「历史」
    case layered
    /// 更粗、几何感更强
    case bold
}

/// 正式使用的变体
let chosenVariant: IconVariant = .clean

// V 的形状，坐标是相对圆角矩形内部的比例（原点左下，y 向上）
struct VGeometry {
    var leftTop: NSPoint
    var apex: NSPoint
    var rightTop: NSPoint
    var strokeRatio: CGFloat
}

func geometry(for variant: IconVariant) -> VGeometry {
    switch variant {
    case .clean:
        // 留足四周留白，笔画略细，显秀气
        return VGeometry(
            leftTop: NSPoint(x: 0.230, y: 0.735),
            apex: NSPoint(x: 0.500, y: 0.265),
            rightTop: NSPoint(x: 0.770, y: 0.735),
            strokeRatio: 0.140
        )
    case .layered:
        return VGeometry(
            leftTop: NSPoint(x: 0.230, y: 0.735),
            apex: NSPoint(x: 0.500, y: 0.265),
            rightTop: NSPoint(x: 0.770, y: 0.735),
            strokeRatio: 0.140
        )
    case .bold:
        return VGeometry(
            leftTop: NSPoint(x: 0.215, y: 0.745),
            apex: NSPoint(x: 0.500, y: 0.255),
            rightTop: NSPoint(x: 0.785, y: 0.745),
            strokeRatio: 0.168
        )
    }
}

// ---------------------------------------------------------------- 绘制

/// 超椭圆（squircle）路径，用来模拟 macOS 的连续圆角
func squirclePath(in rect: NSRect, exponent: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let cx = rect.midX
    let cy = rect.midY
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 1440

    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / exponent)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / exponent)
        let point = NSPoint(x: x, y: y)
        if i == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func drawIcon(size: CGFloat, variant: IconVariant) -> NSBitmapImageRep {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("无法创建 \(pixels)px 位图")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true

    let scale = size / canvas   // 所有设计尺寸都按 1024 画布定义
    let bodyRect = NSRect(
        x: bodyInset * scale,
        y: bodyInset * scale,
        width: (canvas - bodyInset * 2) * scale,
        height: (canvas - bodyInset * 2) * scale
    )
    let bodyPath = squirclePath(in: bodyRect, exponent: cornerExponent)

    // 1) 底色：带投影的渐变圆角方块
    NSGraphicsContext.saveGraphicsState()
    let bodyShadow = NSShadow()
    bodyShadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    bodyShadow.shadowBlurRadius = 26 * scale
    bodyShadow.shadowOffset = NSSize(width: 0, height: -14 * scale)
    bodyShadow.set()
    NSGradient(starting: gradientTop, ending: gradientBottom)?
        .draw(in: bodyPath, angle: -70)
    NSGraphicsContext.restoreGraphicsState()

    // 2) 顶部一层很淡的高光，让它看起来像有厚度
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(
        starting: NSColor.white.withAlphaComponent(0.22),
        ending: NSColor.white.withAlphaComponent(0.0)
    )?.draw(
        in: NSRect(
            x: bodyRect.minX,
            y: bodyRect.midY,
            width: bodyRect.width,
            height: bodyRect.height / 2
        ),
        angle: -90
    )
    NSGraphicsContext.restoreGraphicsState()

    let geo = geometry(for: variant)

    func point(_ ratio: NSPoint, dx: CGFloat = 0, dy: CGFloat = 0) -> NSPoint {
        NSPoint(
            x: bodyRect.minX + bodyRect.width * (ratio.x + dx),
            y: bodyRect.minY + bodyRect.height * (ratio.y + dy)
        )
    }

    func makeVPath(dx: CGFloat = 0, dy: CGFloat = 0) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = bodyRect.width * geo.strokeRatio
        path.lineCapStyle = variant == .bold ? .butt : .round
        path.lineJoinStyle = variant == .bold ? .miter : .round
        path.move(to: point(geo.leftTop, dx: dx, dy: dy))
        path.line(to: point(geo.apex, dx: dx, dy: dy))
        path.line(to: point(geo.rightTop, dx: dx, dy: dy))
        return path
    }

    // 3) 层次变体：后面两层淡淡的回声，暗示「历史里的一叠」
    if variant == .layered {
        NSGraphicsContext.saveGraphicsState()
        bodyPath.addClip()
        for (index, offset) in [CGFloat(0.052), CGFloat(0.026)].enumerated() {
            let echo = makeVPath(dy: offset)
            NSColor.white.withAlphaComponent(index == 0 ? 0.14 : 0.22).setStroke()
            echo.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // 4) 主体的 V
    let vPath = makeVPath()
    NSGraphicsContext.saveGraphicsState()
    let vShadow = NSShadow()
    vShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    vShadow.shadowBlurRadius = 14 * scale
    vShadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
    vShadow.set()
    NSColor.white.setStroke()
    vPath.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("无法编码 PNG: \(url.lastPathComponent)")
    }
    do {
        try data.write(to: url)
    } catch {
        fatalError("写入失败 \(url.path): \(error)")
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sheetMode = CommandLine.arguments.contains("--sheet")
let smallMode = CommandLine.arguments.contains("--small")

// ---------------------------------------------------------------- 小尺寸检查
//
// 用最近邻放大，能看清楚每个像素怎么落的 —— 判断 16px 下还认不认得出。

if smallMode {
    let sizes: [CGFloat] = [16, 32, 64]
    let magnify: CGFloat = 8
    let gap: CGFloat = 30
    let labelHeight: CGFloat = 44
    let tileWidth = 64 * magnify
    let width = tileWidth * CGFloat(sizes.count) + gap * CGFloat(sizes.count + 1)
    let height = tileWidth + gap * 2 + labelHeight

    guard let sheetRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width),
        pixelsHigh: Int(height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let sheetContext = NSGraphicsContext(bitmapImageRep: sheetRep) else {
        fatalError("无法创建小尺寸检查图")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = sheetContext
    NSColor(white: 0.45, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    for (index, size) in sizes.enumerated() {
        let rep = drawIcon(size: size, variant: chosenVariant)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)

        let x = gap + (tileWidth + gap) * CGFloat(index)
        let drawn = size * magnify
        let y = gap + labelHeight + (tileWidth - drawn)

        sheetContext.imageInterpolation = .none
        image.draw(in: NSRect(x: x, y: y, width: drawn, height: drawn))

        NSAttributedString(
            string: "\(Int(size))px  ×\(Int(magnify))",
            attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        ).draw(at: NSPoint(x: x + 4, y: gap + 10))
    }

    NSGraphicsContext.restoreGraphicsState()
    writePNG(sheetRep, to: root.appendingPathComponent("icon-small.png"))
    print("✓ 小尺寸检查图: icon-small.png")
    exit(0)
}

// ---------------------------------------------------------------- 对比图模式

if sheetMode {
    let tile: CGFloat = 340
    let gap: CGFloat = 24
    let variants = IconVariant.allCases
    let width = tile * CGFloat(variants.count) + gap * CGFloat(variants.count + 1)
    let height = tile + gap * 2 + 40

    guard let sheetRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width),
        pixelsHigh: Int(height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let sheetContext = NSGraphicsContext(bitmapImageRep: sheetRep) else {
        fatalError("无法创建对比图")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = sheetContext
    NSColor(white: 0.5, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    for (index, variant) in variants.enumerated() {
        let rep = drawIcon(size: tile, variant: variant)
        let image = NSImage(size: NSSize(width: tile, height: tile))
        image.addRepresentation(rep)

        let x = gap + (tile + gap) * CGFloat(index)
        image.draw(in: NSRect(x: x, y: gap + 40, width: tile, height: tile))

        let label = NSAttributedString(
            string: variant.rawValue,
            attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        )
        label.draw(at: NSPoint(x: x + 8, y: gap + 6))
    }

    NSGraphicsContext.restoreGraphicsState()
    writePNG(sheetRep, to: root.appendingPathComponent("icon-variants.png"))
    print("✓ 对比图: icon-variants.png")
    exit(0)
}

// ---------------------------------------------------------------- 正式输出

let iconset = root.appendingPathComponent("Paste.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// 是否生成 1024×1024（icon_512x512@2x）。
///
/// **默认不生成**：一张 1024 的平滑渐变 PNG 就要 583 KB，
/// 比其余 9 个尺寸加起来还多；而这张图只在 Quick Look / 大图标预览里用到，
/// 对菜单栏工具来说基本没用。去掉之后 .icns 从 1014 KB 降到 431 KB。
let includeMaximumSize = false

// iconutil 要求的固定文件名与尺寸
var variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
]
if includeMaximumSize {
    variants.append(("icon_512x512@2x.png", 1024))
}

print("==> 变体 \(chosenVariant.rawValue)，绘制 \(variants.count) 个尺寸")
for variant in variants {
    writePNG(drawIcon(size: variant.pixels, variant: chosenVariant),
             to: iconset.appendingPathComponent(variant.name))
}
print("    完成")

// 顺便导出一张预览图，方便直接看效果
writePNG(drawIcon(size: 512, variant: chosenVariant),
         to: root.appendingPathComponent("icon-preview.png"))

print("==> iconutil 打包 .icns")
let output = root.appendingPathComponent("Resources/AppIcon.icns")
try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    print("✗ iconutil 失败")
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("✓ 完成: Resources/AppIcon.icns")
