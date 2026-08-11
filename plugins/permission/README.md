# @ohos-rs/ability-plugin-permission

这是 `openharmony-ability-plugin-permission` 的 ArkTS 实现包。它在 `NativeAbility` 所属的
Ability context 中调用 `abilityAccessCtrl.requestPermissionsFromUser`；业务 Rust 代码通过配对的
Rust facade 发起请求，不直接调用本 HAR 的内部 action。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-permission
```

## 装配

在应用 `oh-package.json5` 中添加该 HAR：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.0",
    "@ohos-rs/ability-plugin-permission": "1.0.0-beta.0"
  }
}
```

在入口 Ability 通过 `LazyPlugin` 显式注册新 plugin 实例，并继续调用 `NativeAbility` 的生命周期实现：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { PermissionPlugin } from "@ohos-rs/ability-plugin-permission";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new PermissionPlugin())];
}
```

Rust 侧也必须在 `#[ability]` 初始化器注册 `PermissionBridgePlugin`。两端装配方式见
[Rust facade README](../../crates/plugin-permission/README.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.permission` |
| `execution` | `async` |
| `requires` | `["ability"]` |
| 支持 action | `request` |
| request → response | `ohos.permission.PermissionRequest` → `ohos.permission.PermissionResponse` |

`PermissionPlugin` 只在 Ability context 可用后激活。它校验 `payload.typeName`、非空权限数组和每个
权限名称，再调用系统授权 API；不接受 JSON payload 或未声明的 action。

## 行为

- `permissions` 以输入顺序传入，`codes` 以相同顺序返回。
- 系统调用失败、缺失结果或未授权的回退码为 `-1`；这让 Rust facade 能保持每项权限一一对应。
- 请求完成后会检查 `context.isActive()`。若 Ability 已销毁，Promise 以错误结束而不是返回过期结果。
- 调用方仍必须在应用 manifest 中声明权限；运行时插件不能替代该配置。

## 维护要求

修改 action、字段或 typeName 时，必须同步修改 Rust crate、ArkTS 实现、测试和 demo；不兼容契约
使用新的 action/typeName。请求/响应使用真实 N-API object，不得引入 `JSON.stringify` / `JSON.parse`。

完整线程、生命周期与验收规则见 [插件开发规范](../../docs/plugin-development-standard.md)。
