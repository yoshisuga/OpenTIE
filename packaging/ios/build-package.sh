#!/bin/bash
# Builds OpenTIE.app for an iPhone or iPad, or for the iOS Simulator.
#
#   packaging/ios/build-package.sh device     # build/ios/device/OpenTIE.app
#   packaging/ios/build-package.sh simulator  # build/ios/simulator/OpenTIE.app
#
# Dependencies (SDL3, zstd, SpeexDSP, FFmpeg) are cloned at pinned versions
# and built for the slice under build/ios/<slice>. The shader compilers run on
# this Mac and are built once under build/ios/host.
#
# A device build is signed with IOS_CODESIGN_IDENTITY and embeds
# IOS_PROVISIONING_PROFILE when they are set; see packaging/ios/README.md.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

slice="${1:-simulator}"
case "${slice}" in
    device) sdk=iphoneos; min_flag=-miphoneos-version-min ;;
    simulator | sim) slice=simulator; sdk=iphonesimulator; min_flag=-mios-simulator-version-min ;;
    *) echo "usage: $0 device|simulator" >&2; exit 2 ;;
esac

sdl_version="${SDL_VERSION:-3.4.14}"
zstd_version="${ZSTD_VERSION:-1.5.7}"
ffmpeg_version="${FFMPEG_VERSION:-8.0.1}"
speexdsp_version="${SPEEXDSP_VERSION:-1.2.1}"
shadercross_commit="${SHADERCROSS_COMMIT:-6b06e55c7c5d7e7a09a8a14f76e866dcfad5ab99}"
deployment_target="${TIE_IOS_DEPLOYMENT_TARGET:-16.0}"
application_version="${TIE_VERSION:-0.0.0-dev}"
build_version="${TIE_IOS_BUILD_VERSION:-1}"
build_type="${TIE_BUILD_TYPE:-Release}"
bundle_identifier="${IOS_BUNDLE_ID:-org.totallyopen.opentie}"
sign_identity="${IOS_CODESIGN_IDENTITY:--}"
provisioning_profile="${IOS_PROVISIONING_PROFILE:-}"

work_root="${TIE_IOS_BUILD_ROOT:-${repo_root}/build/ios}"
source_root="${work_root}/sources"
host_root="${work_root}/host"
host_prefix="${host_root}/prefix"
slice_root="${work_root}/${slice}"
prefix="${slice_root}/prefix"
toolchain="${repo_root}/cmake/toolchains/ios-${slice}.cmake"
application="${slice_root}/OpenTIE.app"
jobs="$(sysctl -n hw.logicalcpu)"

sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
cc="$(xcrun --sdk "${sdk}" --find clang)"
target_cflags="-arch arm64 -isysroot ${sdk_path} ${min_flag}=${deployment_target}"

clone_tag() {
    local repository="$1" tag="$2" destination="$3"
    if [[ ! -d "${destination}/.git" ]]; then
        git clone --branch "${tag}" --depth 1 "${repository}" "${destination}"
    fi
}

apply_patch() {
    local checkout="$1" patch="$2"
    if git -C "${checkout}" apply --check "${patch}" >/dev/null 2>&1; then
        git -C "${checkout}" apply "${patch}"
    elif ! git -C "${checkout}" apply --reverse --check "${patch}" >/dev/null 2>&1; then
        echo "$(basename "${patch}") cannot be applied cleanly" >&2
        exit 1
    fi
}

prepare_shadercross() {
    local destination="${source_root}/SDL_shadercross"
    local patch="${repo_root}/packaging/common/shadercross-fsr3.patch"
    if [[ ! -d "${destination}/.git" ]]; then
        git clone https://github.com/libsdl-org/SDL_shadercross.git "${destination}"
        git -C "${destination}" checkout "${shadercross_commit}"
    fi
    apply_patch "${destination}" "${patch}"
    git -C "${destination}" submodule update --init --recursive
}

