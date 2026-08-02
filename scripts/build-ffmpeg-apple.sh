#!/usr/bin/env bash

set -euo pipefail

# Reproducible LGPL-only FFmpeg build for Primuse.
#
# The generated dynamic XCFrameworks contain every native FFmpeg audio
# decoder and all demuxers, but no encoders, muxers, network stack, filters,
# capture devices, or GPL/non-free components.

readonly FFMPEG_TAG="n8.1"
readonly FFMPEG_COMMIT="9047fa1b084f76b1b4d065af2d743df1b40dfb56"
readonly REPOSITORY_URL="https://git.ffmpeg.org/ffmpeg.git"
readonly BUILD_CONFIGURATION_ID="${FFMPEG_COMMIT}-dwarf-v1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_ROOT="${FFMPEG_BUILD_ROOT:-/private/tmp/primuse-ffmpeg-apple}"
SOURCE_DIR="${FFMPEG_SOURCE_DIR:-${BUILD_ROOT}/source}"
OUTPUT_DIR="${FFMPEG_OUTPUT_DIR:-${PROJECT_DIR}/Frameworks/FFmpeg}"
JOBS="${FFMPEG_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"

readonly LIBRARIES=(libavutil libswresample libavcodec libavformat)

# This is the intersection of FFmpeg 8.1's native audio decoder registry and
# the audio codecs reported by `ffmpeg -decoders`, plus the few public names
# whose configure component name differs. Decoder dependencies may enable a
# small number of parsers, but never a video decoder.
readonly AUDIO_DECODERS=(
  aac aac_fixed aac_latm ac3 ac3_fixed acelp_kelvin
  adpcm_4xm adpcm_adx adpcm_afc adpcm_agm adpcm_aica adpcm_argo adpcm_ct
  adpcm_dtk adpcm_ea adpcm_ea_maxis_xa adpcm_ea_r1 adpcm_ea_r2 adpcm_ea_r3
  adpcm_ea_xas adpcm_g722 adpcm_g726 adpcm_g726le adpcm_ima_acorn
  adpcm_ima_alp adpcm_ima_amv adpcm_ima_apc adpcm_ima_apm
  adpcm_ima_cunning adpcm_ima_dat4 adpcm_ima_dk3 adpcm_ima_dk4
  adpcm_ima_ea_eacs adpcm_ima_ea_sead adpcm_ima_iss adpcm_ima_moflex
  adpcm_ima_mtf adpcm_ima_oki adpcm_ima_qt adpcm_ima_rad
  adpcm_ima_smjpeg adpcm_ima_ssi adpcm_ima_wav adpcm_ima_ws
  adpcm_ima_xbox adpcm_ms adpcm_mtaf adpcm_psx adpcm_sanyo adpcm_sbpro_2
  adpcm_sbpro_3 adpcm_sbpro_4 adpcm_swf adpcm_thp adpcm_thp_le adpcm_vima
  adpcm_xa adpcm_xmd adpcm_yamaha adpcm_zork alac als amrnb amrwb anull
  apac ape aptx aptx_hd atrac1 atrac3 atrac3al atrac3p atrac3pal atrac9
  binkaudio_dct binkaudio_rdft bmv_audio bonk cbd2_dpcm comfortnoise cook
  dca derf_dpcm dfpwm dolby_e dsd_lsbf dsd_lsbf_planar dsd_msbf
  dsd_msbf_planar dsicinaudio dss_sp dst dvaudio eac3 evrc fastaudio flac
  ffwavesynth ftr g723_1 g728 g729 gremlin_dpcm gsm gsm_ms hca hcom iac
  ilbc imc interplay_acm interplay_dpcm mace3 mace6 metasound misc4 mlp
  mp1 mp1float mp2 mp2float mp3 mp3adu mp3adufloat mp3float mp3on4
  mp3on4float mpc7 mpc8 msnsiren nellymoser on2avc opus osq paf_audio
  pcm_alaw pcm_bluray pcm_dvd pcm_f16le pcm_f24le pcm_f32be pcm_f32le
  pcm_f64be pcm_f64le pcm_lxf pcm_mulaw pcm_s16be pcm_s16be_planar
  pcm_s16le pcm_s16le_planar pcm_s24be pcm_s24daud pcm_s24le
  pcm_s24le_planar pcm_s32be pcm_s32le pcm_s32le_planar pcm_s64be
  pcm_s64le pcm_s8 pcm_s8_planar pcm_sga pcm_u16be pcm_u16le pcm_u24be
  pcm_u24le pcm_u32be pcm_u32le pcm_u8 pcm_vidc qcelp qdm2 qdmc qoa
  ra_144 ra_288 ralf rka roq_dpcm s302m sbc sdx2_dpcm shorten sipr siren
  smackaud sol_dpcm sonic speex tak truehd truespeech tta twinvq vmdaudio
  vorbis wady_dpcm wavarc wavpack wmalossless wmapro wmav1 wmav2 wmavoice
  ws_snd1 xan_dpcm xma1 xma2
)

