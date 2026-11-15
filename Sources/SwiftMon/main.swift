// 入口：`--dump N [interval]` 走文本模式（便于交叉核对），否则起窗口。

import Foundation
import AppKit
import SwiftUI

setvbuf(stdout, nil, _IONBF, 0)   // 崩溃时不丢日志
let trace = ProcessInfo.processInfo.environment["SWIFTMON_TRACE"] == "1"
func tlog(_ message: String) { if trace { FileHandle.standardError.write("[trace] \(message)\n".data(using: .utf8)!) } }
let args = CommandLine.arguments

func runDump(count: Int, interval: Double) -> Int32 {
    tlog("creating monitor")
    let monitor = Monitor()
    tlog("monitor ready: \(monitor.diagnostic)")
    print(monitor.diagnostic)
    guard monitor.diagnostic.hasPrefix("IOReport") else { return 2 }

    // 第一帧只是建立基线，丢弃
    _ = monitor.tick()
    Thread.sleep(forTimeInterval: interval)
    for index in 0..<count {
        tlog("tick \(index)")
        let snap = monitor.tick()
        tlog("tick \(index) done")
        print(monitor.textLine(snap, index: index))
        if index < count - 1 { Thread.sleep(forTimeInterval: interval) }
    }
    return 0
}

// 离屏渲染一张界面图：不依赖屏幕录制权限，用于自检 UI 是否真画出来
if let snapshotIndex = args.firstIndex(of: "--snapshot") {
    let path = args.count > snapshotIndex + 1 ? args[snapshotIndex + 1] : "/tmp/swiftmon.png"
    let monitor = Monitor()
    print(monitor.diagnostic)
    for i in 0..<40 {
        _ = monitor.tick()
        if i < 39 { Thread.sleep(forTimeInterval: 0.05) }
    }
    let rendered: NSImage? = MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: RootView(monitor: monitor).frame(width: 940, height: 500))
        renderer.scale = 2
        return renderer.nsImage
    }
    guard let image = rendered,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
        exit(3)
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("snapshot written: \(path) (\(png.count) bytes)")
    exit(0)
}

if let dumpIndex = args.firstIndex(of: "--dump") {
    let count = args.count > dumpIndex + 1 ? Int(args[dumpIndex + 1]) ?? 3 : 3
    let interval = args.count > dumpIndex + 2 ? Double(args[dumpIndex + 2]) ?? 1.0 : 1.0
    exit(runDump(count: count, interval: interval))
}

// MARK: - GUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let monitor = Monitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = RootView(monitor: monitor)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwiftMon"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        monitor.start(interval: 1.0)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
