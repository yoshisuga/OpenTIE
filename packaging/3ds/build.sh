#!/usr/bin/env bash
# Builds OpenTIE.3dsx for the Nintendo 3DS.
#
# Requires devkitARM, libctru and 3ds-tools (DEVKITPRO, default /opt/devkitpro).
# SDL3 has no devkitPro package, so it is built from source into the prefix.
# Without a local devkitPro, run this script in the devkitpro/devkitarm image:
#
#   docker run --rm -v "$PWD":/src -w /src devkitpro/devkitarm packaging/3ds/build.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build_root="${BUILD_ROOT:-${repo_root}/build/3ds}"
prefix="${build_root}/prefix"
sources="${build_root}/sources"
sdl_version="${SDL_VERSION:-3.4.14}"
build_type="${BUILD_TYPE:-Release}"
export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
toolchain="${DEVKITPRO}/cmake/3DS.cmake"
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

mkdir -p "${sources}" "${prefix}"

if [[ ! -f "${prefix}/lib/libSDL3.a" ]]; then
    if [[ ! -d "${sources}/SDL3-${sdl_version}" ]]; then
        curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${sdl_version}/SDL3-${sdl_version}.tar.gz" |
            tar -xz -C "${sources}"
    fi
    cmake -S "${sources}/SDL3-${sdl_version}" -B "${sources}/SDL3-${sdl_version}/build-3ds" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${prefix}" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
    cmake --build "${sources}/SDL3-${sdl_version}/build-3ds" -j "${jobs}"
    cmake --install "${sources}/SDL3-${sdl_version}/build-3ds"
fi

cmake -S "${repo_root}" -B "${build_root}/opentie" \
    -DCMAKE_TOOLCHAIN_FILE="${repo_root}/cmake/toolchains/3ds.cmake" \
    -DTIE_3DS_PREFIX="${prefix}" \
    -DCMAKE_BUILD_TYPE="${build_type}"
cmake --build "${build_root}/opentie" -j "${jobs}"

echo "Built ${build_root}/opentie/src/tie_3ds/OpenTIE.3dsx"
