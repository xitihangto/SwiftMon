// IOReport 私有框架绑定：按 group 订阅 → 采样 → 差分，读取 CPU/GPU 驻留与能耗计数器。
// 说明：手工过滤通道数组存在 CF 所有权陷阱（数组回调不 retain 通道对象，
// 样本调用时会崩），因此这里按 group/subgroup 直接取通道字典，逐组订阅。

import Foundation
import CoreFoundation

// MARK: - FFI

@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(
    _ group: CFString,
    _ subGroup: CFString?,
    _ a: UInt64,
    _ b: UInt64
) -> CFDictionary?

@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(
    _ a: UnsafeMutableRawPointer?,
    _ b: CFMutableDictionary,
    _ c: UnsafeMutablePointer<CFMutableDictionary?>,
    _ d: UInt64,
    _ e: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?

@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(
    _ sub: UnsafeMutableRawPointer,
    _ channels: CFMutableDictionary,
    _ options: UnsafeMutableRawPointer?
) -> CFDictionary?

@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(
    _ prev: CFDictionary,
    _ cur: CFDictionary,
    _ options: UnsafeMutableRawPointer?
) -> CFDictionary?

// 注意：通道对象由 IOReport 内部持有，若用 CFDictionary 桥接，Swift 的 ARC
// retain/release 会造成过度释放（多轮采样后崩在 objc_retain）。
// 因此这里一律用 UnsafeRawPointer 传入、Unmanaged 返回，全程不让 ARC 介入。
@_silgen_name("IOReportChannelGetGroup")
private func IOReportChannelGetGroup(_ c: UnsafeRawPointer) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetSubGroup")
private func IOReportChannelGetSubGroup(_ c: UnsafeRawPointer) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ c: UnsafeRawPointer) -> Unmanaged<CFString>?

@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ c: UnsafeRawPointer) -> Unmanaged<CFString>?

@_silgen_name("IOReportStateGetCount")
private func IOReportStateGetCount(_ c: UnsafeRawPointer) -> Int32

@_silgen_name("IOReportStateGetNameForIndex")
private func IOReportStateGetNameForIndex(_ c: UnsafeRawPointer, _ i: Int32) -> Unmanaged<CFString>?

@_silgen_name("IOReportStateGetResidency")
private func IOReportStateGetResidency(_ c: UnsafeRawPointer, _ i: Int32) -> Int64

@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ c: UnsafeRawPointer, _ i: Int32) -> Int64

// MARK: - 采样结果

/// 一个 IOReport 通道的一次差分读数。
struct RawChannel {
    let group: String
    let subGroup: String
    let name: String
    let unit: String
    /// 简单计数器（能耗）的值
    let value: Int64
    /// 状态驻留（利用率/频率）：(状态名, 驻留 tick)
    let residencies: [(String, Int64)]
}

// MARK: - 采样器

final class IOReportSampler {

    /// 单个通道组的订阅
    private enum ChannelKind { case state, simple }

    private final class GroupSubscription {
        let name: String
        let kind: ChannelKind
        let subscription: UnsafeMutableRawPointer
        let channels: CFMutableDictionary
        var previous: CFDictionary?

        init?(name: String, group: String, subGroup: String?, kind: ChannelKind) {
            guard let raw = IOReportCopyChannelsInGroup(group as CFString, subGroup as CFString?, 0, 0),
                  let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, raw) else { return nil }
            var subscribed: CFMutableDictionary?
            guard let sub = IOReportCreateSubscription(nil, mutable, &subscribed, 0, nil),
                  let subscribed else { return nil }
            self.name = name
            self.kind = kind
            self.subscription = sub
            self.channels = subscribed
            self.previous = IOReportCreateSamples(sub, subscribed, nil)
        }

        /// 一次差分读数
        func delta() -> [RawChannel] {
            let trace = ProcessInfo.processInfo.environment["SWIFTMON_TRACE"] == "1"
            func tlog(_ m: String) { if trace { FileHandle.standardError.write("[io:\(name)] \(m)\n".data(using: .utf8)!) } }
            tlog("samples begin")
            guard let current = IOReportCreateSamples(subscription, channels, nil) else { tlog("samples nil"); return [] }
            tlog("samples ok")
            defer { previous = current }
            guard let previous else { tlog("no previous"); return [] }
            tlog("delta begin")
            guard let delta = IOReportCreateSamplesDelta(previous, current, nil) else { tlog("delta nil"); return [] }
            tlog("delta ok, parsing")
            let parsed = Self.parse(delta, kind: kind)
            tlog("parsed \(parsed.count)")
            return parsed
        }

        private static func channelArray(_ dict: CFDictionary) -> CFArray? {
            let key = "IOReportChannels" as CFString
            guard let raw = CFDictionaryGetValue(dict, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
            return Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue()
        }

        private static func parse(_ dict: CFDictionary, kind: ChannelKind) -> [RawChannel] {
            guard let array = channelArray(dict) else { return [] }
            var out: [RawChannel] = []
            let count = CFArrayGetCount(array)
            out.reserveCapacity(count)
            for index in 0..<count {
                guard let channel = CFArrayGetValueAtIndex(array, index) else { continue }
                let group = (IOReportChannelGetGroup(channel)?.takeUnretainedValue() as String?) ?? ""
                let sub = (IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
                let name = (IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String?) ?? ""
                let unit = (IOReportChannelGetUnitLabel(channel)?.takeUnretainedValue() as String?) ?? ""

                // 只对匹配的类型调用对应 getter：状态通道读驻留，计数器通道读整数值。
                // 混用会拿到非预期数据（能耗通道没有状态、驻留通道没有简单值）。
                switch kind {
                case .state:
                    var residencies: [(String, Int64)] = []
                    let stateCount = IOReportStateGetCount(channel)
                    if stateCount > 0 {
                        residencies.reserveCapacity(Int(stateCount))
                        for state in 0..<stateCount {
                            let stateName = (IOReportStateGetNameForIndex(channel, state)?.takeUnretainedValue() as String?) ?? "S\(state)"
                            residencies.append((stateName, IOReportStateGetResidency(channel, state)))
                        }
                    }
                    out.append(RawChannel(group: group, subGroup: sub, name: name, unit: unit,
                                          value: 0, residencies: residencies))
                case .simple:
                    out.append(RawChannel(group: group, subGroup: sub, name: name, unit: unit,
                                          value: IOReportSimpleGetIntegerValue(channel, 0),
                                          residencies: []))
                }
            }
            return out
        }
    }

    private var subscriptions: [GroupSubscription] = []
    private(set) var channelCount = 0

    init?() {
        let specs: [(String, String, String?, ChannelKind)] = [
            ("cpu", "CPU Stats", "CPU Core Performance States", .state),
            ("gpu", "GPU Stats", "GPU Performance States", .state),
            ("energy", "Energy Model", nil, .simple),
        ]
        for (name, group, subgroup, kind) in specs {
            if let subscription = GroupSubscription(name: name, group: group, subGroup: subgroup, kind: kind) {
                subscriptions.append(subscription)
            }
        }
        guard !subscriptions.isEmpty else { return nil }
        // 用一次空跑确认管道可用
        let probe = subscriptions.flatMap { $0.delta() }
        guard !probe.isEmpty else { return nil }
        channelCount = probe.count
    }

    /// 返回自上次采样以来的差分读数。
    func sample() -> [RawChannel] {
        subscriptions.flatMap { $0.delta() }
    }
}
