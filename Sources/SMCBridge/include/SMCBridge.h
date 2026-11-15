// AppleSMC 最小桥接：结构与调用方式按 C 布局实现（Swift 手工打包 struct 会踩对齐坑）。
// 只暴露"读一个 4 字节 float 类型的 SMC key"这一件事，够取整机功耗。

#ifndef SMCBRIDGE_H
#define SMCBRIDGE_H

/// 读取 SMC 中 4 字节 float key（如 PSTR / PDTR）。成功返回 1 并写入 *out。
int smc_read_float(const char *key, double *out);

/// SMC 中 key 的总数，用于判断 SMC 是否可用（不可用返回 0）。
unsigned smc_key_count(void);

#endif
