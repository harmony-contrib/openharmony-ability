# @ohos-rs/ability-plugin-deep-link

[English](README.md) | 简体中文

读取应用冷启动和后续 Want 中的 URI，并提供 Rust 会话内的消费式启动数据访问。

这是 [`openharmony-ability-plugin-deep-link`](../../crates/plugin-deep-link/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-deep-link
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-deep-link": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { DeepLinkPlugin } from "@ohos-rs/ability-plugin-deep-link";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new DeepLinkPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `DeepLinkBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-deep-link/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.deep-link` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `get_initial_uri` | `get-initial-uri` | 读取冷启动 URI，不消费。 |
| `get_latest_uri` | `get-latest-uri` | 读取最近一次 Want URI。 |
| `take_initial_uri` | —（同步会话读取） | 取出并清空 Rust 初始 URI。 |
| `take_want_parameters` | —（同步会话读取） | 取出并清空最近一次 Want 参数数据。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- 异步 URI 查询读取 `NativeAbility` 维护的 `AppStorage` 初始/最新 URI；没有 URI 时返回 `None`。
- `take_*` 读取 Rust app 的生命周期状态，不经过 ArkTS；消费后再次读取为空字符串，与异步非消费式查询不同。
- 启动数据在对应生命周期回调到达后才可读取。保留 `NativeAbility` 的 `onCreate`、`onNewWant` 调用链。
- URI scheme 必须在应用清单中声明；本插件只读取投递数据，不会在运行时注册 scheme。

当前实现见 [插件源码](src/main/ets/DeepLinkPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
