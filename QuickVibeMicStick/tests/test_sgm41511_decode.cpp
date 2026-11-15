#include <assert.h>
#include <string.h>

#include "../sgm41511_decode.h"

int main() {
    using namespace sgm41511_diag;

    assert(strcmp(vbusName(0x00), "NONE") == 0);
    assert(strcmp(vbusName(0x20), "USB SDP") == 0);
    assert(strcmp(vbusName(0x40), "ADAPTER") == 0);
    assert(strcmp(vbusName(0xE0), "OTG") == 0);
    assert(strcmp(vbusName(0x60), "RESERVED") == 0);
    assert(strcmp(chargeName(0x08), "PRECHARGE") == 0);
    assert(strcmp(chargeName(0x10), "FAST") == 0);
    assert(strcmp(chargeName(0x18), "TERMINATED") == 0);
    assert(powerGood(0x04));
    assert(thermalRegulation(0x02));
    assert(vsysRegulation(0x01));

    assert(strcmp(chargeFaultName(0x00), "NORMAL") == 0);
    assert(strcmp(chargeFaultName(0x10), "INPUT") == 0);
    assert(strcmp(chargeFaultName(0x20), "THERM SHDN") == 0);
    assert(strcmp(chargeFaultName(0x30), "SAFETY TIMER") == 0);
    assert(watchdogFault(0x80));
    assert(boostFault(0x40));
    assert(batteryOverVoltage(0x08));

    assert(ntcZone(0x00) == NtcZone::Normal);
    assert(ntcZone(0x02) == NtcZone::Warm);
    assert(ntcZone(0x03) == NtcZone::Cool);
    assert(ntcZone(0x05) == NtcZone::Cold);
    assert(ntcZone(0x06) == NtcZone::Hot);
    assert(ntcZone(0x07) == NtcZone::Unknown);
    assert(strcmp(ntcRange(NtcZone::Warm), "45..60C") == 0);
    assert(strcmp(ntcRange(NtcZone::Hot), ">60C") == 0);

    assert(vbusGood(0x80));
    assert(vindpmActive(0x40));
    assert(iindpmActive(0x20));
    assert(topoffActive(0x08));
    assert(acovActive(0x04));
    assert(vindpmInterruptMasked(0x02));
    assert(iindpmInterruptMasked(0x01));

    assert(iindpmMilliamps(0x07) == 800);
    assert(ichgMilliamps(0x08) == 480);
    assert(ichgMilliamps(0x3F) == 3000);
    assert(prechargeMilliamps(0x11) == 120);
    assert(terminationMilliamps(0x11) == 120);
    assert(regulationMillivolts(0x58) == 4208);
    assert(regulationMillivolts(0x78) == 4352);
    assert(systemMinimumMillivolts(0x0A) == 3500);
    assert(vindpmMillivolts(0x06) == 4500);
    assert(chargerEnabled(0x10));
    assert(otgEnabled(0x20));
    assert(watchdogDisabled(0x00));
    assert(dieThermalLimitC(0x02) == 120);
    assert(coolCurrentPercent(0x01) == 20);
    assert(warmVoltageLimitMv(0x00, 0x58) == 4100);

    assert(restoreDividerMillivolts(1900, 100000, 100000) == 3800);
    assert(restoreDividerMillivolts(1900, 200000, 100000) == 5700);
    assert(restoreDividerMillivolts(1900, 100000, 0) == 0);
    assert(plausibleBatteryMillivolts(2500));
    assert(plausibleBatteryMillivolts(4500));
    assert(!plausibleBatteryMillivolts(2499));
    assert(!plausibleBatteryMillivolts(4501));
    return 0;
}
