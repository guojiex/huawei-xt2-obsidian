cmake_minimum_required(VERSION 3.16)
project(git2_napi C)

set(REPOSITORY_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../..")
set(NATIVE_ROOT "${REPOSITORY_ROOT}/native/git2_napi")

# hvigor 会按 abiFilters 里的每个架构单独调用本脚本，并通常把目标架构放在
# OHOS_ARCH 里；不同 DevEco 版本下该变量可能缺失，退化到 CMAKE_SYSTEM_PROCESSOR
# 判断，最后兜底 arm64-v8a —— 即历史默认行为。
if(NOT OHOS_ARCH)
  if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
    set(OHOS_ARCH arm64-v8a)
  elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
    set(OHOS_ARCH x86_64)
  else()
    set(OHOS_ARCH arm64-v8a)
  endif()
endif()

if(OHOS_ARCH STREQUAL "x86_64")
  set(OHOS_SYSROOT_LIB "x86_64-linux-ohos")
else()
  set(OHOS_SYSROOT_LIB "aarch64-linux-ohos")
endif()

# 只有 x86_64 是例外（Windows 版 DevEco 只提供 x86 模拟器镜像），真机与
# Apple Silicon Mac 上的模拟器都是 arm64-v8a。
if(NOT OHOS_ARCH STREQUAL "arm64-v8a" AND NOT OHOS_ARCH STREQUAL "x86_64")
  message(FATAL_ERROR "Unsupported OHOS_ARCH=${OHOS_ARCH} (expected arm64-v8a or x86_64)")
endif()

# 头文件目录同样按架构隔离：arm64 时后缀为空，路径与历史完全一致。
if(OHOS_ARCH STREQUAL "x86_64")
  set(HEADER_SUFFIX "-x86_64")
else()
  set(HEADER_SUFFIX "")
endif()

set(LIBGIT2_OUTPUT "${NATIVE_ROOT}/.build/out/libs/${OHOS_ARCH}")
set(LIBGIT2_HEADERS "${NATIVE_ROOT}/.build/build/libgit2${HEADER_SUFFIX}/include")

if(NOT EXISTS "${LIBGIT2_OUTPUT}/libgit2.so.1.9" OR
   NOT EXISTS "${LIBGIT2_HEADERS}/git2.h")
  message(FATAL_ERROR
    "Build native/git2_napi before assembling the App HAP. "
    "Missing ${OHOS_ARCH} artifacts: run OHOS_ARCH=${OHOS_ARCH} ./native/git2_napi/build.sh")
endif()

find_library(ACE_NAPI_LIBRARY ace_napi.z
  HINTS "${CMAKE_SYSROOT}/usr/lib/${OHOS_SYSROOT_LIB}")
if(NOT ACE_NAPI_LIBRARY)
  message(FATAL_ERROR "Could not find libace_napi.z in the HarmonyOS NDK")
endif()

add_library(libgit2 SHARED IMPORTED GLOBAL)
set_target_properties(libgit2 PROPERTIES
  IMPORTED_LOCATION "${LIBGIT2_OUTPUT}/libgit2.so.1.9")

add_library(libgit2_napi SHARED "${NATIVE_ROOT}/src/libgit2_napi.c")
set_target_properties(libgit2_napi PROPERTIES
  OUTPUT_NAME "git2_napi"
  BUILD_WITH_INSTALL_RPATH TRUE
  INSTALL_RPATH "$ORIGIN")
target_include_directories(libgit2_napi PRIVATE "${LIBGIT2_HEADERS}")
target_compile_features(libgit2_napi PRIVATE c_std_99)
target_compile_options(libgit2_napi PRIVATE -Wall -Wextra)
target_link_libraries(libgit2_napi PRIVATE libgit2 "${ACE_NAPI_LIBRARY}")

add_custom_command(TARGET libgit2_napi POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${LIBGIT2_OUTPUT}/libgit2.so.1.9"
    "$<TARGET_FILE_DIR:libgit2_napi>/libgit2.so.1.9")
