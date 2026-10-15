# @ohos-rs/ability-plugin-account

[English](README.md) | 简体中文

通过 Huawei Account Kit 完成交互式登录、静默登录和取消应用授权。

这是 [`openharmony-ability-plugin-account`](../../crates/plugin-account/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-account
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-account": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AccountPlugin } from "@ohos-rs/ability-plugin-account";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AccountPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `AccountBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-account/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.account` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `login` | `login` | 显示登录面板，返回 AccountInfo。 |
| `silent_login` | `silentLogin` | 不显示面板的登录。 |
| `logout` | `logout` | 取消当前应用的 Huawei Account 授权。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- 需要目标设备和应用具备 Huawei Account Kit 的运行条件；插件不代替应用侧的账号服务配置。
- 交互登录允许等待五分钟；静默登录不显示 UI，设备登录或应用授权条件不满足时会失败。
- `AccountInfo` 包含 `uid`、`open_id`、`union_id`、`display_name`、`avatar_uri`、`authorization_code` 和可选 `access_token`；平台未提供的字符串字段可能为空。
- `logout` 取消的是应用授权，不代表注销设备上的系统账号。桥接 action `silentLogin` 保持现有 ABI 拼写。

当前实现见 [插件源码](src/main/ets/AccountPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
