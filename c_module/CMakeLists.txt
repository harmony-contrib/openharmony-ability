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

option(OH_ABILITY_BUILD_SDL_DEMO "Build the SDL3 integration demo module" OFF)
set(OH_ABILITY_SDL_SOURCE_DIR "" CACHE PATH
    "Path to the SDL3 checkout containing the current oh_ability adapter")

if(OH_ABILITY_BUILD_SDL_DEMO)
    if(NOT EXISTS "${OH_ABILITY_SDL_SOURCE_DIR}/CMakeLists.txt")
        message(FATAL_ERROR
            "OH_ABILITY_BUILD_SDL_DEMO requires OH_ABILITY_SDL_SOURCE_DIR to point to SDL sources")
    endif()
    if(NOT EXISTS
       "${OH_ABILITY_SDL_SOURCE_DIR}/examples/ohos/oh_ability/CMakeLists.txt")
        message(FATAL_ERROR
            "The selected SDL checkout has no current oh_ability adapter template")
    endif()

    # SDL is embedded in the native module. The checkout is already migrated to the external-host
    # model: oh_ability owns the eight-export contract, XComponent, lifecycle and input.
    set(SDL_SHARED OFF CACHE BOOL "" FORCE)
    set(SDL_STATIC ON CACHE BOOL "" FORCE)
    set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
    set(SDL_TESTS OFF CACHE BOOL "" FORCE)
    set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
    set(SDL_DIALOG ON CACHE BOOL "" FORCE)
    add_subdirectory("${OH_ABILITY_SDL_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/sdl3")
    add_subdirectory(
        "${OH_ABILITY_SDL_SOURCE_DIR}/examples/ohos/oh_ability"
        "${CMAKE_BINARY_DIR}/sdl3-oh-ability")
    add_subdirectory(example/sdl_demo_native)
endif()
