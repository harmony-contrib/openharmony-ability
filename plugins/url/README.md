# @ohos-rs/ability-plugin-url

English | [简体中文](README.zh-CN.md)

This external-URL HAR pairs with `openharmony-ability-plugin-url`. It uses the Ability context's `context.openLink(url)` to open external links.

## Install

```bash
ohpm install @ohos-rs/ability-plugin-url
```

## Assembly

Add the HAR to the application's `oh-package.json5`:

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-url": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { UrlPlugin } from "@ohos-rs/ability-plugin-url";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new UrlPlugin())];
}
```

Register `UrlBridgePlugin` in Rust and call `UrlExt::open_url`. See the [Rust facade README](../../crates/plugin-url/README.md).

## Plugin contract

| Field | Value |
| --- | --- |
| `id` | `ohos.url` |
| `execution` | `async` |
| `requires` | `["ability"]` |
| Actions | `open-url` |
| request → response | `ohos.url.OpenRequest { url }` → `ohos.url.OpenResponse { accepted }` |

## Behavior

- `url` must be absolute and include a scheme. Empty strings and missing schemes throw.
- Platform `openLink` failures or Ability destruction reject the Promise with an explicit error.
- Requests/responses are named N-API objects, without JSON transport.

See the [plugin development standard](../../docs/plugin-development-standard.md) for threading,
lifecycle and contract acceptance rules.

## License

Choose either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE).
