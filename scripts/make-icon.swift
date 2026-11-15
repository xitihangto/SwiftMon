// 生成 AppIcon.icns 的源图：深色圆角底 + 三色曲线 + 仪表弧。
// 用法：swift scripts/make-icon.swift <输出目录>

import AppKit
import CoreGraphics
import Foundation

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/swiftmon-icon"
let size = 1024

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.06
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = size * 0.22
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 背景：深灰到近黑
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1),
                                       CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0),
                           options: [])

    // 三条曲线：绿 / 橙 / 紫，模拟 E-P-GPU 三条 sparkline
    let series: [(CGColor, CGFloat, CGFloat)] = [
        (CGColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1), 0.62, 0.13),
        (CGColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 1), 0.50, 0.11),
        (CGColor(red: 0.72, green: 0.45, blue: 1.00, alpha: 1), 0.34, 0.09),
    ]
    let left = body.minX + size * 0.13
    let width = body.width - size * 0.26
    for (index, item) in series.enumerated() {
        let (color, baseY, amplitude) = item
        let path2 = CGMutablePath()
        let points = 24
        for i in 0...points {
            let t = CGFloat(i) / CGFloat(points)
            let x = left + t * width
            let wave = sin(t * .pi * 3.2 + CGFloat(index) * 1.1) * 0.5 + sin(t * .pi * 7.1) * 0.28
            let y = body.minY + body.height * baseY + wave * body.height * amplitude
            if i == 0 { path2.move(to: CGPoint(x: x, y: y)) } else { path2.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.setLineWidth(size * 0.035)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color)
        ctx.addPath(path2)
        ctx.strokePath()
    }

    // 顶部仪表弧
    ctx.setLineWidth(size * 0.045)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
    ctx.addArc(center: CGPoint(x: body.midX, y: body.maxY - size * 0.20),
               radius: size * 0.18,
               startAngle: .pi * 1.15,
               endAngle: .pi * 1.85,
               clockwise: false)
    ctx.strokePath()

    // 高光描边
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setLineWidth(size * 0.008)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.strokePath()

    image.unlockFocus()
    return image
}

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let image = drawIcon(size: CGFloat(size))
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    exit(1)
}
let pngPath = "\(outputDir)/icon_1024.png"
try png.write(to: URL(fileURLWithPath: pngPath))
print(pngPath)
