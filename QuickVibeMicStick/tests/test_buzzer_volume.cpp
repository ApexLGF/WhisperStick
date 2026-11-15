#include <assert.h>
#include <stdint.h>

#include "../buzzer_volume.h"

int main() {
    assert(buzzerClampVolumePercent(0) == 0);
    assert(buzzerClampVolumePercent(1) == 20);
    assert(buzzerClampVolumePercent(10) == 20);
    assert(buzzerClampVolumePercent(20) == 20);
    assert(buzzerClampVolumePercent(30) == 20);
    assert(buzzerClampVolumePercent(31) == 40);
    assert(buzzerClampVolumePercent(40) == 40);
    assert(buzzerClampVolumePercent(50) == 40);
    assert(buzzerClampVolumePercent(51) == 60);
    assert(buzzerClampVolumePercent(60) == 60);
    assert(buzzerClampVolumePercent(70) == 60);
    assert(buzzerClampVolumePercent(71) == 80);
    assert(buzzerClampVolumePercent(80) == 80);
    assert(buzzerClampVolumePercent(90) == 80);
    assert(buzzerClampVolumePercent(91) == 100);
    assert(buzzerClampVolumePercent(100) == 100);
    assert(buzzerClampVolumePercent(255) == 100);

    assert(buzzerScaleDuty(300, 0) == 0);
    assert(buzzerScaleDuty(300, 20) == 36);
    assert(buzzerScaleDuty(300, 60) == 108);
    assert(buzzerScaleDuty(300, 100) == 180);
    assert(buzzerScaleDuty(0, 100) == 0);
    assert(buzzerScaleDuty(4000, 100) == 1023);
    assert(kBuzzerPreviewMs == 2000);
    assert(kBuzzerPreviewFreq == 932);

    return 0;
}
