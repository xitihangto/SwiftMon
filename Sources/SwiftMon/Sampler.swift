// 指标聚合：把 IOReport 差分读数 + 内存读数整理成一帧快照，并维护环形缓冲供曲线使用。

import Foundation
import Combine

// MARK: - 数据模型

struct ClusterStat: Identifiable {
    let id: String        // "E" / "P"
    let label: String     // "E-CPU"
    let usage: Double     // 0...1
    let freqMHz: Double
    let coreCount: Int
}

struct Snapshot {
    var time = Date()
    var clusters: [ClusterStat] = []
    var cpuUsage: Double = 0
    var gpuUsage: Double = 0
    var gpuFreqMHz: Double = 0
    var cpuPower: Double = 0
    var gpuPower: Double = 0
    var anePower: Double = 0
    var totalPower: Double = 0
    /// SMC 读到的整机功耗（macOS 27 上 Energy Model 的 CPU/ANE 冻结，这是唯一可靠来源）
    var systemPower: Double? = nil
    var memory = MemoryStat()
    var selfCost = SelfCost()
    var hasPower = false

    var eCluster: ClusterStat? { clusters.first { $0.id == "E" } }
    var pCluster: ClusterStat? { clusters.first { $0.id == "P" } }
}

/// 定长环形缓冲：只保留最近 N 个采样点，永不增长。
final class Series {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = 120) { self.capacity = capacity }

    func append(_ value: Double) {
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

// MARK: - 监控器

final class Monitor: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var running = false

    let eCPU = Series()
    let pCPU = Series()
    let gpu = Series()
    let cpuPower = Series()
    let gpuPower = Series()
    let anePower = Series()
    let totalPower = Series()
    let ram = Series()

    private var sampler: IOReportSampler?
    private let systemPower = SystemPowerReader()
    private var freqs = FreqTables()
    private var selfCost = SelfCost()
    private var timer: Timer?
    private var lastTick: Double = 0
    private(set) var sampleInterval: Double = 1.0
    private(set) var diagnostic: String = ""

    private static let idleStates: Set<String> = ["IDLE", "DOWN", "OFF"]

    init() {
        freqs = FreqTableReader.read()
        sampler = IOReportSampler()
        if sampler == nil {
            diagnostic = "IOReport 订阅失败"
        } else {
            diagnostic = "IOReport \(sampler!.channelCount) 通道 / 频率表 E\(freqs.eCPU.count) P\(freqs.pCPU.count) GPU\(freqs.gpu.count)"
        }
        lastTick = SelfCost.now()
    }

    // MARK: 生命周期

    func start(interval: Double = 1.0) {
        sampleInterval = interval
        guard timer == nil else { return }
        lastTick = SelfCost.now()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        running = true
        tick()   // 第一帧立即出数
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        running = false
    }

    // MARK: 采样

    /// 取一帧并写入曲线，返回该帧（供 --dump 使用）。
    @discardableResult
    func tick() -> Snapshot {
        let trace = ProcessInfo.processInfo.environment["SWIFTMON_TRACE"] == "1"
        func tlog(_ m: String) { if trace { FileHandle.standardError.write("[sampler] \(m)\n".data(using: .utf8)!) } }
        let now = SelfCost.now()
        let dt = max(now - lastTick, 0.0001)
        lastTick = now

        tlog("sample begin")
        let raw = sampler?.sample() ?? []
        tlog("sample got \(raw.count) channels")
        var snap = compute(raw: raw, dt: dt)
        selfCost.update()
        snap.selfCost = selfCost
        snap.time = Date()

        // 曲线
        if let e = snap.eCluster { eCPU.append(e.usage * 100) }
        if let p = snap.pCluster { pCPU.append(p.usage * 100) }
        gpu.append(snap.gpuUsage * 100)
        cpuPower.append(snap.cpuPower + snap.anePower)
        gpuPower.append(snap.gpuPower)
        anePower.append(snap.anePower)
        totalPower.append(snap.totalPower)
        ram.append(Double(snap.memory.used) / 1_073_741_824)

        snapshot = snap
        return snap
    }

    private func compute(raw: [RawChannel], dt: Double) -> Snapshot {
        var snap = Snapshot()

        // --- CPU：按通道名前缀聚成 E / P 两个簇 ---
        var eActive = 0.0, eTotal = 0.0, eWeightedFreq = 0.0, eCores = 0
        var pActive = 0.0, pTotal = 0.0, pWeightedFreq = 0.0, pCores = 0

        for channel in raw where channel.group == "CPU Stats" && channel.subGroup == "CPU Core Performance States" {
            let isP = channel.name.hasPrefix("PCPU")
            let isE = channel.name.hasPrefix("ECPU") || channel.name.hasPrefix("MCPU")
            guard isP || isE else { continue }
            let table = isP ? freqs.pCPU : freqs.eCPU
            let stat = residencyStat(channel, freqs: table)
            if isP {
                pActive += stat.active; pTotal += stat.total
                pWeightedFreq += stat.freqMHz * stat.active
                pCores += 1
            } else {
                eActive += stat.active; eTotal += stat.total
                eWeightedFreq += stat.freqMHz * stat.active
                eCores += 1
            }
        }

        if eCores > 0 {
            let usage = eTotal > 0 ? eActive / eTotal : 0
            let freq = eActive > 0 ? eWeightedFreq / eActive : 0
            snap.clusters.append(ClusterStat(id: "E", label: "E-CPU", usage: usage, freqMHz: freq, coreCount: eCores))
        }
        if pCores > 0 {
            let usage = pTotal > 0 ? pActive / pTotal : 0
            let freq = pActive > 0 ? pWeightedFreq / pActive : 0
            snap.clusters.append(ClusterStat(id: "P", label: "P-CPU", usage: usage, freqMHz: freq, coreCount: pCores))
        }
        let activeAll = eActive + pActive
        let totalAll = eTotal + pTotal
        snap.cpuUsage = totalAll > 0 ? activeAll / totalAll : 0

        // --- GPU ---
        if let gpuChannel = raw.first(where: { $0.group == "GPU Stats" && $0.name == "GPUPH" }) {
            let stat = residencyStat(gpuChannel, freqs: freqs.gpu)
            snap.gpuUsage = stat.total > 0 ? stat.active / stat.total : 0
            snap.gpuFreqMHz = stat.freqMHz
        }

        // --- 能耗：能量差 / 时间 ---
        for channel in raw where channel.group == "Energy Model" {
            let joules = Double(channel.value) * unitToJoules(channel.unit)
            let watts = joules / dt
            switch channel.name {
            case "CPU Energy": snap.cpuPower += watts
            case "GPU Energy", "GPU": snap.gpuPower += watts
            case "ANE": snap.anePower += watts
            default: break
            }
            snap.hasPower = true
        }
        // 同一份能量若同时出现 mJ 的 "GPU" 与 nJ 的 "GPU Energy"，只取其一，避免翻倍
        if snap.gpuPower > 0 {
            // 只有当两个通道同时存在时才会翻倍：这里用最大值兜底（量级不同，实际不会同时有效）
            snap.gpuPower = min(snap.gpuPower, max(snap.cpuPower, 200))
        }
        if let sys = systemPower.readWatts() {
            snap.systemPower = sys
            // CPU/ANE 的 Energy Model 计数器冻结时，用整机减 GPU 估算
            if snap.cpuPower == 0 && snap.anePower == 0 && sys > snap.gpuPower {
                snap.cpuPower = sys - snap.gpuPower
            }
        }
        snap.totalPower = snap.systemPower ?? (snap.cpuPower + snap.gpuPower + snap.anePower)

        tlog("compute done, reading memory")
        snap.memory = MemoryReader.read()
        return snap
    }

    // MARK: 驻留 → 利用率/频率

    private struct ResidencyStat {
        var usage: Double = 0
        var active: Double = 0
        var total: Double = 0
        var freqMHz: Double = 0
    }

    private func residencyStat(_ channel: RawChannel, freqs: [Double]) -> ResidencyStat {
        var out = ResidencyStat()
        guard !channel.residencies.isEmpty else { return out }
        var total = 0.0
        var activeStates: [(String, Double)] = []
        for (name, residency) in channel.residencies {
            let value = Double(residency)
            total += value
            if !Self.idleStates.contains(name) { activeStates.append((name, value)) }
        }
        let active = activeStates.reduce(0) { $0 + $1.1 }
        out.total = total
        out.active = active
        out.usage = total > 0 ? active / total : 0

        // 频率表与活跃状态数量可能不等：从高频端对齐
        let n = min(activeStates.count, freqs.count)
        if n > 0 {
            let states = activeStates.suffix(n)
            let table = freqs.suffix(n)
            var weight = 0.0
            var weighted = 0.0
            for (index, state) in states.enumerated() {
                weighted += state.1 * table[table.startIndex + index]
                weight += state.1
            }
            out.freqMHz = weight > 0 ? weighted / weight : 0
        }
        return out
    }

    private func unitToJoules(_ unit: String) -> Double {
        switch unit {
        case "mJ": return 1e-3
        case "uJ", "µJ": return 1e-6
        case "nJ": return 1e-9
        case "J": return 1.0
        default: return 1e-3   // 未知单位按 mJ 处理
        }
    }

    // MARK: 文本输出（--dump）

    func textLine(_ snap: Snapshot, index: Int) -> String {
        var lines: [String] = []
        let e = snap.eCluster.map { "\($0.label) \(Fmt.percent($0.usage * 100)) \(Fmt.mhz($0.freqMHz))Hz×\($0.coreCount)" } ?? "E n/a"
        let p = snap.pCluster.map { "\($0.label) \(Fmt.percent($0.usage * 100)) \(Fmt.mhz($0.freqMHz))Hz×\($0.coreCount)" } ?? "P n/a"
        lines.append(String(format: "[%3ds] %@ | %@ | CPU合计 %@", index, e, p, Fmt.percent(snap.cpuUsage * 100)))
        let sys = snap.systemPower.map { Fmt.watts($0) } ?? "n/a"
        lines.append("      GPU \(Fmt.percent(snap.gpuUsage * 100)) \(Fmt.mhz(snap.gpuFreqMHz))Hz | 整机 \(sys) GPU \(Fmt.watts(snap.gpuPower)) CPU+ANE≈\(Fmt.watts(snap.cpuPower + snap.anePower))")
        lines.append("      内存 \(Fmt.bytes(snap.memory.used))/\(Fmt.bytes(snap.memory.total)) 压缩 \(Fmt.bytes(snap.memory.compressed)) swap \(Fmt.bytes(snap.memory.swapUsed)) | 自身 \(Fmt.percent(snap.selfCost.cpuPercent)) \(Fmt.bytes(snap.selfCost.residentBytes)) \(snap.selfCost.threadCount)线程")
        return lines.joined(separator: "\n")
    }
}
