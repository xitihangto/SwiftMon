// 整机功耗：macOS 27 上 Energy Model 的 CPU/ANE 计数器是冻结的（读 0），
// 因此整机功耗走 SMC（PSTR 有电池机型 / PDTR、PD0R 无电池机型），与 macmon 同一兜底链。

import Foundation
import SMCBridge

struct SystemPowerReader {
    private let keys = ["PSTR", "PDTR", "PD0R"]
    private(set) var available: Bool

    init() {
        available = smc_key_count() != 0
    }

    /// 当前整机功耗（瓦），无数据返回 nil
    func readWatts() -> Double? {
        guard available else { return nil }
        for key in keys {
            var value: Double = 0
            if smc_read_float(key, &value) != 0, value > 0 { return value }
        }
        return nil
    }
}
