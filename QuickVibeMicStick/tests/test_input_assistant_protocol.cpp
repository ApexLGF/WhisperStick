#include <assert.h>
#include <string.h>
#include <stdio.h>
#include "../v5_protocol.h"

int main() {
    UiModeCtx ctx = {};
    ctx.assistantRequestId = 9;
    const uint8_t loading[] = {0x59, 9, 0};
    assert(v5IsFrame(loading, sizeof(loading)));
    assert(v5ParseInputAssistant(loading, sizeof(loading), 9, ctx));
    assert(ctx.assistantState == 0);

    const uint8_t ready[] = {0x59, 9, 1, 1, 4, 't','e','x','t', 2,
                             5, 'S','h','o','r','t', 6, 'P','o','l','i','s','h'};
    assert(v5ParseInputAssistant(ready, sizeof(ready), 9, ctx));
    assert(ctx.assistantState == 1 && ctx.assistantSelectedScope);
    assert(ctx.assistantCount == 2 && strcmp(ctx.assistantPreview, "text") == 0);
    assert(strcmp(ctx.assistantTitles[1], "Polish") == 0);

    const uint8_t processing[] = {0x59, 9, 2};
    assert(v5ParseInputAssistant(processing, sizeof(processing), 9, ctx));
    assert(ctx.assistantState == 2);
    assert(!v5ParseInputAssistant(ready, sizeof(ready), 8, ctx));
    const uint8_t badState[] = {0x59, 9, 6};
    assert(!v5ParseInputAssistant(badState, sizeof(badState), 9, ctx));
    const uint8_t truncated[] = {0x59, 9, 1, 0, 4, 'x'};
    assert(!v5ParseInputAssistant(truncated, sizeof(truncated), 9, ctx));
    puts("input assistant protocol: PASS");
}
