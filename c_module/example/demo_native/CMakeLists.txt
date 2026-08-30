# Pure C demo native module. It produces libdemo_native.so with the exact
# export surface consumed by the @ohos-rs/ability host and the demo Index page
# (see types/libdemo_native/Index.d.ts). Install it into
# demo/entry/libs/<abi>/libdemo_native.so to replace the Rust demo module.
#
# Plugin switches (compile-time, mirroring the OH_ABILITY_PLUGIN_* macros):
#   -DOH_ABILITY_PLUGIN_WEBVIEW=OFF      disable the webview plugin/demos (no libohweb link;
#                                        exports stay as explicit-error stubs)
#   -DOH_ABILITY_PLUGIN_RESOURCE=OFF     disable the ohos.resource inbound plugin
#   -DOH_ABILITY_PLUGIN_PERMISSION=OFF   disable the ohos.permission demo export
#   -DOH_ABILITY_PLUGIN_FILES=OFF        disable the ohos.files demo exports
#   -DOH_ABILITY_PLUGIN_URL=OFF          disable the ohos.url demo export
#   -DOH_ABILITY_PLUGIN_APP_CONTROL=OFF  reserved: ohos.app-control (no demo surface yet)
#   -DOH_ABILITY_PLUGIN_WINDOW=OFF       reserved: ohos.window (no demo surface yet)
# All default to ON. Disabled plugins keep their export names as explicit-error stubs so the
# demo Index page still imports cleanly.
option(OH_ABILITY_PLUGIN_WEBVIEW "Enable the ohos.webview plugin and demos (links libohweb)" ON)
option(OH_ABILITY_PLUGIN_RESOURCE "Enable the ohos.resource inbound plugin" ON)
option(OH_ABILITY_PLUGIN_PERMISSION "Enable the ohos.permission demo export" ON)
option(OH_ABILITY_PLUGIN_FILES "Enable the ohos.files demo exports" ON)
option(OH_ABILITY_PLUGIN_URL "Enable the ohos.url demo export" ON)
option(OH_ABILITY_PLUGIN_APP_CONTROL "Reserved: ohos.app-control" ON)
option(OH_ABILITY_PLUGIN_WINDOW "Reserved: ohos.window" ON)

add_library(demo_native SHARED
    src/main.c
    src/exports.c
    src/bridge_demos.c
    src/plugins/permission/plugin_permission.c
    src/plugins/files/plugin_files.c
    src/plugins/url/plugin_url.c
    src/plugins/resource/plugin_resource.c
    src/plugins/webview/plugin_webview.c
    src/plugins/window/plugin_window.c
    src/plugins/app-control/plugin_app_control.c
)

target_link_libraries(demo_native PRIVATE oh_ability)

# src/ for demo_common.h; each plugin directory is an include root so plugins include their own
# header by name.
target_include_directories(demo_native PRIVATE
    src
    src/plugins/permission
    src/plugins/files
    src/plugins/url
    src/plugins/resource
    src/plugins/webview
    src/plugins/window
    src/plugins/app-control
)

target_compile_options(demo_native PRIVATE -Wall -Wextra -Werror -Wno-unused-command-line-argument)

target_compile_definitions(demo_native PRIVATE
    $<$<BOOL:${OH_ABILITY_PLUGIN_WEBVIEW}>:OH_ABILITY_PLUGIN_WEBVIEW>
    $<$<BOOL:${OH_ABILITY_PLUGIN_RESOURCE}>:OH_ABILITY_PLUGIN_RESOURCE>
    $<$<BOOL:${OH_ABILITY_PLUGIN_PERMISSION}>:OH_ABILITY_PLUGIN_PERMISSION>
    $<$<BOOL:${OH_ABILITY_PLUGIN_FILES}>:OH_ABILITY_PLUGIN_FILES>
    $<$<BOOL:${OH_ABILITY_PLUGIN_URL}>:OH_ABILITY_PLUGIN_URL>
    $<$<BOOL:${OH_ABILITY_PLUGIN_APP_CONTROL}>:OH_ABILITY_PLUGIN_APP_CONTROL>
    $<$<BOOL:${OH_ABILITY_PLUGIN_WINDOW}>:OH_ABILITY_PLUGIN_WINDOW>
)

# N-API runtime and platform libraries required by the framework.
ohos_find_library(OHOS_ACE_NAPI_LIB ace_napi)
ohos_find_library(OHOS_ACE_NDK_LIB ace_ndk)
ohos_find_library(OHOS_NATIVE_WINDOW_LIB native_window)
ohos_find_library(OHOS_RAWFILE_LIB rawfile)
target_link_libraries(demo_native PRIVATE
    ${OHOS_ACE_NAPI_LIB}
    ${OHOS_ACE_NDK_LIB}
    ${OHOS_NATIVE_WINDOW_LIB}
    ${OHOS_RAWFILE_LIB}
)

if(OH_ABILITY_PLUGIN_WEBVIEW)
    ohos_find_library(OHOS_WEB_LIB ohweb)
    target_link_libraries(demo_native PRIVATE ${OHOS_WEB_LIB})
endif()
