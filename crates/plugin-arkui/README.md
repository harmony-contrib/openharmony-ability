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
