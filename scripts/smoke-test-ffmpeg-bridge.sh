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

python3 - "$SMOKE_DIR" <<'PY'
import struct
import sys
import wave
from pathlib import Path

root = Path(sys.argv[1])
with wave.open(str(root / "tone-pcm.wav"), "rb") as source:
    pcm = source.readframes(source.getnframes())

def write_carrier(name, payload):
    with wave.open(str(root / name), "wb") as output:
        output.setparams((2, 2, 44100, 0, "NONE", "not compressed"))
        output.writeframes(payload)

# Repeated sync words in ordinary samples must not force the DTS demuxer.
for index, marker in enumerate(("7ffe8001", "fe7f0180", "1fffe800", "ff1f00e8")):
    payload = bytearray(pcm)
    for offset in (128, 684, 4097, 4653):
        payload[offset:offset + 32] = bytes.fromhex(marker) + bytes(28)
    write_carrier(f"pcm-false-dts-{index}.wav", payload)

# DTS-CD can disguise either byte order and 16- or 14-bit packing as PCM.
raw = (root / "tone.dts").read_bytes()
packed = bytearray()
offset = 0
while offset < len(raw):
    assert raw[offset:offset + 4] == bytes.fromhex("7ffe8001")
    size = (((raw[offset + 5] & 3) << 12) | (raw[offset + 6] << 4) | (raw[offset + 7] >> 4)) + 1
    assert size >= 96 and offset + size <= len(raw)
    bits = ''.join(f'{byte:08b}' for byte in raw[offset:offset + size])
    for start in range(0, len(bits), 14):
        word = int(bits[start:start + 14].ljust(14, '0'), 2)
        packed.extend(struct.pack('>H', word | (0xC000 if word & 0x2000 else 0)))
    offset += size

for packing, payload in (("16", raw), ("14", bytes(packed))):
    write_carrier(f"dts-carrier-{packing}-be.wav", payload)
    swapped = bytearray(payload)
    swapped[0::2], swapped[1::2] = payload[1::2], payload[0::2]
    write_carrier(f"dts-carrier-{packing}-le.wav", swapped)
PY

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

# Containers only FFmpeg opens. `tagged-`/`covered-` prefixes tell the smoke
# binary to require the title tag (and cover) from the metadata probe.
SMOKE_TAGS=(-metadata "title=Smoke Title" -metadata artist=Smoke -metadata album=Fixtures)
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "color=c=red:s=64x64" -frames:v 1 "$SMOKE_DIR/cover.jpg"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=44100" \
  -ac 2 -c:a flac "${SMOKE_TAGS[@]}" \
  -attach "$SMOKE_DIR/cover.jpg" -metadata:s:t mimetype=image/jpeg -metadata:s:t filename=cover.jpg \
  "$SMOKE_DIR/covered-tone.mka"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=48000" \
  -ac 2 -c:a opus -strict -2 "${SMOKE_TAGS[@]}" "$SMOKE_DIR/tagged-tone.webm"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=48000" \
  -ac 2 -c:a mp2 "$SMOKE_DIR/tone.mp2"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=96000" \
  -ac 2 -c:a pcm_s24le -f w64 "$SMOKE_DIR/tone.w64"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=48000" \
  -ac 2 -c:a pcm_s16le -rf64 always "${SMOKE_TAGS[@]}" -f wav "$SMOKE_DIR/tagged-tone.rf64"
"$FFMPEG_BIN" -hide_banner -loglevel error \
  -f lavfi -i "sine=frequency=997:duration=1.5:sample_rate=48000" \
  -ac 2 -c:a ac3 "${SMOKE_TAGS[@]}" -f rm "$SMOKE_DIR/tagged-tone.ra"

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
  "$SMOKE_DIR"/pcm-false-dts-*.wav \
  "$SMOKE_DIR"/dts-carrier-*.wav \
  "$SMOKE_DIR/tone.wma" \
  "$SMOKE_DIR/tone.flac" \
  "$SMOKE_DIR/tone.aac" \
  "$SMOKE_DIR/tone.mlp" \
  "$SMOKE_DIR/tone.truehd" \
  "$SMOKE_DIR/covered-tone.mka" \
  "$SMOKE_DIR/tagged-tone.webm" \
  "$SMOKE_DIR/tone.mp2" \
  "$SMOKE_DIR/tone.w64" \
  "$SMOKE_DIR/tagged-tone.rf64" \
  "$SMOKE_DIR/tagged-tone.ra" \
  "$@"
