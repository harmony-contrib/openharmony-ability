# Pure C framework library: implements the @ohos-rs/ability native module
# contract and the SDL-style application model for business C code.
#
# Capability switches (compile-time, like cargo features / SDL subsystems):
#   -DOH_ABILITY_ENABLE_IME=OFF     disable IME support (no ohinputmethod link)
#   -DOH_ABILITY_ENABLE_DISPLAY=OFF disable display density queries (no native_display_manager link)
#   -DOH_ABILITY_PLUGIN_NODE=OFF    disable the built-in ohos.node surface plugin
# Disabled capabilities keep their API declarations out of oh_ability.h and return
# OH_ABILITY_ERROR_NOT_READY from the corresponding accessors.
option(OH_ABILITY_ENABLE_IME "Enable IME support (links ohinputmethod)" ON)
option(OH_ABILITY_ENABLE_DISPLAY "Enable display density queries (links native_display_manager)" ON)
option(OH_ABILITY_PLUGIN_NODE "Enable the built-in ohos.node surface plugin" ON)

set(OH_ABILITY_SOURCES
    src/state.c
    src/module.c
    src/lifecycle.c
    src/event.c
    src/bridge.c
    src/registry.c
    src/xcomponent.c
    src/configuration.c
)
if(OH_ABILITY_ENABLE_IME)
    list(APPEND OH_ABILITY_SOURCES src/ime.c)
endif()
if(OH_ABILITY_PLUGIN_NODE)
    list(APPEND OH_ABILITY_SOURCES src/node.c)
endif()

add_library(oh_ability STATIC ${OH_ABILITY_SOURCES})

target_include_directories(oh_ability PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

# -Wno-unused-command-line-argument: the OHOS toolchain passes --gcc-toolchain to clang, which
# rejects it as unused for C compilation on some SDK versions; combined with -Werror it fails.
target_compile_options(oh_ability PRIVATE -Wall -Wextra -Werror -Wno-unused-command-line-argument)

# The capability macros are PUBLIC: consumers include <oh_ability.h>, whose declarations are
# gated on them.
target_compile_definitions(oh_ability PUBLIC
    $<$<BOOL:${OH_ABILITY_ENABLE_IME}>:OH_ABILITY_ENABLE_IME>
    $<$<BOOL:${OH_ABILITY_ENABLE_DISPLAY}>:OH_ABILITY_ENABLE_DISPLAY>
    $<$<BOOL:${OH_ABILITY_PLUGIN_NODE}>:OH_ABILITY_PLUGIN_NODE>
)

# hilog for framework diagnostics.
ohos_find_library(OHOS_HILOG_LIB hilog_ndk)
target_link_libraries(oh_ability PUBLIC ${OHOS_HILOG_LIB})

if(OH_ABILITY_ENABLE_IME)
    ohos_find_library(OHOS_INPUTMETHOD_LIB ohinputmethod)
    target_link_libraries(oh_ability PUBLIC ${OHOS_INPUTMETHOD_LIB})
endif()

if(OH_ABILITY_ENABLE_DISPLAY)
    ohos_find_library(OHOS_DISPLAY_MANAGER_LIB native_display_manager)
    target_link_libraries(oh_ability PUBLIC ${OHOS_DISPLAY_MANAGER_LIB})
endif()
