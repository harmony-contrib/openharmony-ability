# Notification plugin

[English](README.md) | 简体中文

## Install

```bash
ohpm install @ohos-rs/ability-plugin-notification
```

## 装配

通过 factory 注册新实例。构造函数要求包含 `scheme` 的 options 对象，
值为不带 `:` 或 `://` 的应用 URI scheme：

```ts
import { LazyPlugin } from "@ohos-rs/ability";
import { NotificationPlugin } from "@ohos-rs/ability-plugin-notification";

new LazyPlugin(() => new NotificationPlugin({ scheme: "my-app-notification" }));
```

通知正文和按钮点击向目标 Ability 的 `onNewWant` 投递
`<scheme>://response?tag=<encoded-tag>&action=<encoded-action-id>`。
点击通知正文时不带 action 参数。
构造时检查 scheme 并转为小写。每个实例保留自己的配置，不同 Ability factory 可使用不同 scheme。
框架不提供默认值，业务响应处理器应使用相同配置。
既有 GPUI 集成可显式传入 `{ scheme: "gpui-notification" }`。

通知最多包含三个 action。Rust 和 ArkTS 都拒绝超出限制的请求；
ArkTS 在申请授权或创建 WantAgent 前先检查整个数组。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
