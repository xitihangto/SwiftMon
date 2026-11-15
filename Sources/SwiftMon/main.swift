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

// 离屏渲染「关于」窗口，用于自检 UI（不需要屏幕录制权限）
if let aboutIndex = args.firstIndex(of: "--snapshot-about") {
    let path = args.count > aboutIndex + 1 ? args[aboutIndex + 1] : "/tmp/swiftmon-about.png"
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let rendered: NSImage? = MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: AboutView(onClose: {}))
        renderer.scale = 2
        return renderer.nsImage
    }
    guard let image = rendered,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("about render failed\n".data(using: .utf8)!)
        exit(3)
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("about snapshot written: \(path) (\(png.count) bytes)")
    exit(0)
}

if let dumpIndex = args.firstIndex(of: "--dump") {
    let count = args.count > dumpIndex + 1 ? Int(args[dumpIndex + 1]) ?? 3 : 3
    let interval = args.count > dumpIndex + 2 ? Double(args[dumpIndex + 2]) ?? 1.0 : 1.0
    exit(runDump(count: count, interval: interval))
}

// MARK: - GUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let monitor = Monitor()
    private var window: NSWindow?
    private var aboutWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var contextMenu: NSMenu?

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 永远以菜单栏（accessory）形态运行：没有 Dock 图标，也没有顶部菜单栏
        NSApp.setActivationPolicy(.accessory)

        buildWindow()
        buildStatusItem()
        monitor.start(interval: 1.0)
        showWindow()
    }

    /// 关掉窗口不退出：应用常驻菜单栏。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: 主窗口

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwiftMon"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
        window.contentView = NSHostingView(rootView: RootView(monitor: monitor))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
    }

    /// 左键只做一件事：把窗口拿到最前面。已经是可见状态也照样前置。
    private func showWindow() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: 菜单栏图标：左键显示窗口，右键出菜单

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform.path.ecg",
                                accessibilityDescription: "SwiftMon")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SwiftMon — 左键显示窗口，右键显示菜单"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let menu = NSMenu()
        let aboutItem = NSMenuItem(title: "关于 SwiftMon", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 SwiftMon", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        contextMenu = menu
        if ProcessInfo.processInfo.environment["SWIFTMON_TRACE"] == "1" {
            let titles = menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
            let message = "statusItem: visible=\(item.isVisible) icon=\(item.button?.image != nil) menu=\(titles)\n"
            FileHandle.standardError.write(message.data(using: .utf8)!)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            // 右键：在图标下方弹出菜单
            guard let menu = contextMenu else { return }
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: sender.bounds.height + 4),
                       in: sender)
        } else {
            showWindow()
        }
    }

    // MARK: 关于 / 退出

    @objc private func showAbout() {
        if let aboutWindow, aboutWindow.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }
        let about = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        about.title = "关于 SwiftMon"
        about.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
        about.contentView = NSHostingView(rootView: AboutView { [weak self] in
            self?.aboutWindow?.close()
        })
        about.isReleasedWhenClosed = false
        about.center()
        aboutWindow = about
        NSApp.activate(ignoringOtherApps: true)
        about.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)   // 不做二次确认
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
