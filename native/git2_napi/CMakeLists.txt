cmake_minimum_required(VERSION 3.16)
project(libgit2_napi C)

set(LIBGIT2_INCLUDE_DIR "" CACHE PATH "Path to libgit2 v1.9.7 headers")
set(LIBGIT2_LIBRARY "" CACHE FILEPATH "Path to the libgit2 shared library")
set(OHOS_NATIVE_SDK "" CACHE PATH "Path to the OpenHarmony native SDK")
# aarch64-linux-ohos 对应 arm64-v8a；x86_64-linux-ohos 对应 x86_64。
# build.sh 会按 OHOS_ARCH 显式传入，默认值保持历史行为。
set(SYSROOT_LIB "aarch64-linux-ohos" CACHE STRING "OHOS sysroot library triple")

if(NOT EXISTS "${LIBGIT2_INCLUDE_DIR}/git2.h")
  message(FATAL_ERROR "Set LIBGIT2_INCLUDE_DIR to the libgit2 include directory")
endif()
if(NOT EXISTS "${LIBGIT2_LIBRARY}")
  message(FATAL_ERROR "Set LIBGIT2_LIBRARY to the built libgit2 shared library")
endif()

find_library(ACE_NAPI_LIBRARY ace_napi.z
  HINTS "${OHOS_NATIVE_SDK}/sysroot/usr/lib/${SYSROOT_LIB}")
if(NOT ACE_NAPI_LIBRARY)
  message(FATAL_ERROR "Could not find libace_napi.z.so in the OpenHarmony NDK")
endif()

add_library(libgit2 SHARED IMPORTED GLOBAL)
set_target_properties(libgit2 PROPERTIES IMPORTED_LOCATION "${LIBGIT2_LIBRARY}")

add_library(libgit2_napi SHARED src/libgit2_napi.c)
target_include_directories(libgit2_napi PRIVATE "${LIBGIT2_INCLUDE_DIR}")
target_compile_features(libgit2_napi PRIVATE c_std_99)
set_target_properties(libgit2_napi PROPERTIES
  OUTPUT_NAME "git2_napi"
  BUILD_WITH_INSTALL_RPATH TRUE
  INSTALL_RPATH "$ORIGIN")
target_compile_options(libgit2_napi PRIVATE -Wall -Wextra)
target_link_libraries(libgit2_napi PRIVATE libgit2 "${ACE_NAPI_LIBRARY}")