# Host tools: SDL3 for the Mac, SDL_shadercross, and Aeron's FSR shader
# generator. Their output (MSL source) is the same for device and simulator.
build_host_tools() {
    if [[ ! -f "${host_prefix}/lib/cmake/SDL3/SDL3Config.cmake" ]]; then
        cmake -S "${source_root}/SDL-${sdl_version}" -B "${host_root}/sdl" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release "-DCMAKE_INSTALL_PREFIX=${host_prefix}" \
            -DSDL_HIDAPI_LIBUSB=OFF -DSDL_INSTALL_DOCS=OFF -DSDL_SHARED=ON -DSDL_STATIC=OFF \
            -DSDL_TESTS=OFF
        cmake --build "${host_root}/sdl" --parallel "${jobs}"
        cmake --install "${host_root}/sdl"
    fi

    prepare_shadercross
    cmake -S "${source_root}/SDL_shadercross" -B "${host_root}/shadercross" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release "-DCMAKE_PREFIX_PATH=${host_prefix}" \
        -DLLVM_APPEND_VC_REV=OFF -DSDLSHADERCROSS_CLI=ON -DSDLSHADERCROSS_DXC=ON \
        -DSDLSHADERCROSS_INSTALL=OFF -DSDLSHADERCROSS_SHARED=ON \
        -DSDLSHADERCROSS_SPIRVCROSS_SHARED=ON -DSDLSHADERCROSS_STATIC=OFF \
        -DSDLSHADERCROSS_VENDORED=ON
    cmake --build "${host_root}/shadercross" --parallel "${jobs}"

    cmake -S "${repo_root}/aeron" -B "${host_root}/aeron-tools" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release "-DCMAKE_PREFIX_PATH=${host_prefix}" \
        -DAERON_HOST_TOOLS_ONLY=ON
    cmake --build "${host_root}/aeron-tools" --target aeron_fsr3_shadergen --parallel "${jobs}"
}

build_dependencies() {
    local common_cmake=(
        -G Ninja
        -DCMAKE_BUILD_TYPE=Release
        "--toolchain=${toolchain}"
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=${deployment_target}"
        "-DCMAKE_INSTALL_PREFIX=${prefix}"
    )

    # SDL carries a patch, so it is rebuilt (incrementally) every time.
    cmake -S "${source_root}/SDL-${sdl_version}" -B "${slice_root}/sdl" "${common_cmake[@]}" \
        -DSDL_INSTALL_DOCS=OFF -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF
    cmake --build "${slice_root}/sdl" --parallel "${jobs}"
    cmake --install "${slice_root}/sdl"

    if [[ ! -f "${prefix}/lib/libzstd.a" ]]; then
        cmake -S "${source_root}/zstd-${zstd_version}/build/cmake" -B "${slice_root}/zstd" \
            "${common_cmake[@]}" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF \
            -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_TESTS=OFF
        cmake --build "${slice_root}/zstd" --parallel "${jobs}"
        cmake --install "${slice_root}/zstd"
    fi

    if [[ ! -f "${prefix}/lib/libspeexdsp.a" ]]; then
        [[ -f "${source_root}/speexdsp-${speexdsp_version}/configure" ]] ||
            (cd "${source_root}/speexdsp-${speexdsp_version}" && ./autogen.sh)
        rm -rf "${slice_root}/speexdsp"
        mkdir -p "${slice_root}/speexdsp"
        (
            cd "${slice_root}/speexdsp"
            CC="${cc}" CFLAGS="${target_cflags} -O2" \
                "${source_root}/speexdsp-${speexdsp_version}/configure" \
                --host=aarch64-apple-darwin "--prefix=${prefix}" \
                --disable-shared --enable-static --disable-examples
            make -j"${jobs}"
            make install
        )
    fi

    if [[ ! -f "${prefix}/lib/libavformat.a" ]]; then
        rm -rf "${slice_root}/ffmpeg"
        mkdir -p "${slice_root}/ffmpeg"
        (
            cd "${slice_root}/ffmpeg"
            "${source_root}/FFmpeg-${ffmpeg_version}/configure" \
                "--prefix=${prefix}" \
                --enable-cross-compile --target-os=darwin --arch=arm64 \
                "--cc=${cc}" "--sysroot=${sdk_path}" \
                --disable-autodetect --disable-avdevice --disable-avfilter --disable-debug \
                --disable-doc --disable-everything --disable-network --disable-programs \
                --enable-static --disable-shared \
                --enable-decoder=vorbis --enable-demuxer=ogg --enable-pic --enable-pthreads \
                "--extra-cflags=${target_cflags}" "--extra-ldflags=${target_cflags}"
            make -j"${jobs}"
            make install
        )
        # CMake splits "-framework CoreVideo" into two arguments; the
        # application links these frameworks itself.
        sed -i '' -E 's/ -framework [A-Za-z]+//g' "${prefix}"/lib/pkgconfig/libav*.pc
    fi
}

build_application() {
    local debug_ui=OFF
    [[ "${build_type}" == Debug ]] && debug_ui=ON

    cmake -S "${repo_root}" -B "${slice_root}/tie-${build_type}" -G Ninja \
        "--toolchain=${toolchain}" \
        "-DTIE_IOS_PREFIX=${prefix}" \
        "-DCMAKE_BUILD_TYPE=${build_type}" \
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=${deployment_target}" \
        "-DAERON_SHADERCROSS_EXECUTABLE=${host_root}/shadercross/shadercross" \
        "-DAERON_FSR3_SHADERGEN_EXECUTABLE=${host_root}/aeron-tools/aeron_fsr3_shadergen" \
        -DAERON_SHADER_FORMATS=MSL \
        -DENABLE_ASAN=OFF \
        -DENABLE_FLUIDSYNTH=OFF \
        -DENABLE_NUKED_SC55=ON \
        -DTIE_BUILD_TOOLS=OFF \
        "-DTIE_ENABLE_DEBUG_UI=${debug_ui}" \
        "-DTIE_IOS_BUILD_VERSION=${build_version}" \
        "-DTIE_IOS_BUNDLE_IDENTIFIER=${bundle_identifier}" \
        "-DTIE_VERSION=${application_version}"
    cmake --build "${slice_root}/tie-${build_type}" --target tie --parallel "${jobs}"

    rm -rf "${application}"
    cp -R "${slice_root}/tie-${build_type}/OpenTIE.app" "${application}"
}

