cmake_minimum_required(VERSION 3.16)
project(git2_napi_test C)

set(REPOSITORY_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../..")
set(NATIVE_ROOT "${REPOSITORY_ROOT}/native/git2_napi")
set(LIBGIT2_OUTPUT "${NATIVE_ROOT}/.build/out/libs/arm64-v8a")
set(LIBGIT2_HEADERS "${NATIVE_ROOT}/.build/build/libgit2/include")

if(NOT EXISTS "${LIBGIT2_OUTPUT}/libgit2.so.1.9" OR
   NOT EXISTS "${LIBGIT2_HEADERS}/git2.h")
  message(FATAL_ERROR "Build native/git2_napi before assembling the Native test HAP")
endif()

find_library(ACE_NAPI_LIBRARY ace_napi.z
  HINTS "${CMAKE_SYSROOT}/usr/lib/aarch64-linux-ohos")
if(NOT ACE_NAPI_LIBRARY)
  message(FATAL_ERROR "Could not find libace_napi.z in the HarmonyOS NDK")
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
