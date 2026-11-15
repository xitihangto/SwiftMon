// 系统级读数：内存、swap、自身开销。全部走公开 API，成本接近 0。

import Foundation
import Darwin

// MARK: - 内存

struct MemoryStat {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
}

enum MemoryReader {

    static func read() -> MemoryStat {
        var stat = MemoryStat()
        stat.total = ProcessInfo.processInfo.physicalMemory

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            stat.free = UInt64(info.free_count) * page
            stat.wired = UInt64(info.wire_count) * page
            stat.compressed = UInt64(info.compressor_page_count) * page
            // 与 top / 活动监视器一致的口径：总内存 - 空闲 - 可回收的 purgeable
            let purgeable = UInt64(info.purgeable_count) * page
            stat.used = stat.total > (stat.free + purgeable) ? stat.total - stat.free - purgeable : 0
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            stat.swapUsed = swap.xsu_used
            stat.swapTotal = swap.xsu_total
        }
        return stat
    }
}

// MARK: - 自身开销

struct SelfCost {
    var cpuPercent: Double = 0
    var residentBytes: UInt64 = 0
    var threadCount: Int = 0

    private var lastUser: Double = 0
    private var lastSystem: Double = 0
    private var lastWall: Double = 0

    static func now() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    mutating func update() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpuSeconds = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        let wall = SelfCost.now()

        if lastWall > 0 {
            let elapsed = max(wall - lastWall, 0.0001)
            cpuPercent = max(0, (cpuSeconds - lastUser - lastSystem) / elapsed * 100)
        }
        lastUser = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        lastSystem = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        lastWall = wall

        var basic = mach_task_basic_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(infoCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &infoCount)
            }
        }
        if kr == KERN_SUCCESS {
            residentBytes = basic.resident_size
        }
        var threadList: thread_act_array_t?
        var threadCountOut: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &threadList, &threadCountOut) == KERN_SUCCESS, let list = threadList {
            threadCount = Int(threadCountOut)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(Int(threadCountOut) * MemoryLayout<thread_t>.stride))
        }
    }
}

// MARK: - 格式化

enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        let gb = Double(value) / 1_073_741_824
        if gb >= 10 { return String(format: "%.1fG", gb) }
        if gb >= 1 { return String(format: "%.2fG", gb) }
        return String(format: "%.0fM", Double(value) / 1_048_576)
    }

    static func watts(_ value: Double) -> String {
        value >= 10 ? String(format: "%.1fW", value) : String(format: "%.2fW", value)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func mhz(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.2fG", value / 1000) : String(format: "%.0fM", value)
    }
}
