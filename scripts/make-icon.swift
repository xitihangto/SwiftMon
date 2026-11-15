// 生成 AppIcon.icns 的源图。
// 图形：深色圆角底 + 系统符号 waveform.path.ecg 本体（与菜单栏图标同一个字形，等比放大），
// 字形用绿 → 橙 → 紫的水平渐变着色。
// 用法：swift scripts/make-icon.swift <输出目录>

import AppKit
import CoreGraphics
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/swiftmon-icon"

/// 显式 sRGB 颜色：CGColor(red:green:blue:) 走的是 Generic RGB，
/// 画进 sRGB 上下文会被转换提亮（0.731 → 0.80 这种偏差），必须指定色彩空间。
private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a])!
}

let size: CGFloat = 1024

/// 菜单栏用的符号名。改这里图标跟着变。
let symbolName = "waveform.path.ecg"

/// 把符号渲染成纯白字形位图（只关心 alpha）。
private func renderSymbolBitmap(symbolName: String, side: Int, weight: NSFont.Weight) -> CGImage? {
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
    let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.95, weight: weight)
    guard let configured = symbol.withSymbolConfiguration(configuration) else { return nil }
    configured.isTemplate = true

    guard let ctx = CGContext(data: nil,
                              width: side,
                              height: side,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side))
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let glyphSize = configured.size
    let scale = min(canvas.width / max(glyphSize.width, 1),
                    canvas.height / max(glyphSize.height, 1)) * 0.98
    let drawSize = NSSize(width: glyphSize.width * scale, height: glyphSize.height * scale)
    let origin = NSPoint(x: (canvas.width - drawSize.width) / 2,
                         y: (canvas.height - drawSize.height) / 2)
    configured.draw(in: NSRect(origin: origin, size: drawSize))
    NSGraphicsContext.current = previous
    return ctx.makeImage()
}

/// 扫描 alpha，得到真实墨迹边界（SF Symbol 自带的可观内边距就在这里被剥掉）。
private func inkBounds(of image: CGImage, threshold: UInt8 = 8) -> CGRect? {
    let width = image.width
    let height = image.height
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
    let bytesPerRow = image.bytesPerRow
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        let row = bytes + y * bytesPerRow
        for x in 0..<width {
            let alpha = row[x * 4 + 3]
            if alpha > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// 字形裁到墨迹后灌入渐变。
private func gradientGlyph(symbolName: String, weight: NSFont.Weight) -> CGImage? {
    let side = 2048
    guard let raw = renderSymbolBitmap(symbolName: symbolName, side: side, weight: weight),
          let ink = inkBounds(of: raw),
          let cropped = raw.cropping(to: ink) else { return nil }
    if ProcessInfo.processInfo.environment["ICON_TRACE"] == "1" {
        FileHandle.standardError.write("raw=\(raw.width)x\(raw.height) ink=\(ink) cropped=\(cropped.width)x\(cropped.height)\n".data(using: .utf8)!)
        for (name, img) in [("raw", raw), ("cropped", cropped)] {
            let rep = NSBitmapImageRep(cgImage: img)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/glyph_\(name).png"))
            }
        }
    }

    let width = cropped.width
    let height = cropped.height
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil,
                              width: width,
                              height: height,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

    let spectrum = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            srgb(0.30, 0.86, 0.45, 1),
            srgb(1.00, 0.62, 0.20, 1),
            // 最右端：20% 原紫(#B873FF) + 80% 界面里 "GPU" 字样色(#BB57C8) 的混合
            srgb(0.731, 0.365, 0.828, 1),
        ] as CFArray,
        locations: [0.0, 0.45, 0.85]
    )!
    ctx.setBlendMode(.sourceIn)
    ctx.drawLinearGradient(spectrum,
                           start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: CGFloat(width), y: 0),
                           options: [])
    ctx.setBlendMode(.normal)
    let colored = ctx.makeImage()
    if ProcessInfo.processInfo.environment["ICON_TRACE"] == "1", let colored {
        let rep = NSBitmapImageRep(cgImage: colored)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/glyph_colored.png"))
        }
    }
    return colored
}

/// 圆角底 + 居中的心跳字形。显式用 sRGB 上下文渲染，
/// 否则 lockFocus 会套上显示器（P3）色彩空间，颜色数值会被错误解释而偏亮/过饱和。
func drawIcon(size: CGFloat) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let side = Int(size)
    guard let ctx = CGContext(data: nil,
                              width: side,
                              height: side,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.055
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = size * 0.225
    let outline = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 背景：深灰 → 近黑
    ctx.saveGState()
    ctx.addPath(outline)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            srgb(0.17, 0.19, 0.23, 1),
            srgb(0.07, 0.08, 0.10, 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(background,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
    ctx.restoreGState()

    // 字形
    if let glyph = gradientGlyph(symbolName: symbolName, weight: .semibold) {
        let targetWidth = body.width * 0.97
        let aspect = CGFloat(glyph.width) / CGFloat(max(glyph.height, 1))
        let targetHeight = targetWidth / aspect
        let maxHeight = body.height * 0.62
        let scale = min(1, maxHeight / max(targetHeight, 1))
        let drawWidth = targetWidth * scale
        let drawHeight = targetHeight * scale
        let target = CGRect(x: body.midX - drawWidth / 2,
                            y: body.midY - drawHeight / 2,
                            width: drawWidth,
                            height: drawHeight)
        ctx.interpolationQuality = .high
        ctx.draw(glyph, in: target)
        if ProcessInfo.processInfo.environment["ICON_TRACE"] == "1" {
            let info = String(format: "字形占图标宽 %.1f%% / 高 %.1f%%（左右边距各 %.1f%%，上下各 %.1f%%），墨迹宽高比 %.2f:1",
                              drawWidth / size * 100, drawHeight / size * 100,
                              target.minX / size * 100, target.minY / size * 100, aspect)
            FileHandle.standardError.write((info + "\n").data(using: .utf8)!)
        }
    }

    // 外框高光
    ctx.addPath(outline)
    ctx.setLineWidth(size * 0.007)
    ctx.setStrokeColor(srgb(1, 1, 1, 0.10))
    ctx.strokePath()

    return ctx.makeImage()
}

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

guard let image = drawIcon(size: size) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}
let pngPath = "\(outputDir)/icon_1024.png"
let url = URL(fileURLWithPath: pngPath) as CFURL
guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else {
    FileHandle.standardError.write("cannot create png destination\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write("png write failed\n".data(using: .utf8)!)
    exit(1)
}
print(pngPath)
