cmake_minimum_required(VERSION 3.16.0)

project(ohos-c-ability C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ---------------------------------------------------------------------------
# OHOS SDK stub library resolution.
#
# The NDK ships stub libraries (lib*.z.so or plain names) in the sysroot. The
# ohos.toolchain.cmake exposes CMAKE_SYSROOT and OHOS_TOOLCHAIN_NAME
# (e.g. aarch64-linux-ohos). Some SDK versions only ship one spelling, so we
# try both and fall back to the default search.
# ---------------------------------------------------------------------------
function(ohos_find_library out_var name)
    set(candidates "lib${name}.z.so" "lib${name}.so")
    find_library(${out_var}
        NAMES ${candidates}
        HINTS "${CMAKE_SYSROOT}/usr/lib/${OHOS_TOOLCHAIN_NAME}"
        NO_DEFAULT_PATH)
    if(NOT ${out_var})
        find_library(${out_var} NAMES ${candidates})
    endif()
    if(NOT ${out_var})
        message(FATAL_ERROR "OHOS SDK library '${name}' was not found")
    endif()
    message(STATUS "OHOS SDK library ${name} -> ${${out_var}}")
endfunction()

add_subdirectory(ability)
add_subdirectory(example/demo_native)
