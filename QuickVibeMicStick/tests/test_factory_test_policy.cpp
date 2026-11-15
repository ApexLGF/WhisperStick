#include <assert.h>

#include "../factory_test_policy.h"

int main() {
    using namespace factory_test;

    assert(!batteryVoltagePass(false, 4000));
    assert(!batteryVoltagePass(true, 2999));
    assert(batteryVoltagePass(true, 3000));
    assert(batteryVoltagePass(true, 4200));
    assert(!batteryVoltagePass(true, 4401));
    assert(roomTemperatureNtcPass(0));
    assert(!roomTemperatureNtcPass(2));
    assert(!roomTemperatureNtcPass(3));
    assert(!roomTemperatureNtcPass(5));
    assert(!roomTemperatureNtcPass(6));

    const int16_t dcOnly[] = {1500, 1500, 1500, 1500};
    MicrophoneBlock dcBlock = analyzeMicrophoneBlock(dcOnly, 4);
    assert(dcBlock.centeredSquares == 0);
    assert(dcBlock.centeredPeak == 0);
    const int16_t dcWithSignal[] = {1400, 1500, 1600, 1500};
    MicrophoneBlock signalBlock = analyzeMicrophoneBlock(dcWithSignal, 4);
    assert(signalBlock.centeredSquares == 20000);
    assert(signalBlock.centeredPeak == 100);

    MicrophoneMetrics good = {30, 180, 2000, 32000, 0, 0};
    assert(microphonePass(good));
    good.baselineRms = 100;
    good.maximumRms = 129;
    assert(!microphonePass(good));
    good.maximumRms = 130;
    assert(microphonePass(good));
    MicrophoneMetrics measuredV14 = {162, 222, 534, 80896, 0, 0};
    assert(microphonePass(measuredV14));
    measuredV14.peak = 323;
    assert(!microphonePass(measuredV14));
    good.samples = 15999;
    assert(!microphonePass(good));
    good.samples = 32000;
    good.zeroSamples = 7000;
    assert(!microphonePass(good));
    good.zeroSamples = 0;
    good.clippedSamples = 2000;
    assert(!microphonePass(good));
    return 0;
}
