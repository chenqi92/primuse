# FFmpeg audio runtime

Primuse uses the dynamic FFmpeg libraries `libavformat`, `libavcodec`,
`libavutil`, and `libswresample` as its broad-format fallback decoder.

- Version: FFmpeg 8.1 (`n8.1`)
- Commit: `9047fa1b084f76b1b4d065af2d743df1b40dfb56`
- Upstream: <https://git.ffmpeg.org/ffmpeg.git>
- License: GNU Lesser General Public License 2.1 or later
- Build script: `scripts/build-ffmpeg-apple.sh`
- Decoder smoke test: `scripts/smoke-test-ffmpeg-bridge.sh`

The build disables GPL and non-free code, encoders, muxers, filters, devices,
the FFmpeg network stack, and video decoders. It keeps all native audio
decoders and demuxers and produces dynamic XCFrameworks for iOS and macOS.

The exact unmodified source corresponding to the shipped binaries is
available from the upstream repository at the commit above. Release builds
must also publish a source archive and this build script alongside the app's
download page to satisfy the FFmpeg LGPL checklist.
