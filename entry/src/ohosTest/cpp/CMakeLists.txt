cmake_minimum_required(VERSION 3.16)
project(git2_napi_test C)

set(REPOSITORY_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../..")
set(NATIVE_ROOT "${REPOSITORY_ROOT}/native/git2_napi")
# hvigor 按 abiFilters 逐架构调用 CMake 并传 -DOHOS_ARCH（ohos.toolchain.cmake），
# 测试 HAP 必须取**同架构**的 libgit2 产物；两套 libgit2 都由 native/git2_napi/build.sh
# 预先编好（OHOS_ARCH=x86_64 时其 libgit2 构建目录带 -x86_64 后缀）。
if(OHOS_ARCH STREQUAL "x86_64")
  set(LIBGIT2_OUTPUT "${NATIVE_ROOT}/.build/out/libs/x86_64")
  set(LIBGIT2_HEADERS "${NATIVE_ROOT}/.build/build/libgit2-x86_64/include")
  set(SYSROOT_LIB "x86_64-linux-ohos")
elseif(OHOS_ARCH STREQUAL "arm64-v8a")
  set(LIBGIT2_OUTPUT "${NATIVE_ROOT}/.build/out/libs/arm64-v8a")
  set(LIBGIT2_HEADERS "${NATIVE_ROOT}/.build/build/libgit2/include")
  set(SYSROOT_LIB "aarch64-linux-ohos")
else()
  message(FATAL_ERROR "Unsupported OHOS_ARCH for the Native test HAP: ${OHOS_ARCH}")
endif()

if(NOT EXISTS "${LIBGIT2_OUTPUT}/libgit2.so.1.9" OR
   NOT EXISTS "${LIBGIT2_HEADERS}/git2.h")
  message(FATAL_ERROR "Build native/git2_napi (${OHOS_ARCH}) before assembling the Native test HAP")
endif()

# find_library 会命中 CMakeCache 的旧值（换架构重配后曾把 aarch64 路径
# 缓存进 x86_64 构建目录），先 unset 再找，找到后还要校验架构三元组。
unset(ACE_NAPI_LIBRARY CACHE)
find_library(ACE_NAPI_LIBRARY ace_napi.z
  HINTS "${CMAKE_SYSROOT}/usr/lib/${SYSROOT_LIB}")
if(NOT ACE_NAPI_LIBRARY)
  message(FATAL_ERROR "Could not find libace_napi.z in the HarmonyOS NDK")
endif()
if(NOT ACE_NAPI_LIBRARY MATCHES "${SYSROOT_LIB}")
  message(FATAL_ERROR "libace_napi.z arch mismatch: ${ACE_NAPI_LIBRARY} (expect ${SYSROOT_LIB}); delete entry/.cxx and reconfigure")
endif()

add_library(libgit2 SHARED IMPORTED GLOBAL)
set_target_properties(libgit2 PROPERTIES
  IMPORTED_LOCATION "${LIBGIT2_OUTPUT}/libgit2.so.1.9")

add_library(git2_napi_test SHARED "${NATIVE_ROOT}/src/libgit2_napi.c")
set_target_properties(git2_napi_test PROPERTIES
  OUTPUT_NAME "git2_napi"
  BUILD_WITH_INSTALL_RPATH TRUE
  INSTALL_RPATH "$ORIGIN")
target_include_directories(git2_napi_test PRIVATE "${LIBGIT2_HEADERS}")
target_compile_features(git2_napi_test PRIVATE c_std_99)
target_compile_options(git2_napi_test PRIVATE -Wall -Wextra)
target_link_libraries(git2_napi_test PRIVATE libgit2 "${ACE_NAPI_LIBRARY}")

add_custom_command(TARGET git2_napi_test POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
    "${LIBGIT2_OUTPUT}/libgit2.so.1.9"
    "$<TARGET_FILE_DIR:git2_napi_test>/libgit2.so.1.9")
