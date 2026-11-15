#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-micstick-v14}"
echo "[1/2] Install pinned dependencies for $TARGET"
pio pkg install -d "$ROOT/QuickVibeMicStick" -e "$TARGET" --skip-dependencies
echo "[2/2] Normalize upstream U8g2 dependency metadata"
python3 - "$ROOT/QuickVibeMicStick/.pio/libdeps/$TARGET" <<'PY'
from pathlib import Path
import sys
manifest = Path(sys.argv[1]) / 'U8g2_for_TFT_eSPI' / 'library.properties'
if manifest.exists():
    # Upstream calls TFT_eSPI "TFT_eSPI Library". PlatformIO's pinned
    # registry package is named TFT_eSPI; do not resolve an unpinned duplicate.
    source = manifest.read_text()
    manifest.write_text(source.replace('depends=TFT_eSPI Library', 'depends=TFT_eSPI'))
PY