readonly AUDIO_PARSERS=(
  aac aac_latm ac3 adx amr cook dca dolby_e dvaudio flac ftr g723_1 g729
  gsm misc4 mlp mpegaudio opus sbc sipr tak vorbis xma
)

join_by_comma() {
  local IFS=,
  printf '%s' "$*"
}

checkout_source() {
  if [[ ! -d "${SOURCE_DIR}/.git" ]]; then
    mkdir -p "$(dirname "${SOURCE_DIR}")"
    git clone --depth 1 --branch "${FFMPEG_TAG}" "${REPOSITORY_URL}" "${SOURCE_DIR}"
  fi

  local actual
  actual="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
  if [[ "${actual}" != "${FFMPEG_COMMIT}" ]]; then
    echo "FFmpeg source mismatch: expected ${FFMPEG_COMMIT}, got ${actual}" >&2
    exit 1
  fi
}

configure_and_build() {
  local variant="$1"
  local sdk="$2"
  local arch="$3"
  local minimum_flag="$4"
  local build_dir="${BUILD_ROOT}/build/${variant}"
  local stage_dir="${BUILD_ROOT}/stage/${variant}"
  local build_configuration_file="${stage_dir}/.primuse-build-configuration"
  local sdk_path
  local compiler
  local host_compiler
  local host_sdk_path
  local extra_cross_flags=()
  local configure_args=()

  sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  compiler="$(xcrun --sdk "${sdk}" --find clang)"
  host_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
  host_compiler="$(xcrun --sdk macosx --find clang)"
  if [[ "${sdk}" != "macosx" || "${arch}" != "$(uname -m)" ]]; then
    extra_cross_flags+=(--enable-cross-compile)
  fi

  if [[ "${FFMPEG_REUSE_BUILDS:-0}" == "1" \
    && -f "${stage_dir}/lib/libavformat.dylib" \
    && -f "${build_configuration_file}" \
    && "$(<"${build_configuration_file}")" == "${BUILD_CONFIGURATION_ID}" ]]; then
    echo "Reusing completed FFmpeg build: ${variant}"
    return
  fi

  rm -rf "${build_dir}" "${stage_dir}"
  mkdir -p "${build_dir}" "${stage_dir}"

  configure_args=(
    --prefix="${stage_dir}"
    --target-os=darwin
    --arch="${arch}"
    --cc="${compiler}"
    --host-cc="${host_compiler}"
    --host-cflags="-isysroot ${host_sdk_path}"
    --host-ldflags="-isysroot ${host_sdk_path}"
    --sysroot="${sdk_path}"
    --extra-cflags="-arch ${arch} ${minimum_flag}"
    --extra-ldflags="-arch ${arch} ${minimum_flag}"
    --install-name-dir=@rpath
    --enable-shared
    --disable-static
    --enable-pic
    --disable-programs
    --disable-doc
    --enable-debug=2
    --disable-stripping
    --disable-avdevice
    --disable-avfilter
    --disable-swscale
    --disable-encoders
    --disable-muxers
    --disable-filters
    --disable-devices
    --disable-hwaccels
    --disable-videotoolbox
    --disable-audiotoolbox
    --disable-network
    --disable-autodetect
    --enable-zlib
    --disable-gpl
    --disable-nonfree
    --disable-decoders
    --enable-decoder="$(join_by_comma "${AUDIO_DECODERS[@]}")"
    --disable-parsers
    --enable-parser="$(join_by_comma "${AUDIO_PARSERS[@]}")"
    --disable-bsfs
    --disable-protocols
    --enable-protocol=file,pipe
  )
  if ((${#extra_cross_flags[@]})); then
    configure_args+=("${extra_cross_flags[@]}")
  fi
  # Keep the legacy Intel slice reproducible on clean Xcode installations,
  # which no longer include NASM. Apple Silicon builds retain NEON assembly.
  if [[ "${arch}" == "x86_64" ]]; then
    configure_args+=(--disable-x86asm)
  fi

  (
    cd "${build_dir}"
    "${SOURCE_DIR}/configure" "${configure_args[@]}"
    make -j"${JOBS}" install
  )
  printf '%s\n' "${BUILD_CONFIGURATION_ID}" > "${build_configuration_file}"
}

library_binary() {
  local stage_dir="$1"
  local library="$2"
  realpath "${stage_dir}/lib/${library}.dylib"
}

create_framework() {
  local variant="$1"
  local platform="$2"
  local library="$3"
  local stage_dir="${BUILD_ROOT}/stage/${variant}"
  local framework_root="${BUILD_ROOT}/frameworks/${variant}/${library}.framework"
  local binary
  local headers_dir
  local modules_dir
  local plist_path
  local dependency
  local old_dependency
  local minimum_version

  if [[ "${platform}" == "MacOSX" ]]; then
    minimum_version="14.0"
  else
    minimum_version="18.0"
  fi

  rm -rf "${framework_root}"
  if [[ "${platform}" == "MacOSX" ]]; then
    binary="${framework_root}/Versions/A/${library}"
    headers_dir="${framework_root}/Versions/A/Headers"
    modules_dir="${framework_root}/Versions/A/Modules"
    plist_path="${framework_root}/Versions/A/Resources/Info.plist"
    mkdir -p "${headers_dir}" "${modules_dir}" "$(dirname "${plist_path}")"
    ln -s A "${framework_root}/Versions/Current"
    ln -s "Versions/Current/${library}" "${framework_root}/${library}"
    ln -s Versions/Current/Headers "${framework_root}/Headers"
    ln -s Versions/Current/Modules "${framework_root}/Modules"
    ln -s Versions/Current/Resources "${framework_root}/Resources"
  else
    binary="${framework_root}/${library}"
    headers_dir="${framework_root}/Headers"
    modules_dir="${framework_root}/Modules"
    plist_path="${framework_root}/Info.plist"
    mkdir -p "${headers_dir}" "${modules_dir}"
  fi
  cp "$(library_binary "${stage_dir}" "${library}")" "${binary}"
  cp -R "${stage_dir}/include/${library}/." "${headers_dir}/"

  install_name_tool -id "@rpath/${library}.framework/${library}" "${binary}"
  for dependency in "${LIBRARIES[@]}"; do
    [[ "${dependency}" == "${library}" ]] && continue
    old_dependency="$(otool -L "${binary}" | awk -v name="${dependency}" \
      '$1 ~ ("^@rpath/" name "\\.[0-9]+\\.dylib$") { print $1; exit }')"
    if [[ -n "${old_dependency}" ]]; then
      install_name_tool -change \
        "${old_dependency}" \
        "@rpath/${dependency}.framework/${dependency}" \
        "${binary}"
    fi
  done

  printf 'framework module %s {\n  umbrella header "%s.h"\n  export *\n  module * { export * }\n}\n' \
    "${library}" "${library#lib}" > "${modules_dir}/module.modulemap"

  plutil -create xml1 "${plist_path}"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.welape.primuse.ffmpeg.${library}" "${plist_path}"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${library}" "${plist_path}"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${library}" "${plist_path}"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string FMWK" "${plist_path}"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 8.1" "${plist_path}"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "${plist_path}"
  /usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string ${minimum_version}" "${plist_path}"
  /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "${plist_path}"
  /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string ${platform}" "${plist_path}"
}

merge_frameworks() {
  local arm_variant="$1"
  local intel_variant="$2"
  local universal_variant="$3"
  local library="$4"
  local arm_framework="${BUILD_ROOT}/frameworks/${arm_variant}/${library}.framework"
  local intel_framework="${BUILD_ROOT}/frameworks/${intel_variant}/${library}.framework"
  local universal_framework="${BUILD_ROOT}/frameworks/${universal_variant}/${library}.framework"
  local binary_path="${library}"

  if [[ "${universal_variant}" == macos-* ]]; then
    binary_path="Versions/A/${library}"
  fi

  rm -rf "${universal_framework}"
  mkdir -p "$(dirname "${universal_framework}")"
  cp -R "${arm_framework}" "${universal_framework}"
  lipo -create \
    "${arm_framework}/${binary_path}" \
    "${intel_framework}/${binary_path}" \
    -output "${universal_framework}/${binary_path}"
}

framework_binary_path() {
  local variant="$1"
  local library="$2"
  local framework_root="${BUILD_ROOT}/frameworks/${variant}/${library}.framework"

  if [[ "${variant}" == macos-* ]]; then
    printf '%s\n' "${framework_root}/Versions/A/${library}"
  else
    printf '%s\n' "${framework_root}/${library}"
  fi
}

create_dsym() {
  local variant="$1"
  local library="$2"
  local binary
  local dsym="${BUILD_ROOT}/dSYMs/${variant}/${library}.framework.dSYM"

  binary="$(framework_binary_path "${variant}" "${library}")"
  rm -rf "${dsym}"
  mkdir -p "$(dirname "${dsym}")"
  xcrun dsymutil --verify-dwarf=output "${binary}" -o "${dsym}"
  xcrun strip -x "${binary}"
}

package_xcframeworks() {
  local library
  rm -rf "${OUTPUT_DIR}"
  mkdir -p "${OUTPUT_DIR}"

  for library in "${LIBRARIES[@]}"; do
    create_framework ios-arm64 iPhoneOS "${library}"
    create_framework ios-simulator-arm64 iPhoneSimulator "${library}"
    create_framework ios-simulator-x86_64 iPhoneSimulator "${library}"
    create_framework macos-arm64 MacOSX "${library}"
    create_framework macos-x86_64 MacOSX "${library}"
    merge_frameworks \
      ios-simulator-arm64 ios-simulator-x86_64 ios-simulator-universal "${library}"
    merge_frameworks macos-arm64 macos-x86_64 macos-universal "${library}"

    create_dsym ios-arm64 "${library}"
    create_dsym ios-simulator-universal "${library}"
    create_dsym macos-universal "${library}"

    xcodebuild -create-xcframework \
      -framework "${BUILD_ROOT}/frameworks/ios-arm64/${library}.framework" \
      -debug-symbols "${BUILD_ROOT}/dSYMs/ios-arm64/${library}.framework.dSYM" \
      -framework "${BUILD_ROOT}/frameworks/ios-simulator-universal/${library}.framework" \
      -debug-symbols "${BUILD_ROOT}/dSYMs/ios-simulator-universal/${library}.framework.dSYM" \
      -framework "${BUILD_ROOT}/frameworks/macos-universal/${library}.framework" \
      -debug-symbols "${BUILD_ROOT}/dSYMs/macos-universal/${library}.framework.dSYM" \
      -output "${OUTPUT_DIR}/${library}.xcframework"
  done
}

main() {
  checkout_source
  configure_and_build ios-arm64 iphoneos arm64 -miphoneos-version-min=18.0
  configure_and_build ios-simulator-arm64 iphonesimulator arm64 -mios-simulator-version-min=18.0
  configure_and_build ios-simulator-x86_64 iphonesimulator x86_64 -mios-simulator-version-min=18.0
  configure_and_build macos-arm64 macosx arm64 -mmacosx-version-min=14.0
  configure_and_build macos-x86_64 macosx x86_64 -mmacosx-version-min=14.0
  package_xcframeworks
  cp "${SOURCE_DIR}/COPYING.LGPLv2.1" \
    "${PROJECT_DIR}/Primuse/ThirdParty/FFmpeg/COPYING.LGPLv2.1"
  cp "${SOURCE_DIR}/COPYING.LGPLv2.1" \
    "${PROJECT_DIR}/Primuse/Resources/FFmpeg-LGPL-2.1.txt"
  echo "FFmpeg XCFrameworks written to ${OUTPUT_DIR}"
}

main "$@"
