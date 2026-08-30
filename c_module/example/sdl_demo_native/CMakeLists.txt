add_library(sdl_demo_native SHARED src/main.c)

target_link_libraries(sdl_demo_native PRIVATE SDL3::OHAbility)
target_compile_options(sdl_demo_native PRIVATE
    -Wall -Wextra -Werror -Wno-unused-command-line-argument
)

# N-API and ArkUI/native-window symbols used by the framework and SDL's OHOS backend.
ohos_find_library(OHOS_ACE_NAPI_LIB ace_napi)
ohos_find_library(OHOS_ACE_NDK_LIB ace_ndk)
ohos_find_library(OHOS_NATIVE_WINDOW_LIB native_window)
ohos_find_library(OHOS_RAWFILE_LIB rawfile)
target_link_libraries(sdl_demo_native PRIVATE
    ${OHOS_ACE_NAPI_LIB}
    ${OHOS_ACE_NDK_LIB}
    ${OHOS_NATIVE_WINDOW_LIB}
    ${OHOS_RAWFILE_LIB}
)
