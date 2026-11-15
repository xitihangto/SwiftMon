// SwiftUI 界面：仿 macmon 的"盒子里放标题 + 曲线"布局
//   上排：E-CPU / P-CPU / GPU / RAM          下排：CPU / GPU / ANE / 合计 功耗

import SwiftUI

struct RootView: View {
    @ObservedObject var monitor: Monitor

    private let cardBg = Color(red: 0.11, green: 0.12, blue: 0.14)
    private let subtle = Color(white: 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 12) {
                MetricCard(title: "E-CPU",
                           value: Fmt.percent((monitor.snapshot.eCluster?.usage ?? 0) * 100),
                           detail: "\(Fmt.mhz(monitor.snapshot.eCluster?.freqMHz ?? 0))Hz × \(monitor.snapshot.eCluster?.coreCount ?? 0)",
                           series: monitor.eCPU, tint: .green, maxValue: 100)
                MetricCard(title: "P-CPU",
                           value: Fmt.percent((monitor.snapshot.pCluster?.usage ?? 0) * 100),
                           detail: "\(Fmt.mhz(monitor.snapshot.pCluster?.freqMHz ?? 0))Hz × \(monitor.snapshot.pCluster?.coreCount ?? 0)",
                           series: monitor.pCPU, tint: .orange, maxValue: 100)
                MetricCard(title: "GPU",
                           value: Fmt.percent(monitor.snapshot.gpuUsage * 100),
                           detail: "\(Fmt.mhz(monitor.snapshot.gpuFreqMHz))Hz",
                           series: monitor.gpu, tint: .purple, maxValue: 100)
                MetricCard(title: "RAM",
                           value: Fmt.bytes(monitor.snapshot.memory.used),
                           detail: "共 \(Fmt.bytes(monitor.snapshot.memory.total)) · swap \(Fmt.bytes(monitor.snapshot.memory.swapUsed))",
                           series: monitor.ram, tint: .blue,
                           maxValue: Double(monitor.snapshot.memory.total) / 1_073_741_824)
            }
            HStack(spacing: 12) {
                MetricCard(title: "CPU+ANE 功耗", value: Fmt.watts(monitor.snapshot.cpuPower),
                           detail: "整机 − GPU（估算）",
                           series: monitor.cpuPower, tint: .yellow, maxValue: nil)
                MetricCard(title: "GPU 功耗", value: Fmt.watts(monitor.snapshot.gpuPower),
                           detail: monitor.snapshot.gpuPower > 0 ? "活动 \(Fmt.percent(monitor.snapshot.gpuUsage * 100))" : "无数据",
                           series: monitor.gpuPower, tint: .pink, maxValue: nil)
                MetricCard(title: "ANE 功耗", value: Fmt.watts(monitor.snapshot.anePower),
                           detail: monitor.snapshot.anePower > 0 ? "Energy Model" : "macOS 27 冻结",
                           series: monitor.anePower, tint: .teal, maxValue: nil)
                MetricCard(title: "整机功耗", value: Fmt.watts(monitor.snapshot.totalPower),
                           detail: monitor.snapshot.systemPower != nil ? "SMC 实测" : "CPU+GPU+ANE",
                           series: monitor.totalPower, tint: .red, maxValue: nil)
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 480)
        .background(Color(red: 0.07, green: 0.08, blue: 0.09))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("SwiftMon").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Apple Silicon 实时监控").font(.system(size: 12)).foregroundStyle(subtle)
            Spacer()
            Text("采样 \(String(format: "%.0f", monitor.sampleInterval))s")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(subtle)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Label(String(format: "自身 CPU %.2f%%", monitor.snapshot.selfCost.cpuPercent), systemImage: "gauge.with.dots.needle.bottom.50percent")
            Label("内存 \(Fmt.bytes(monitor.snapshot.selfCost.residentBytes))", systemImage: "memorychip")
            Label("\(monitor.snapshot.selfCost.threadCount) 线程", systemImage: "list.bullet")
            Spacer()
            Text(monitor.diagnostic).font(.system(size: 11, design: .monospaced)).foregroundStyle(subtle)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(subtle)
    }
}

// MARK: - 单张卡片

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let series: Series
    let tint: Color
    let maxValue: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(detail).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.5)).lineLimit(1)
            Sparkline(values: series.values, tint: tint, maxValue: maxValue)
                .frame(height: 54)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.11, green: 0.12, blue: 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(white: 0.18), lineWidth: 1))
    }
}

// MARK: - 曲线

struct Sparkline: View {
    let values: [Double]
    let tint: Color
    let maxValue: Double?

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            let upper = max(maxValue ?? (values.max() ?? 1) * 1.2, 0.0001)
            let stepX = size.width / CGFloat(max(values.count - 1, 1))
            var path = Path()
            var area = Path()
            for (index, raw) in values.enumerated() {
                let normalized = min(max(raw / upper, 0), 1)
                let point = CGPoint(x: CGFloat(index) * stepX,
                                    y: size.height - CGFloat(normalized) * size.height)
                if index == 0 {
                    path.move(to: point)
                    area.move(to: CGPoint(x: point.x, y: size.height))
                    area.addLine(to: point)
                } else {
                    path.addLine(to: point)
                    area.addLine(to: point)
                }
            }
            area.addLine(to: CGPoint(x: CGFloat(values.count - 1) * stepX, y: size.height))
            area.closeSubpath()

            context.fill(area, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.35), tint.opacity(0.02)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(path, with: .color(tint.opacity(0.95)), lineWidth: 1.5)
        }
    }
}
