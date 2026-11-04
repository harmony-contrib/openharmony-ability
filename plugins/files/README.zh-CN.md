# @ohos-rs/ability-plugin-files

[English](README.md) | 简体中文

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
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-files": "1.0.0-beta.3"
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
[Rust facade README](../../crates/plugin-files/README.zh-CN.md)。

若应用通过临时文件加原子替换写入目标路径，使用 `new FilesPlugin(false)`。
在 API 23+ 且支持 `SystemCapability.FileManagement.UserFileService.FolderSelection`
的设备上，保存选择器不会预创建空文件，由调用方负责创建。默认构造方式保留系统
预创建空文件的行为；较低 API 或不支持该能力的设备沿用平台默认行为。
这是宿主配置，不改变具名 N-API 请求与响应契约。

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
- folder 选择由系统 `DocumentViewPicker.select(FOLDER)` 判断是否支持，不按设备名称拦截，支持具备能力的 tablet / 2in1。系统拒绝时保留错误码、设备类型和 API 版本。
- 系统对话框关闭后检查 `context.isActive()`；Ability 已销毁时 Promise 以错误结束。
- request/response 是具名 N-API object，禁止 JSON transport。

完整线程、生命周期与契约变更规则见
[插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
