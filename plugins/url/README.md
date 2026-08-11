# @ohos-rs/ability-plugin-url

这是外部 URL 打开能力的 ArkTS HAR，对应 Rust crate `openharmony-ability-plugin-url`。它在
Ability context 上调用 `context.openLink(url)` 打开外部链接。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-url
```

## 装配

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.0",
    "@ohos-rs/ability-plugin-url": "1.0.0-beta.0"
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

Rust 侧还需注册 `UrlBridgePlugin`，并通过 `UrlExt::open_url` 发起调用。使用示例见
[Rust facade README](../../crates/plugin-url/README.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.url` |
| `execution` | `async` |
| `requires` | `["ability"]` |
| 支持 action | `open-url` |
| request → response | `ohos.url.OpenRequest { url }` → `ohos.url.OpenResponse { accepted }` |

## 行为

- `url` 必须是带 scheme 的绝对 URL；缺失 scheme 或空字符串直接抛错。
- `openLink` 失败或 Ability 在调用期间销毁时，Promise 以明确错误结束。
- request/response 是具名 N-API object，禁止 JSON transport。

完整线程、生命周期与契约变更规则见
[插件开发规范](../../docs/plugin-development-standard.md)。
