#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INO="$ROOT/QuickVibeMicStick/QuickVibeMicStick.ino"
OTA_CPP="$ROOT/QuickVibeMicStick/micstick_ota.cpp"

grep -q 'NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC' "$INO" \
  || { echo "FAIL: OTA control characteristic must require encryption" >&2; exit 1; }
grep -q 'NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE_ENC' "$INO" \
  || { echo "FAIL: OTA data characteristic must require encryption" >&2; exit 1; }
grep -q 'NimBLEDevice::setSecurityAuth(false, false, true)' "$INO" \
  || { echo "FAIL: BLE security must use Secure Connections" >&2; exit 1; }
grep -q 'if (!connInfo.isEncrypted()) return;' "$INO" \
  || { echo "FAIL: OTA callbacks must reject unencrypted writes" >&2; exit 1; }

grep -q 'micstickOta.note_runtime_health();' "$INO" \
  || { echo "FAIL: main loop must report runtime health" >&2; exit 1; }
grep -q 'micstickOta.note_audio_health();' "$INO" \
  || { echo "FAIL: audio task must report runtime health" >&2; exit 1; }
grep -q 'if (bytesRead > 0) micstickOta.note_audio_health();' "$INO" \
  || { echo "FAIL: audio health must follow a successful I2S read" >&2; exit 1; }
if grep -q 'addServiceUUID(OTA_SERVICE_UUID)' "$INO"; then
  echo "FAIL: OTA UUID must not consume the advertising payload" >&2
  exit 1
fi
if grep -q 'micstickOta.confirm_boot();' "$INO"; then
  echo "FAIL: OTA boot confirmation must not happen directly in setup" >&2
  exit 1
fi
grep -q 'maybe_confirm_boot' "$OTA_CPP" \
  || { echo "FAIL: OTA boot confirmation must be gated by health checks" >&2; exit 1; }
grep -q 'esp_ota_mark_app_invalid_rollback_and_reboot' "$OTA_CPP" \
  || { echo "FAIL: failed OTA health checks must trigger rollback and reboot" >&2; exit 1; }

echo "PASS: test_micstick_ota_security_contract"
