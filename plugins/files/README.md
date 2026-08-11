# @ohos-rs/ability-plugin-files

这是文件选择对话框能力的 ArkTS HAR，对应 Rust crate `openharmony-ability-plugin-files`。它在
Ability context 上调用系统文件选择器（open / save / folder），通过结构化 `DialogOptions` 传参；
filter 字符串语法只在 ArkTS 插件内部转换。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-files
```

## 装配

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.0",
    "@ohos-rs/ability-plugin-files": "1.0.0-beta.0"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { FilesPlugin } from "@ohos-rs/ability-plugin-files";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new FilesPlugin())];
}
```

Rust 侧还需注册 `FilesBridgePlugin`，并通过 `FilesExt::show_file_dialog` 发起调用。使用示例见
[Rust facade README](../../crates/plugin-files/README.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.files` |
| `execution` | `async` |
| `requires` | `["ability"]` |
| 支持 action | `file-dialog` |
| request → response | `ohos.files.DialogOptions` → `ohos.files.DialogResponse` |

`DialogOptions` 支持 `dialogType`（open / save / folder）、`allowMany`、`defaultLocation` 与
`filters`（`FileDialogFilter` 的 name/pattern 列表）。`DialogResponse` 返回
`{ files: string[] }`；用户取消时为空数组。

## 行为

- `dialogType` 必须是合法的 open / save / folder 枚举值；请求 typeName 或字段不合法直接抛错。
- folder 选择依赖设备能力：非 2-in-1 设备上调用 folder 对话框会以明确错误结束。
- 系统对话框关闭后检查 `context.isActive()`；Ability 已销毁时 Promise 以错误结束。
- request/response 是具名 N-API object，禁止 JSON transport。

完整线程、生命周期与契约变更规则见
[插件开发规范](../../docs/plugin-development-standard.md)。
