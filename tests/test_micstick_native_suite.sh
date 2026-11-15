#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/QuickVibeMicStick"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

build_run() {
  local name="$1"
  shift
  g++ -std=c++17 -Wall -Wextra -Werror -I"$SRC" "$@" -o "$TMP/$name"
  "$TMP/$name"
}

build_run input_action \
  "$SRC/tests/test_input_action_mode.cpp" "$SRC/action_mode_protocol.cpp"
build_run application_switcher \
  "$SRC/tests/test_application_switcher_protocol.cpp" "$SRC/application_switcher_protocol.cpp"
build_run approval "$SRC/tests/test_approval_protocol.cpp"
(cd "$SRC" && build_run audio_agc "$SRC/tests/test_audio_agc.cpp")
build_run buzzer_volume "$SRC/tests/test_buzzer_volume.cpp"
build_run led_brightness "$SRC/tests/test_led_brightness.cpp"
build_run token_format "$SRC/tests/test_token_format.cpp"
build_run config_micsource "$SRC/tests/test_v5_config_micsource.cpp" "$SRC/v5_protocol.cpp"
build_run session_groups "$SRC/tests/test_v5_sessions_group.cpp" \
  "$SRC/v5_protocol.cpp" "$SRC/session_rows.cpp"
build_run agent_info "$SRC/tests/test_v5_agent_info.cpp" "$SRC/v5_protocol.cpp"
build_run task_lifecycle "$SRC/tests/test_task_lifecycle_protocol.cpp"
build_run ota_session "$SRC/tests/test_micstick_ota_session.cpp" \
  "$SRC/micstick_ota_protocol.cpp"

bash "$ROOT/tests/test_micstick_ota_security_contract.sh"

echo "PASS: test_micstick_native_suite"
