# Third-party components

The root Apache-2.0 license covers original WhisperStick / QuickVibe source and documentation. It does not replace licenses attached to third-party code, fonts, or dependencies. Keep these notices when redistributing.

| Component | Version / source | License and location |
| --- | --- | --- |
| ChineseITN | Bundled Swift implementation | [Apache-2.0, attribution and modifications](QuickVibeHost/ThirdParty/ChineseITN/NOTICE); accompanying LICENSE and PATCHES.md |
| TokenRemain-derived usage presentation | Bundled implementation | [Apache-2.0 notice](QuickVibeHost/ThirdParty/TOKENREMAIN_NOTICE) and TOKENREMAIN_LICENSE |
| ccusage | 20.0.19, bundled universal macOS helper | [MIT](QuickVibeHost/ThirdParty/ccusage/CCUSAGE_LICENSE); [binary details](QuickVibeHost/ThirdParty/ccusage/README.md) |
| Sentry Cocoa | 9.24.0, pinned by Package.resolved | [MIT](licenses/Sentry-Cocoa.txt); crash reporting is disabled in this demo |
| TFT_eSPI | 2.5.43 | [Upstream license notices](licenses/TFT-eSPI.txt) |
| NimBLE-Arduino | 2.5.0 | [Apache-2.0](licenses/NimBLE-Arduino.txt); bundled NimBLE subcomponents retain their own notices |
| Adafruit NeoPixel | 1.12.3 | [LGPL-3.0](licenses/Adafruit-NeoPixel-LGPL-3.0.txt) |
| U8g2_for_TFT_eSPI | a170ef8b6d8414b1ee2ecc97b5b913e08f5597ac | [BSD-2-Clause and font notices](licenses/U8g2-for-TFT-eSPI.txt) |
| WenQuanYi Bitmap Song | Generated 12/16-pixel font subsets | [GPL-2.0 with font embedding exception](licenses/WenQuanYi.txt), [GPL text](licenses/GPL-2.0-only.txt) |
| Arduino-ESP32 / ESP-IDF and toolchain | Arduino 2.0.14 via PlatformIO | Licenses are distributed with downloaded packages and individual components |
| Sherpa-ONNX / ONNX Runtime / FunASR | Downloaded native frameworks | Upstream and bundled dependency licenses apply; see below |

## Font source and regeneration

`QuickVibeMicStick/i18n_font.generated.cpp` is generated font data, not Apache-licensed original artwork. The WenQuanYi copyright and font embedding exception are retained. The generator and locale catalogs are included. Obtain the upstream [U8g2 font source and converter](https://github.com/olikraus/u8g2/tree/master/tools/font), then run:

```bash
python3 QuickVibeMicStick/tools/generate_i18n_font.py --u8g2-root /path/to/u8g2
```

The source BDF files are `wenquanyi_9pt.bdf` and `wenquanyi_12pt.bdf`. The preparation script changes only the cached U8g2 Arduino dependency name from `TFT_eSPI Library` to `TFT_eSPI`; it does not modify its rendering code or font data.

## Native ASR dependencies

`QuickVibeHost/setup-frameworks.sh` downloads native frameworks and checks fixed SHA-256 values. The repository contains the App-side bridge code; it does not contain the complete framework build sources or downloaded model weights. In particular, the offline FunASR C bridge is part of the prebuilt archive. Building the App therefore currently depends on those published archives.

Upstream projects: [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx), [ONNX Runtime](https://github.com/microsoft/onnxruntime), [FunASR](https://github.com/modelscope/FunASR). Preserve each downloaded component's notices. Model weights have their own licenses; the source-code license does not license the weights.

## Redistribution

Firmware links libraries with their own redistribution requirements, including LGPL components. Retain source, version pins, build instructions and applicable notices when distributing derived firmware. Brand names, product illustrations and logos identify supported devices and integrations; they do not grant trademark rights or imply endorsement.
