# openharmony-ability-plugin-permission

`openharmony-ability-plugin-permission` 是 OpenHarmony 运行时权限能力的 Rust facade。它与
ArkTS HAR `@ohos-rs/ability-plugin-permission` 成对使用：Rust 发起强类型异步请求，ArkTS 使用
`abilityAccessCtrl` 展示系统授权界面并返回结果。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-permission` |
| ArkTS HAR | `@ohos-rs/ability-plugin-permission` |
| 插件 ID | `ohos.permission` |
| 执行模式 | 异步：`AsyncBridge` / `invokeAsync` |
| 前置 context | `ability` |
| action | `request` |
| request → response | `ohos.permission.PermissionRequest` → `ohos.permission.PermissionResponse` |

所有调用使用具名 N-API object，而不是 JSON 字符串。Rust 的 `permissions` 字段在 ArkTS 中对应
`permissions`，返回的 `codes` 与输入权限列表按相同索引对齐。

## 接入

1. 在 native Rust 模块中添加该 crate，并在 `#[ability]` 初始化器内注册 Rust facade：

   ```rust
   use openharmony_ability::OpenHarmonyApp;
   use openharmony_ability_derive::ability;
   use openharmony_ability_plugin_permission::PermissionBridgePlugin;

   #[ability]
   fn configure_ability(app: OpenHarmonyApp) {
       app.register_plugin(PermissionBridgePlugin)
           .expect("permission facade must be registered once");
   }
   ```

2. 在应用的 `oh-package.json5` 中加入 `@ohos-rs/ability-plugin-permission`，并在继承
   `NativeAbility` 的入口通过 `LazyPlugin` 显式装配 `PermissionPlugin`：

   ```ts
   import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
   import { PermissionPlugin } from "@ohos-rs/ability-plugin-permission";

   export default class EntryAbility extends NativeAbility {
     public bridgePlugins = [new LazyPlugin(() => new PermissionPlugin())];
   }
   ```

3. 在应用的 `module.json5` 声明需要请求的 OpenHarmony 权限。插件只负责运行时请求，不能绕过
   manifest 声明或系统授权策略。

两侧均已装配后才可调用；只添加 Rust crate 或只添加 HAR 都会在桥接边界失败。

## Rust 使用方式

`PermissionExt` 为 `OpenHarmonyApp` 提供 `request_permission`。它接受单个 `&str` / `String`，也接受
`Vec<String>` 或 `Vec<&str>`；返回 `Vec<PermissionRequestCode>`。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_permission::PermissionExt;

async fn request_camera(app: &OpenHarmonyApp) -> Result<()> {
    let results = app
        .request_permission(vec![
            "ohos.permission.CAMERA",
            "ohos.permission.MICROPHONE",
        ])
        .await?;

    for result in results {
        // result.permission 是请求名；result.code 是系统返回码。
        tracing::info!(permission = %result.permission, code = result.code);
    }
    Ok(())
}
```

这是 worker-safe 的异步 API：调用可以来自 Rust worker，桥接层通过 TSFN 回到 ArkTS，等待系统弹窗完成后
再把 Rust 所有权数据返回给 future。不要在调用侧人为 `block_on` 或占用 ArkTS 主线程。

## 行为与错误语义

- 空权限列表或只含空白名称会在 Rust/ArkTS 边界前被拒绝。
- Rust facade 为请求设置 60 秒 bridge deadline；超时或 Ability/session 销毁会取消等待。
- ArkTS 先以 `-1` 填充每个结果。系统调用失败、返回数组短于请求数组时，对应位置保留 `-1`；正常结果的
  顺序始终与输入一致。
- 系统授权弹窗完成后，ArkTS 会检查 `context.isActive()`；如果 Ability 已销毁，调用以错误结束，不返回
  已失效的结果。

## 开发与排查

ArkTS 侧必须校验输入 `typeName === "ohos.permission.PermissionRequest"`，并返回
`"ohos.permission.PermissionResponse"`。新增 action 或修改字段时，Rust 和 ArkTS 的 typeName、插件 ID、
`requires`、执行模式必须同步更新；不得使用 JSON 序列化 API 传输 payload。

完整的线程、生命周期、契约升级和验收要求见
[插件开发规范](../../docs/plugin-development-standard.md)。ArkTS 实现与装配细节见
[对应 HAR README](../../plugins/permission/README.md)。
