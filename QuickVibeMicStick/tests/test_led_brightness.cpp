#include <assert.h>
#include <stdint.h>

#include "../led_brightness.h"

int main() {
    assert(ledClampBrightnessPercent(0) == 0);
    assert(ledClampBrightnessPercent(1) == 8);
    assert(ledClampBrightnessPercent(19) == 8);
    assert(ledClampBrightnessPercent(20) == 32);
    assert(ledClampBrightnessPercent(51) == 32);
    assert(ledClampBrightnessPercent(52) == 70);
    assert(ledClampBrightnessPercent(255) == 70);

    assert(ledScaleChannel(255, 32) == 82);
    assert(ledScaleChannel(3, 8) == 1);
    assert(ledScaleChannel(1, 8) == 1);
    assert(ledScaleChannel(3, 0) == 0);
    assert(ledScaleChannel(0, 70) == 0);

    return 0;
}
