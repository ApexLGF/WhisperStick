#pragma once

#include <stdint.h>

// Tracks the battery-only BLE-disconnection shutdown window.  User activity
// while disconnected starts a fresh window, so waking/using the device always
// leaves the full reconnect timeout available.
class DisconnectShutdownGuard {
public:
    explicit constexpr DisconnectShutdownGuard(uint32_t timeoutMs)
        : timeoutMs_(timeoutMs) {}

    void noteConnection(bool connected, uint32_t nowMs) {
        connected_ = connected;
        armed_ = !connected;
        disconnectedSinceMs_ = nowMs;
    }

    void noteUserActivity(uint32_t nowMs) {
        if (connected_) return;
        armed_ = true;
        disconnectedSinceMs_ = nowMs;
    }

    bool shutdownDue(uint32_t nowMs) const {
        return armed_ && !connected_ &&
               static_cast<uint32_t>(nowMs - disconnectedSinceMs_) >= timeoutMs_;
    }

private:
    const uint32_t timeoutMs_;
    uint32_t disconnectedSinceMs_ = 0;
    bool connected_ = false;
    bool armed_ = false;
};

// Owns the two independent L3 deadlines:
//   1. a hard user-idle window; automatic BLE reconnects must not reset it;
//   2. the shorter BLE-disconnected window, which physical user activity does reset.
// USB gating stays in PowerManager because the guard deliberately has no hardware policy.
class L3ShutdownGuard {
public:
    constexpr L3ShutdownGuard(uint32_t idleTimeoutMs, uint32_t disconnectTimeoutMs)
        : idleTimeoutMs_(idleTimeoutMs), disconnect_(disconnectTimeoutMs) {}

    // Start a fresh battery-use window at boot or on the VBUS online->offline edge.
    void beginBatteryWindow(uint32_t nowMs) {
        lastUserActivityMs_ = nowMs;
        idleArmed_ = true;
        // USB may have suppressed a disconnect deadline for hours. Starting a
        // battery session must grant a fresh reconnect window rather than shut
        // down immediately because of that stale deadline.
        disconnect_.noteUserActivity(nowMs);
    }

    void noteUserActivity(uint32_t nowMs) {
        lastUserActivityMs_ = nowMs;
        idleArmed_ = true;
        disconnect_.noteUserActivity(nowMs);
    }

    void noteConnection(bool connected, uint32_t nowMs) {
        // Intentionally does not touch lastUserActivityMs_. A Mac reconnect is
        // transport maintenance, not physical interaction with the device.
        disconnect_.noteConnection(connected, nowMs);
    }

    bool idleDue(uint32_t nowMs) const {
        return idleArmed_ &&
               static_cast<uint32_t>(nowMs - lastUserActivityMs_) >= idleTimeoutMs_;
    }

    bool disconnectedDue(uint32_t nowMs) const {
        return disconnect_.shutdownDue(nowMs);
    }

    bool shutdownDue(uint32_t nowMs) const {
        return idleDue(nowMs) || disconnectedDue(nowMs);
    }

private:
    const uint32_t idleTimeoutMs_;
    uint32_t lastUserActivityMs_ = 0;
    bool idleArmed_ = false;
    DisconnectShutdownGuard disconnect_;
};
