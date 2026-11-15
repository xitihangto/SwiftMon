// 从 IOKit 的 pmgr 节点读取 DVFS 频率表（与 macmon 同源）：
//   CPU E 核 / P 核：voltage-states{1,5}-sram，单位 kHz
//   GPU：voltage-states9，单位 Hz

import Foundation
import IOKit

struct FreqTables {
    var eCPU: [Double] = []   // MHz
    var pCPU: [Double] = []   // MHz
    var gpu: [Double] = []    // MHz

    var isUsable: Bool { !eCPU.isEmpty && !pCPU.isEmpty && !gpu.isEmpty }
}

enum FreqTableReader {

    /// IOKit 中 pmgr 节点可能不止一个（含 stub），先到先得，和 macmon 一致。
    static func read() -> FreqTables {
        var tables = FreqTables()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else {
            return tables
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)
            guard name.contains("pmgr") else { continue }

            if tables.eCPU.isEmpty, let raw = frequencies(entry: entry, key: "voltage-states1-sram") {
                tables.eCPU = raw.map { $0 / 1000.0 }   // kHz → MHz
            }
            if tables.pCPU.isEmpty, let raw = frequencies(entry: entry, key: "voltage-states5-sram") {
                tables.pCPU = raw.map { $0 / 1000.0 }   // kHz → MHz
            }
            if tables.gpu.isEmpty, let raw = frequencies(entry: entry, key: "voltage-states9") {
                tables.gpu = raw.map { $0 / 1_000_000.0 } // Hz → MHz
            }
            if tables.isUsable { break }
        }
        return tables
    }

    /// 属性是 (频率, 电压) 的 UInt32 对，取奇数位前的频率。
    private static func frequencies(entry: io_registry_entry_t, key: String) -> [Double]? {
        guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data, data.count >= 8 else { return nil }
        var values: [Double] = []
        data.withUnsafeBytes { raw in
            let count = data.count / 4
            for i in stride(from: 0, to: count, by: 2) {
                values.append(Double(raw.load(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
        return values.isEmpty ? nil : values
    }
}
