// 往剪贴板里塞各种类型的内容，用来手工验证捕获逻辑。
//
//   swift Tools/pasteboard_probe.swift text "hello"
//   swift Tools/pasteboard_probe.swift image 400 200
//   swift Tools/pasteboard_probe.swift files /tmp/a.txt /tmp/b.txt
//   swift Tools/pasteboard_probe.swift concealed "SUPER-SECRET"
//
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法: pasteboard_probe <text|image|files|concealed> [参数…]")
    exit(1)
}

let mode = args[1]
let pasteboard = NSPasteboard.general
pasteboard.clearContents()

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
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSColor.systemOrange.setFill()
    NSRect(x: 0, y: 0, width: width / 3, height: height / 3).fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("无法编码 PNG")
    }
    return png
}

switch mode {
case "text":
    pasteboard.setString(args.count > 2 ? args[2] : "hello", forType: .string)

case "image":
    let width = args.count > 2 ? Int(args[2]) ?? 400 : 400
    let height = args.count > 3 ? Int(args[3]) ?? 200 : 200
    let png = makePNG(width: width, height: height)
    pasteboard.setData(png, forType: .png)
    // 模拟浏览器/预览：同时提供 TIFF。App 应该把 TIFF 丢掉只留 PNG。
    if let image = NSImage(data: png), let tiff = image.tiffRepresentation {
        pasteboard.setData(tiff, forType: .tiff)
        print("PNG \(png.count) 字节 + TIFF \(tiff.count) 字节（应只保留 PNG）")
    }

case "files":
    let items = args.dropFirst(2).map { path -> NSPasteboardItem in
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        return item
    }
    guard !items.isEmpty else {
        print("至少要给一个文件路径")
        exit(1)
    }
    pasteboard.writeObjects(items)

case "concealed":
    let item = NSPasteboardItem()
    item.setString(args.count > 2 ? args[2] : "SUPER-SECRET", forType: .string)
    item.setString("1", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    pasteboard.writeObjects([item])

default:
    print("未知模式：\(mode)")
    exit(1)
}

let types = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "无"
print("已写入 \(mode)，changeCount=\(pasteboard.changeCount)，types=[\(types)]")