stage_application() {
    local frameworks="${application}/Frameworks"
    mkdir -p "${frameworks}"
    cp "${prefix}/lib/libSDL3.0.dylib" "${frameworks}/"

    local license_dir="${application}/licenses"
    mkdir -p "${license_dir}"
    cp "${repo_root}/src/landru/LICENSE" "${license_dir}/Landru-GPL-3.0.txt"
    cp "${repo_root}/src/imuse/LICENSE" "${license_dir}/iMUSE-GPL-3.0.txt"
    cp "${repo_root}/src/imuse/third_party/nuked-opl3-fast/LICENSE" \
        "${license_dir}/Nuked-OPL3-LGPL-2.1.txt"
    cp "${repo_root}/src/imuse/third_party/nuked-sc55/LICENSE" "${license_dir}/Nuked-SC55.txt"
    cp "${source_root}/SDL-${sdl_version}/LICENSE.txt" "${license_dir}/SDL3.txt"
    cp "${source_root}/zstd-${zstd_version}/LICENSE" "${license_dir}/zstd.txt"
    cp "${source_root}/FFmpeg-${ffmpeg_version}/COPYING.LGPLv2.1" "${license_dir}/FFmpeg-LGPL-2.1.txt"
    cp "${source_root}/speexdsp-${speexdsp_version}/COPYING" "${license_dir}/SpeexDSP-BSD-3-Clause.txt"
    cp "${repo_root}/aeron/third_party/bc7enc/LICENSE" "${license_dir}/bc7enc.txt"
    cp "${repo_root}/aeron/third_party/fidelityfx-fsr3/LICENSE.txt" "${license_dir}/FidelityFX-FSR3.txt"
    cp "${repo_root}/aeron/third_party/libyaml/License" "${license_dir}/libyaml.txt"
}

sign_application() {
    local entitlements=()
    if [[ -n "${provisioning_profile}" ]]; then
        cp "${provisioning_profile}" "${application}/embedded.mobileprovision"
        local profile="${slice_root}/profile.plist" plist="${slice_root}/entitlements.plist"
        security cms -D -i "${provisioning_profile}" > "${profile}"
        # A wildcard profile names "PREFIX.*"; the app needs its own identifier.
        local prefix team
        prefix="$(plutil -extract ApplicationIdentifierPrefix.0 raw "${profile}")"
        team="$(plutil -extract TeamIdentifier.0 raw "${profile}")"
        cat > "${plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>application-identifier</key><string>${prefix}.${bundle_identifier}</string>
    <key>com.apple.developer.team-identifier</key><string>${team}</string>
    <key>get-task-allow</key><true/>
</dict></plist>
PLIST
        entitlements=(--entitlements "${plist}")
    fi
    codesign --force --sign "${sign_identity}" --timestamp=none "${application}/Frameworks/libSDL3.0.dylib"
    codesign --force --sign "${sign_identity}" --timestamp=none \
        "${entitlements[@]+"${entitlements[@]}"}" "${application}"
}

main() {
    for command in cmake codesign git make ninja pkg-config xcrun; do
        command -v "${command}" >/dev/null || { echo "${command} is required" >&2; exit 1; }
    done
    mkdir -p "${source_root}" "${host_root}" "${slice_root}"

    clone_tag https://github.com/libsdl-org/SDL.git "release-${sdl_version}" \
        "${source_root}/SDL-${sdl_version}"
    apply_patch "${source_root}/SDL-${sdl_version}" "${script_dir}/sdl-gpu-simulator.patch"
    clone_tag https://github.com/facebook/zstd.git "v${zstd_version}" "${source_root}/zstd-${zstd_version}"
    clone_tag https://github.com/FFmpeg/FFmpeg.git "n${ffmpeg_version}" \
        "${source_root}/FFmpeg-${ffmpeg_version}"
    clone_tag https://github.com/xiph/speexdsp.git "SpeexDSP-${speexdsp_version}" \
        "${source_root}/speexdsp-${speexdsp_version}"

    build_host_tools
    build_dependencies
    build_application
    stage_application
    sign_application
    echo "Built ${application}"
}

main "$@"
