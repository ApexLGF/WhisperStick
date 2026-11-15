#include <assert.h>

#include "../sgm41511_regs.h"
#include "../battery_power_policy.h"
#include "../power_disconnect_policy.h"

int main() {
    using namespace sgm41511;

    assert(kAddress == 0x6B);
    assert(iindpmCode(100) == 0);
    assert(iindpmCode(500) == 4);
    assert(iindpmCode(800) == 7);
    assert(iindpmCode(3200) == 31);
    assert(ichgCode(300) == 5);
    assert(ichgCode(480) == 8);
    assert(preTermCode(60) == 0);
    assert(preTermCode(120) == 1);
    assert(vregField(4208) == 0x58);
    assert(sysMinField(2600) == 0x00);
    assert(sysMinField(3300) == 0x06);  // floor to the supported 3.2V setting
    assert(sysMinField(3500) == 0x0A);
    assert(sysMinField(3700) == 0x0E);
    assert(replaceField(0xE0, kIindpmMask, iindpmCode(800)) == 0xE7);
    assert(replaceField(0xFF, kWatchdogMask, 0) == 0xCF);
    assert(chargeState(0x00) == 0);
    assert(chargeState(0x08) == 1);
    assert(chargeState(0x10) == 2);
    assert(chargeState(0x18) == 3);
    assert(ntcFault(0x00) == NtcFault::Normal);
    assert(ntcFault(0x02) == NtcFault::Warm);
    assert(ntcFault(0x03) == NtcFault::Cool);
    assert(ntcFault(0x05) == NtcFault::Cold);
    assert(ntcFault(0x06) == NtcFault::Hot);
    assert(ntcFault(0x07) == NtcFault::Unknown);
    assert(!ntcFaultIsSevere(NtcFault::Warm));
    assert(!ntcFaultIsSevere(NtcFault::Cool));
    assert(ntcFaultIsSevere(NtcFault::Cold));
    assert(ntcFaultIsSevere(NtcFault::Hot));
    assert(replaceField(0x30, kWatchdogMask | kJeitaIsetMask,
                        kJeitaIsetMask) == 0x01);
    assert(replaceField(0x5C, kJeitaVsetMask, 0) == 0x4C);
    assert(replaceField(0x4C,
                        kBatfetDisable | kBatfetDelay | kBatfetResetEnable,
                        kBatfetResetEnable) == 0x44);
    assert((static_cast<uint8_t>(0x44 | kBatfetDisable)) == 0x64);
    assert(partNumber(0x10) == kExpectedPartNumber);

    VsysRegulationDiagnosticGuard guard;
    for (uint8_t i = 0; i < 20; ++i) guard.observe(true, false, true, 9000);
    assert(!guard.sustained());
    for (uint8_t i = 0; i < 4; ++i) guard.observe(true, false, true, 10000 + i * 1000);
    assert(!guard.sustained());
    guard.observe(true, false, true, 14000);
    assert(guard.sustained());
    guard.observe(true, true, true, 15000);  // VBUS suppresses shutdown and resets debounce.
    assert(!guard.sustained());
    guard.observe(false, false, true, 16000); // I2C failure is not a low-battery signal.
    assert(guard.samples() == 0);

    BatteryVoltageShutdownGuard batteryGuard;
    for (uint8_t i = 0; i < 5; ++i) {
        batteryGuard.observe(true, false, 3200, 9000 + i * 1000);
    }
    assert(!batteryGuard.shutdownDue());  // Startup grace excludes the first sample.
    batteryGuard.observe(true, false, 3350, 13500);
    for (uint8_t i = 0; i < 4; ++i) {
        batteryGuard.observe(true, false, 3290, 14000 + i * 1000);
    }
    assert(!batteryGuard.shutdownDue());
    batteryGuard.observe(true, false, 3290, 18000);
    assert(batteryGuard.shutdownDue());
    batteryGuard.observe(true, false, 3350, 19000);  // Recovery clears debounce.
    assert(!batteryGuard.shutdownDue());
    batteryGuard.observe(true, true, 3000, 20000);   // Never auto-L3 while USB is valid.
    assert(batteryGuard.samples() == 0);
    batteryGuard.observe(false, false, 0, 21000);    // Missing ADC is not low voltage.
    assert(batteryGuard.samples() == 0);
    batteryGuard.observe(true, false, 3200, 22000);
    assert(batteryGuard.samples() == 1);
    batteryGuard.reset();                            // VBUS edges discard stale samples.
    assert(batteryGuard.samples() == 0);

    DisconnectShutdownGuard disconnectGuard(5UL * 60UL * 1000UL);
    assert(!disconnectGuard.shutdownDue(999999));  // No disconnect edge yet.
    disconnectGuard.noteConnection(false, 1000);
    assert(!disconnectGuard.shutdownDue(300999));
    disconnectGuard.noteUserActivity(300000);
    assert(!disconnectGuard.shutdownDue(599999));
    assert(disconnectGuard.shutdownDue(600000));
    disconnectGuard.noteConnection(true, 600001);
    assert(!disconnectGuard.shutdownDue(1000000));
    disconnectGuard.noteUserActivity(1000001);  // Connected activity must not arm it.
    assert(!disconnectGuard.shutdownDue(2000000));
    disconnectGuard.noteConnection(false, 0xFFFFFF00U);
    assert(!disconnectGuard.shutdownDue(0x000000F0U));
    const uint32_t wrappedDeadline = static_cast<uint32_t>(
        0xFFFFFF00ULL + 5ULL * 60ULL * 1000ULL);
    assert(disconnectGuard.shutdownDue(wrappedDeadline));

    // The hard 30-minute user-idle deadline is independent from BLE transport
    // churn. Reconnects may wake the UI, but must not keep a forgotten device on.
    L3ShutdownGuard l3Guard(30UL * 60UL * 1000UL, 5UL * 60UL * 1000UL);
    l3Guard.beginBatteryWindow(0);
    for (uint32_t minute = 1; minute < 30; ++minute) {
        const uint32_t t = minute * 60UL * 1000UL;
        l3Guard.noteConnection((minute & 1U) != 0, t);
        assert(!l3Guard.idleDue(t));
    }
    assert(l3Guard.idleDue(30UL * 60UL * 1000UL));

    // A physical input resets both the hard idle clock and a disconnected
    // reconnect window, giving the user the full advertised time.
    l3Guard.noteConnection(false, 30UL * 60UL * 1000UL);
    l3Guard.noteUserActivity(31UL * 60UL * 1000UL);
    assert(!l3Guard.shutdownDue(35UL * 60UL * 1000UL + 59999UL));
    assert(l3Guard.disconnectedDue(36UL * 60UL * 1000UL));

    // Unplugging USB begins a fresh battery-use window instead of inheriting
    // hours of harmless USB-powered idle time.
    L3ShutdownGuard unplugGuard(30UL * 60UL * 1000UL, 5UL * 60UL * 1000UL);
    unplugGuard.beginBatteryWindow(100UL * 60UL * 1000UL);
    assert(!unplugGuard.idleDue(129UL * 60UL * 1000UL));
    assert(unplugGuard.idleDue(130UL * 60UL * 1000UL));
    assert(!unplugGuard.disconnectedDue(104UL * 60UL * 1000UL + 59999UL));
    assert(unplugGuard.disconnectedDue(105UL * 60UL * 1000UL));

    // A stale disconnect deadline accumulated while USB suppresses L3 must be
    // restarted when the cable is removed.
    L3ShutdownGuard staleDisconnect(30UL * 60UL * 1000UL, 5UL * 60UL * 1000UL);
    staleDisconnect.noteConnection(false, 0);
    assert(staleDisconnect.disconnectedDue(10UL * 60UL * 1000UL));
    staleDisconnect.beginBatteryWindow(10UL * 60UL * 1000UL);
    assert(!staleDisconnect.shutdownDue(14UL * 60UL * 1000UL + 59999UL));
    assert(staleDisconnect.disconnectedDue(15UL * 60UL * 1000UL));
    return 0;
}
