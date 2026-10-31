#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${OHOS_NDK:-/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native}"

# 目标架构。默认 arm64-v8a 与历史行为完全一致；仅当宿主机是 x86_64 模拟器
# （Windows 版 DevEco 只提供 x86 镜像）时才需要 OHOS_ARCH=x86_64。
OHOS_ARCH="${OHOS_ARCH:-arm64-v8a}"
case "$OHOS_ARCH" in
  arm64-v8a)
    SYSROOT_LIB="aarch64-linux-ohos"
    BUILD_SUFFIX=""
    ;;
  x86_64)
    SYSROOT_LIB="x86_64-linux-ohos"
    BUILD_SUFFIX="-x86_64"
    ;;
  *)
    echo "Unsupported OHOS_ARCH: $OHOS_ARCH (expected arm64-v8a or x86_64)" >&2
    exit 1
    ;;
esac

DEPS="$ROOT/.build/deps"
BUILD="$ROOT/.build/build"
OUT="$ROOT/.build/out/libs/$OHOS_ARCH"
LIBGIT2_SRC="${LIBGIT2_SRC:-$DEPS/libgit2}"
MBEDTLS_SRC="${MBEDTLS_SRC:-$DEPS/mbedtls}"
MBEDTLS_INSTALL="$BUILD/mbedtls-install$BUILD_SUFFIX"
LIBGIT2_BUILD="$BUILD/libgit2$BUILD_SUFFIX"
MBEDTLS_BUILD="$BUILD/mbedtls$BUILD_SUFFIX"
NAPI_BUILD="$BUILD/napi$BUILD_SUFFIX"

if [[ ! -f "$SDK/build/cmake/ohos.toolchain.cmake" ]]; then
  echo "OpenHarmony NDK not found at $SDK (set OHOS_NDK)" >&2
  exit 1
fi

if [[ ! -d "$LIBGIT2_SRC/.git" ]]; then
  mkdir -p "$DEPS"
  git clone --depth 1 --branch v1.9.7 https://github.com/libgit2/libgit2.git "$LIBGIT2_SRC"
fi
if [[ ! -d "$MBEDTLS_SRC/.git" ]]; then
  mkdir -p "$DEPS"
  git clone --depth 1 --branch v3.6.7 https://gitee.com/mirrors/mbedtls.git "$MBEDTLS_SRC"
fi
if [[ ! -f "$MBEDTLS_SRC/framework/CMakeLists.txt" ]]; then
  git -C "$MBEDTLS_SRC" submodule update --init --depth 1 framework
fi

CM="$SDK/build-tools/cmake/bin/cmake"
NINJA="$SDK/build-tools/cmake/bin/ninja"
COMMON=(
  -G Ninja
  "-DCMAKE_TOOLCHAIN_FILE=$SDK/build/cmake/ohos.toolchain.cmake"
  -DOHOS_ARCH="$OHOS_ARCH"
  -DOHOS_COMPATIBLE_SDK_VERSION=24
  -DOHOS_PLATFORM=OHOS
  "-DCMAKE_MAKE_PROGRAM=$NINJA"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
)

"$CM" -S "$MBEDTLS_SRC" -B "$MBEDTLS_BUILD" "${COMMON[@]}" \
  -DMBEDTLS_FATAL_WARNINGS=OFF \
  -DENABLE_TESTING=OFF \
  -DENABLE_PROGRAMS=OFF \
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
  "-DCMAKE_INSTALL_PREFIX=$MBEDTLS_INSTALL"
"$CM" --build "$MBEDTLS_BUILD" --parallel
"$CM" --install "$MBEDTLS_BUILD"

"$CM" -S "$LIBGIT2_SRC" -B "$LIBGIT2_BUILD" "${COMMON[@]}" \
  -DCMAKE_C_STANDARD=99 \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTS=OFF \
  -DBUILD_CLI=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DEXPERIMENTAL_SHA256=OFF \
  -DUSE_SSH=OFF \
  -DUSE_HTTPS=mbedTLS \
  "-DMBEDTLS_INCLUDE_DIR=$MBEDTLS_INSTALL/include" \
  "-DMBEDTLS_LIBRARY=$MBEDTLS_INSTALL/lib/libmbedtls.a" \
  "-DMBEDX509_LIBRARY=$MBEDTLS_INSTALL/lib/libmbedx509.a" \
  "-DMBEDCRYPTO_LIBRARY=$MBEDTLS_INSTALL/lib/libmbedcrypto.a"
"$CM" --build "$LIBGIT2_BUILD" --parallel

"$CM" -S "$ROOT" -B "$NAPI_BUILD" "${COMMON[@]}" \
  "-DOHOS_NATIVE_SDK=$SDK" \
  "-DSYSROOT_LIB=$SYSROOT_LIB" \
  "-DLIBGIT2_INCLUDE_DIR=$LIBGIT2_SRC/include" \
  "-DLIBGIT2_LIBRARY=$LIBGIT2_BUILD/libgit2.so"
"$CM" --build "$NAPI_BUILD" --parallel

mkdir -p "$OUT"
cp "$LIBGIT2_BUILD/libgit2.so.1.9" "$OUT/libgit2.so.1.9"
cp "$NAPI_BUILD/libgit2_napi.so" "$OUT/libgit2_napi.so"
printf 'Built API24 native module (%s): %s\n' "$OHOS_ARCH" "$OUT"
