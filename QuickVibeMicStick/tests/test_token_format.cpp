// test_token_format.cpp — native 单测 formatTokensKM(REQ-020)
// gtest 未装,用 assert + 返回码即可。
//
// Build:
//   g++ -std=c++17 -I. tests/test_token_format.cpp -o /tmp/t024_tokfmt && /tmp/t024_tokfmt
//
#include <cassert>
#include <cstring>
#include <cstdio>
#include "token_format.h"

static void expect(uint32_t n, const char *want) {
    char buf[8];
    formatTokensKM(n, buf, sizeof(buf));
    if (strcmp(buf, want) != 0) {
        printf("FAIL: formatTokensKM(%u) = \"%s\", want \"%s\"\n", (unsigned)n, buf, want);
        assert(false);
    }
    printf("ok: %u -> %s\n", (unsigned)n, buf);
}

int main() {
    // spec §A-3 验收用例
    expect(999,      "999");
    expect(1000,     "1K");
    expect(348123,   "348K");
    expect(999499,   "999K");
    expect(999500,   "1.0M");   // 进位边界:非 "1000K"
    expect(1200000,  "1.2M");
    // 补充边界
    expect(0,        "0");
    expect(1499,     "1K");     // 四舍五入到 1K
    expect(1500,     "2K");
    expect(12300000, "12.3M");
    printf("ALL PASS\n");
    return 0;
}
