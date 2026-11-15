#include "SMCBridge.h"

#include <stdint.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>

// 与 AppleSMC 用户客户端交换的 80 字节结构（偏移已用 C offsetof 验证）
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Vers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } PLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } KeyInfo;
typedef struct {
    uint32_t key;
    Vers vers;
    PLimit pLimit;
    KeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static io_connect_t g_conn = 0;

static int smc_open(void) {
    if (g_conn != 0) return 1;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &g_conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { g_conn = 0; return 0; }
    return 1;
}

static uint32_t smc_fourcc(const char *key) {
    return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) | (uint32_t)(uint8_t)key[3];
}

static int smc_key_info(uint32_t key, uint32_t *size) {
    SMCKeyData input, output;
    memset(&input, 0, sizeof input);
    memset(&output, 0, sizeof output);
    input.key = key;
    input.data8 = 9; // kSMCGetKeyInfo
    size_t outSize = sizeof output;
    if (IOConnectCallStructMethod(g_conn, 2, &input, sizeof input, &output, &outSize) != KERN_SUCCESS) return 0;
    if (output.result != 0) return 0;
    *size = output.keyInfo.dataSize;
    return 1;
}

int smc_read_float(const char *key, double *out) {
    if (!smc_open()) return 0;
    uint32_t k = smc_fourcc(key);
    uint32_t size = 0;
    if (!smc_key_info(k, &size) || size < 4 || size > 32) return 0;

    SMCKeyData input, output;
    memset(&input, 0, sizeof input);
    memset(&output, 0, sizeof output);
    input.key = k;
    input.keyInfo.dataSize = size;
    input.data8 = 5; // kSMCReadKey
    input.data32 = size;
    size_t outSize = sizeof output;
    if (IOConnectCallStructMethod(g_conn, 2, &input, sizeof input, &output, &outSize) != KERN_SUCCESS) return 0;
    if (output.result != 0) return 0;

    // SMC 直接把 float 以主机字节序放在前 4 字节（实测 PSTR=5c4df040 → 7.51W），
    // 不要做字节序翻转，否则会得到 1e19 量级的垃圾值。
    float value;
    memcpy(&value, output.bytes, sizeof value);
    if (!(value > 0.0f) || value != value) return 0;
    *out = (double)value;
    return 1;
}

unsigned smc_key_count(void) {
    if (!smc_open()) return 0;
    uint32_t size = 0;
    if (!smc_key_info(smc_fourcc("#KEY"), &size)) return 0;
    return 1;
}
