// token_format.h — 当日累计 token 的 K/M 缩写格式化(REQ-020)
// 纯函数、无硬件依赖,便于宿主机 native 单测(tests/test_token_format.cpp)。
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>

// 规则:
//   <1000            → 原样("999")
//   >=1000 且 <1e6   → 四舍五入到整 K("348K");999500 起进位为 "1.0M"(避免 "1000K")
//   >=1e6            → "1.2M"(1 位小数)
// 输出写入 dst(cap>=8 足够)。
static inline void formatTokensKM(uint32_t n, char *dst, size_t cap) {
    if (n < 1000)            { snprintf(dst, cap, "%u", (unsigned)n); return; }
    if (n < 1000000) {
        uint32_t k = (n + 500) / 1000;                 // 四舍五入到 K
        if (k >= 1000) { snprintf(dst, cap, "%.1fM", k/1000.0); return; }  // 999500+→1.0M
        snprintf(dst, cap, "%uK", (unsigned)k);
        return;
    }
    double m = n / 1000000.0;
    snprintf(dst, cap, "%.1fM", m);                    // 1.2M / 12.3M
}
