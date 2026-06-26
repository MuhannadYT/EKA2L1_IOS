#!/bin/bash
# Cross-compile FFmpeg for a physical iOS device (arm64) for EKA2L1.
# Output: macos/arm64-device/lib/*.a  (consumed by ffmpeg/CMakeLists.txt)
set -e

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
MINVER=15.0
ARCH=arm64
PREFIX="$(pwd)/macos/arm64-device"

CC="$(xcrun --sdk iphoneos -f clang)"

echo "SDK=$SDK"
echo "PREFIX=$PREFIX"

make distclean >/dev/null 2>&1 || true

./configure \
    --prefix="${PREFIX}" \
    --disable-everything \
    --enable-cross-compile \
    --enable-pic \
    --disable-shared \
    --enable-static \
    --disable-asm \
    --disable-avdevice \
    --disable-filters \
    --disable-programs \
    --disable-network \
    --disable-avfilter \
    --disable-postproc \
    --disable-encoders \
    --disable-doc \
    --disable-ffplay \
    --disable-ffprobe \
    --disable-ffmpeg \
    --disable-audiotoolbox \
    --disable-videotoolbox \
    --enable-decoder=h264 \
    --enable-decoder=mpeg4 \
    --enable-decoder=h263 \
    --enable-decoder=h263p \
    --enable-decoder=mpeg2video \
    --enable-decoder=mjpeg \
    --enable-decoder=mjpegb \
    --enable-decoder=aac \
    --enable-decoder=aac_latm \
    --enable-decoder=wavpack \
    --enable-decoder=amrnb \
    --enable-decoder=amrwb \
    --enable-decoder=mp3 \
    --enable-decoder=pcm_s16le \
    --enable-decoder=pcm_s8 \
    --enable-demuxer=h264 \
    --enable-demuxer=m4v \
    --enable-demuxer=mp3 \
    --enable-demuxer=mov \
    --enable-demuxer=mpegvideo \
    --enable-demuxer=mpegps \
    --enable-demuxer=mjpeg \
    --enable-demuxer=avi \
    --enable-demuxer=aac \
    --enable-demuxer=pcm_s16le \
    --enable-demuxer=pcm_s8 \
    --enable-demuxer=wav \
    --enable-demuxer=amr \
    --enable-encoder=pcm_s16le \
    --enable-muxer=amr \
    --enable-muxer=avi \
    --enable-muxer=mp3 \
    --enable-muxer=wav \
    --enable-muxer=pcm_s16le \
    --enable-muxer=pcm_s8 \
    --enable-muxer=ogg \
    --enable-parser=h264 \
    --enable-parser=mpeg4video \
    --enable-parser=mpegvideo \
    --enable-parser=aac \
    --enable-parser=aac_latm \
    --enable-parser=mpegaudio \
    --enable-protocol=file \
    --target-os=darwin \
    --arch=aarch64 \
    --cc="${CC}" \
    --as="${CC}" \
    --sysroot="${SDK}" \
    --extra-cflags="-arch ${ARCH} -isysroot ${SDK} -mios-version-min=${MINVER} -fembed-bitcode=off" \
    --extra-ldflags="-arch ${ARCH} -isysroot ${SDK} -mios-version-min=${MINVER}"

make clean
make -j"$(sysctl -n hw.physicalcpu)"
make install
echo "==== FFmpeg iOS simulator build complete ===="
ls -la "${PREFIX}/lib"
