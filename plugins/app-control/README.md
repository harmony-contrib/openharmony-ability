# @ohos-rs/ability-plugin-app-control

English | [简体中文](README.zh-CN.md)

This ArkTS HAR implements the synchronous main-thread `terminate` action for `openharmony-ability-plugin-app-control`, exiting through `@ohos.process` `ProcessManager.exit(code)`.

## Install

```bash
ohpm install @ohos-rs/ability-plugin-app-control
```

## Assembly

Add the HAR to the application's `oh-package.json5`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-app-control": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AppControlPlugin } from "@ohos-rs/ability-plugin-app-control";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AppControlPlugin())];
}
```

Register `AppControlBridgePlugin` in Rust and call `AppControlExt::terminate` only with the current N-API callback's `Env`. See the [Rust facade README](../../crates/plugin-app-control/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.app-control` |
| `execution` | `sync-main-thread` |
| `requires` | `["ability"]` |
| Actions | `terminate` |
| request → response | `ohos.app_control.TerminateRequest { code }` → `ohos.app_control.TerminateResponse { accepted }` |

`invokeSync` cannot return a Promise, await or wait for context. The host fails immediately if the Ability is not ready, the plugin is not installed or the caller uses the async entry point.

## Behavior and safety boundaries

- `code` must be an integer. Unsupported actions or mismatched types throw.
- Do not assume UI/Rust code continues after `ProcessManager.exit(code)` succeeds.
- The HAR does not show a quit-confirmation UI. Handle confirmation and save state before calling the Rust facade.
- Requests/responses are named N-API objects, without JSON transport.

See the [plugin development standard](../../docs/plugin-development-standard.md) for threading,
lifecycle and contract acceptance rules.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
