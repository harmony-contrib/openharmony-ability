# ArkUI editors

Register `ArkuiBridgePlugin::new()` and the paired `ArkuiPlugin` factory. This
UI-context capability requires API 20. `apply_editors(app, env, EditorBatch)`
applies controlled states, then ordered focus/blur/UTF-16 selection commands.
Text updates require the current native edit count; stale values preserve IME edits.

`EditorEvents::new(app, id, target_id, callback)` owns one UI-thread callback.
The registered plugin instance and native attachment generation isolate delivery;
dropping the guard removes only that registration. ArkTS owns the system editor.
Native attachment retirement follows the [plugin standard](../../docs/plugin-development-standard.md#native-attachment-ownership).

| Action/event | Request | Response |
|---|---|---|
| `apply-editors` | `ohos.arkui.EditorBatch` | `ohos.node.Acknowledgement` |
| `editor-event` | `ohos.arkui.EditorEvent` | `ohos.node.Acknowledgement` |

The demo's **Native editor** and **Release editor** buttons exercise the full
Rust → named bridge → ArkTS editor → native parent → ContentSlot path.

`apply_native_views` wraps an owned C subtree using `NativeViewBatch`. Register
`NativeViewEvents::new(app, id, target_id, callback)` before creation. Semantic
roles, state and context menus belong to the wrapper; native descendants retain
their own semantics. Optional state descriptions require API 23; custom actions
require API 26. Menu callbacks echo their current menu generation. `ViewMenuItem.kind` explicitly selects `action` or `paste`; a paste grant returns
the original opaque item name. A normal action named `paste` stays ordinary.
Menu close/dispose promises join the plugin teardown barrier. Failed retirement retains the
ArkTS owner. The demo's **Semantic wrapper** button exercises the subtree path.

| Action/event | Request | Response |
|---|---|---|
| `apply-native-views` | `ohos.arkui.NativeViewBatch` | `ohos.node.Acknowledgement` |
| `view-action` | `ohos.arkui.NativeViewAction` | `ohos.node.Acknowledgement` |

`NativeViewSettings.texture_surface` exports a live subtree into a caller-owned
surface; `texture_insets` adds nonnegative overflow space in vp. DISPLAY and
TEXTURE builder boundaries preserve nested exports. The API-20 pointer adapter
forwards the original wrapped mouse touch event only within its callback and
restores coordinates before bubbling. Terminal cancellation retains plain owned
data. Reentrant closing detaches native edges immediately; only builder disposal
waits for active posting to return. The demo's **Export texture** button uses an
ordinary XComponent surface as the consumer.
