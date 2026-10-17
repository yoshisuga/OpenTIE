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
# TIE_VERSION names a release build; local builds show the git checkout.
export DEVKITPRO="${DEVKITPRO:-/opt/devkitpro}"
toolchain="${DEVKITPRO}/cmake/3DS.cmake"
jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

mkdir -p "${sources}" "${prefix}"

# SDL is patched (packaging/3ds/*.patch) and rebuilt, in a fresh source tree,
# whenever the patches change.
sdl_patches=("${repo_root}"/packaging/3ds/sdl-*.patch)
sdl_stamp="${sdl_version}-$(cat "${sdl_patches[@]}" | sha256sum | cut -c1-12)"
sdl_source="${sources}/SDL3-${sdl_stamp}"
if [[ ! -f "${prefix}/lib/libSDL3.a" || "$(cat "${prefix}/.sdl-stamp" 2>/dev/null)" != "${sdl_stamp}" ]]; then
    if [[ ! -d "${sdl_source}" ]]; then
        mkdir -p "${sdl_source}"
        curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${sdl_version}/SDL3-${sdl_version}.tar.gz" |
            tar -xz -C "${sdl_source}" --strip-components=1
        for sdl_patch in "${sdl_patches[@]}"; do
            patch -d "${sdl_source}" -p1 < "${sdl_patch}"
        done
    fi
    cmake -S "${sdl_source}" -B "${sdl_source}/build-3ds" \
        -DCMAKE_TOOLCHAIN_FILE="${toolchain}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${prefix}" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
    cmake --build "${sdl_source}/build-3ds" -j "${jobs}"
    cmake --install "${sdl_source}/build-3ds"
    echo "${sdl_stamp}" > "${prefix}/.sdl-stamp"
fi

cmake -S "${repo_root}" -B "${build_root}/opentie" \
    -DCMAKE_TOOLCHAIN_FILE="${repo_root}/cmake/toolchains/3ds.cmake" \
    -DTIE_3DS_PREFIX="${prefix}" \
    -DTIE_VERSION="${TIE_VERSION:-0.0.0-dev}" \
    -DCMAKE_BUILD_TYPE="${build_type}"
cmake --build "${build_root}/opentie" -j "${jobs}"

echo "Built ${build_root}/opentie/src/tie_3ds/OpenTIE.3dsx"
