#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "../v5_protocol.h"

int main() {
    UiModeCtx ctx = {};
    ctx.promptRequestId = 7;

    const uint8_t loading[] = {0x58, 7, 0};
    assert(v5IsFrame(loading, sizeof(loading)));
    assert(v5ParsePromptRecommendations(loading, sizeof(loading), 7, ctx));
    assert(ctx.promptDynamic && ctx.promptLoading);

    const uint8_t ready[] = {
        0x58, 7, 1, 2,
        6, 'R', 'e', 'v', 'i', 'e', 'w',
        4, 'T', 'e', 's', 't'
    };
    assert(v5ParsePromptRecommendations(ready, sizeof(ready), 7, ctx));
    assert(ctx.promptDynamic && !ctx.promptLoading && ctx.promptCount == 2);
    assert(strcmp(ctx.promptTitles[0], "Review") == 0);
    assert(strcmp(ctx.promptTitles[1], "Test") == 0);

    assert(!v5ParsePromptRecommendations(ready, sizeof(ready), 8, ctx));
    const uint8_t empty[] = {0x58, 7, 1, 0};
    assert(v5ParsePromptRecommendations(empty, sizeof(empty), 7, ctx));
    assert(ctx.promptCount == 0 && !ctx.promptLoading);
    const uint8_t truncated[] = {0x58, 7, 1, 1, 5, 'a'};
    assert(!v5ParsePromptRecommendations(truncated, sizeof(truncated), 7, ctx));
    const uint8_t trailing[] = {0x58, 7, 1, 1, 1, 'a', 0};
    assert(!v5ParsePromptRecommendations(trailing, sizeof(trailing), 7, ctx));

    puts("prompt recommendation protocol: PASS");
    return 0;
}
