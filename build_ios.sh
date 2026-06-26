#!/bin/bash
#
# Build, install and launch the EKA2L1 iOS port on the iOS Simulator.
#
# Usage:
#   ./build_ios.sh            # configure + build + install + launch on a booted simulator
#   ./build_ios.sh build      # configure + build only
#   ./build_ios.sh run        # install + launch only (assumes already built)
#
# Requirements: Xcode (full), an iOS Simulator runtime. CMake 3.x is fetched/cached
# automatically (CMake 4.x cannot configure several of EKA2L1's older submodules).
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${ROOT}/build-ios"
BUNDLE_ID="com.eka2l1.emulator"
APP="${BUILD_DIR}/src/emu/ios/eka2l1.app"

# --- Toolchain -------------------------------------------------------------
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

CACHE="${HOME}/Library/Caches/eka2l1-ios"
CMAKE="${CACHE}/cmake-3.31.6-macos-universal/CMake.app/Contents/bin/cmake"
if [ ! -x "${CMAKE}" ]; then
    echo "Fetching CMake 3.31.6 (one-time)…"
    mkdir -p "${CACHE}"
    curl -fsSL -o "${CACHE}/cmake.tar.gz" \
        https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-macos-universal.tar.gz
    tar xzf "${CACHE}/cmake.tar.gz" -C "${CACHE}"
fi

# --- FFmpeg (prebuilt for the iOS simulator) -------------------------------
if [ ! -f "${ROOT}/src/external/ffmpeg/macos/arm64-simulator/lib/libavcodec.a" ]; then
    echo "Cross-compiling FFmpeg for the iOS simulator (one-time)…"
    ( cd "${ROOT}/src/external/ffmpeg" && ./build-ios-sim.sh )
fi

configure() {
    "${CMAKE}" -S "${ROOT}" -B "${BUILD_DIR}" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT=iphonesimulator \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo
}

build() {
    [ -f "${BUILD_DIR}/build.ninja" ] || configure
    "${CMAKE}" --build "${BUILD_DIR}" --target eka2l1 -j"$(sysctl -n hw.logicalcpu)"
    # The simulator requires at least an ad-hoc signature.
    codesign --force --sign - "${APP}"
}

run() {
    # Boot the first available iPhone simulator if none is booted.
    if ! xcrun simctl list devices booted | grep -q Booted; then
        UDID=$(xcrun simctl list devices available | grep -m1 "iPhone" | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
        echo "Booting simulator ${UDID}…"
        xcrun simctl boot "${UDID}"
        open -a Simulator
        xcrun simctl bootstatus "${UDID}" -b
    fi
    xcrun simctl install booted "${APP}"
    xcrun simctl launch booted "${BUNDLE_ID}"
    echo "Launched EKA2L1 (${BUNDLE_ID}) on the booted simulator."
}

case "${1:-all}" in
    build) build ;;
    run)   run ;;
    all)   build; run ;;
    *)     echo "usage: $0 [build|run|all]"; exit 1 ;;
esac
