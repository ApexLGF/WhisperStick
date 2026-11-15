#!/usr/bin/env bash
# 下载 ONNX Runtime 与 sherpa-onnx 预编译 xcframework 到 ThirdParty/(gitignored)。
# 克隆后、首次构建 QuickVibeHost 前跑一次。英文 Zipformer 与中文 FunASR 依赖它。
#
# Public, checksum-verified framework downloads.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)/ThirdParty/sherpa-onnx"
FUNASR_DIR="$(cd "$(dirname "$0")" && pwd)/ThirdParty/funasr"
FRAMEWORK_BASE_URL="${WHISPERSTICK_FRAMEWORK_BASE_URL:-https://ve.llamer.co/frameworks}"
PATH_REL="/frameworks/sherpa-onnx-frameworks-macos.tar.gz"
SHA="f306507227b80046e4c072bc982a53cc18ac2fe9905ba91b03ac523bda448656"
SHERPA_SHARED_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.8-macos-shared-onnxruntime-static.xcframework.zip"
SHERPA_SHARED_SHA="82d5cb3af38c3cb4871c3532a6c7dc86d6b7db1077bcc9d6a1047100976f199b"
mkdir -p "$DIR"
if [ ! -d "$DIR/onnxruntime.xcframework" ]; then
  TMP=$(mktemp -d)
  echo "⬇️  下载 sherpa-onnx 框架(~44MB)..."
  curl -fL --retry 5 -o "$TMP/fw.tar.gz" "${FRAMEWORK_BASE_URL}/sherpa-onnx-frameworks-macos.tar.gz"
  echo "${SHA}  $TMP/fw.tar.gz" | shasum -a 256 -c - || { echo "❌ SHA256 不匹配,中止"; rm -rf "$TMP"; exit 1; }
  tar xzf "$TMP/fw.tar.gz" -C "$DIR"; rm -rf "$TMP"
fi

# App 使用将 ONNX Runtime 静态封装在内部的 Sherpa 动态库。这样可将 Sherpa
# 自带的 OpenFST 与中文 FunASR 隔离，避免两个静态库的同名符号冲突。
if [ ! -d "$DIR/sherpa-onnx-shared.xcframework" ]; then
  T3=$(mktemp -d)
  echo "⬇️  下载 sherpa-onnx 英文识别运行库(~18MB)..."
  curl -fL --retry 5 -o "$T3/sherpa.zip" "$SHERPA_SHARED_URL"
  echo "${SHERPA_SHARED_SHA}  $T3/sherpa.zip" | shasum -a 256 -c - || { echo "❌ sherpa-onnx SHA256 不匹配"; rm -rf "$T3"; exit 1; }
  unzip -q "$T3/sherpa.zip" -d "$T3/unpacked"
  mv "$T3/unpacked/sherpa-onnx.xcframework" "$DIR/sherpa-onnx-shared.xcframework"
  rm -rf "$T3"
fi

# --- FunASR SeACo framework ---
FUNASR_SHA="508f90e594d99a65a340efe4928eddb52780791dda176811bc0a309702ddd5c0"
if [ ! -d "$FUNASR_DIR/funasr.xcframework" ]; then
  mkdir -p "$FUNASR_DIR"; T2=$(mktemp -d)
  echo "下载 funasr 框架(~2.2MB)..."
  curl -fL --retry 5 -o "$T2/f.tar.gz" "${FRAMEWORK_BASE_URL}/funasr-xcframework-macos.tar.gz"
  echo "${FUNASR_SHA}  $T2/f.tar.gz" | shasum -a 256 -c - || { echo "❌ funasr SHA 不匹配"; rm -rf "$T2"; exit 1; }
  tar xzf "$T2/f.tar.gz" -C "$FUNASR_DIR"; rm -rf "$T2"
  echo "✅ funasr.xcframework ready"
fi

echo "✅ frameworks ready in $DIR(可以 xcodebuild 了)"
