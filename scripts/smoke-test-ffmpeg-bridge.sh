#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FFMPEG_BIN="${FFMPEG_BIN:-$(command -v ffmpeg || true)}"
if [[ -z "$FFMPEG_BIN" ]]; then
  echo "ffmpeg CLI is required to generate smoke-test fixtures" >&2
  exit 69
fi

SMOKE_DIR="$(mktemp -d /tmp/primuse-ffmpeg-smoke.XXXXXX)"
cleanup() { rm -rf "$SMOKE_DIR"; }
trap cleanup EXIT

"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=48000" \
  -ac 2 -c:a dca -strict -2 "$SMOKE_DIR/tone.dts"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "aevalsrc=0|0|sin(2*PI*997*t)|0|0|0:s=48000:d=1.5:c=5.1(side)" \
  -c:a dca -strict -2 "$SMOKE_DIR/tone-5.1-center-only.dts"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -i "$SMOKE_DIR/tone.dts" -c:a copy -f wav "$SMOKE_DIR/tone-dts.wav"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=44100" \
  -ac 2 -c:a pcm_s16le "$SMOKE_DIR/tone-pcm.wav"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=44100" \
  -ac 2 -c:a wmav2 "$SMOKE_DIR/tone.wma"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=96000" \
  -ac 2 -c:a flac "$SMOKE_DIR/tone.flac"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=48000" \
  -ac 2 -c:a aac -f adts "$SMOKE_DIR/tone.aac"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=48000" \
  -ac 2 -c:a mlp -strict -2 "$SMOKE_DIR/tone.mlp"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=48000" \
  -ac 2 -c:a truehd -strict -2 -f truehd "$SMOKE_DIR/tone.truehd"

FRAMEWORK_ROOT="$ROOT_DIR/Frameworks/FFmpeg"
RUNTIME_DIR="$SMOKE_DIR/Frameworks"
mkdir -p "$RUNTIME_DIR"
for library in libavutil libswresample libavcodec libavformat; do
  source_framework="$FRAMEWORK_ROOT/$library.xcframework/macos-arm64_x86_64/$library.framework"
  ln -s "$source_framework" "$RUNTIME_DIR/$library.framework"
done

xcrun clang -fobjc-arc \
  -framework Foundation -framework AVFoundation \
  -F "$RUNTIME_DIR" \
  -framework libavformat -framework libavcodec -framework libswresample -framework libavutil \
  -Wl,-rpath,"$RUNTIME_DIR" \
  "$ROOT_DIR/scripts/FFmpegBridgeSmoke.m" \
  "$ROOT_DIR/Primuse/Services/Audio/FFmpegDecoderBridge.m" \
  -o "$SMOKE_DIR/ffmpeg-bridge-smoke"

xcrun clang -fobjc-arc -c \
  -F "$RUNTIME_DIR" \
  "$ROOT_DIR/Primuse/Services/Audio/FFmpegDecoderBridge.m" \
  -o "$SMOKE_DIR/FFmpegDecoderBridge.o"

xcrun swiftc -parse-as-library \
  -import-objc-header "$ROOT_DIR/scripts/FFmpegWorkerTimeoutSmoke-Bridging.h" \
  -module-cache-path "$SMOKE_DIR/ModuleCache" \
  -F "$RUNTIME_DIR" \
  -framework AVFoundation -framework Foundation \
  -framework libavformat -framework libavcodec -framework libswresample -framework libavutil \
  -Xlinker -rpath -Xlinker "$RUNTIME_DIR" \
  "$ROOT_DIR/Primuse/Services/Audio/AudioDecoderProtocol.swift" \
  "$ROOT_DIR/Primuse/Services/Audio/FFmpegAudioDecoder.swift" \
  "$ROOT_DIR/scripts/FFmpegWorkerTimeoutSmoke.swift" \
  "$SMOKE_DIR/FFmpegDecoderBridge.o" \
  -o "$SMOKE_DIR/ffmpeg-worker-timeout-smoke"

mkfifo "$SMOKE_DIR/stalled.dts"
mkfifo "$SMOKE_DIR/cancelled.dts"
mkfifo "$SMOKE_DIR/stalled-probe.wav"
mkfifo "$SMOKE_DIR/queued-a.dts"
mkfifo "$SMOKE_DIR/queued-b.dts"
"$SMOKE_DIR/ffmpeg-worker-timeout-smoke" \
  "$SMOKE_DIR/stalled.dts" \
  "$SMOKE_DIR/cancelled.dts" \
  "$SMOKE_DIR/stalled-probe.wav" \
  "$SMOKE_DIR/queued-a.dts" \
  "$SMOKE_DIR/queued-b.dts" \
  "$SMOKE_DIR/tone.dts"

"$SMOKE_DIR/ffmpeg-bridge-smoke" \
  "$SMOKE_DIR/tone.dts" \
  "$SMOKE_DIR/tone-5.1-center-only.dts" \
  "$SMOKE_DIR/tone-dts.wav" \
  "$SMOKE_DIR/tone-pcm.wav" \
  "$SMOKE_DIR/tone.wma" \
  "$SMOKE_DIR/tone.flac" \
  "$SMOKE_DIR/tone.aac" \
  "$SMOKE_DIR/tone.mlp" \
  "$SMOKE_DIR/tone.truehd" \
  "$@"
