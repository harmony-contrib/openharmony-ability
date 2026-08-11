# openharmony-ability-plugin-files

`openharmony-ability-plugin-files` 提供文件选择对话框（open / save / folder）的 Rust facade。它与
ArkTS HAR `@ohos-rs/ability-plugin-files` 成对使用，是异步插件，可从 Rust worker 调用。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-files` |
| ArkTS HAR | `@ohos-rs/ability-plugin-files` |
| 插件 ID | `ohos.files` |
| 执行模式 | 异步：`AsyncBridge` / `invokeAsync` |
| 前置 context | `ability` |
| action | `file-dialog` |
| request → response | `ohos.files.DialogOptions` → `ohos.files.DialogResponse { files }` |

## 接入

Rust facade 和 ArkTS factory 都必须在应用启动期装配：

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_files::FilesBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(FilesBridgePlugin)
        .expect("files facade must be registered once");
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { FilesPlugin } from "@ohos-rs/ability-plugin-files";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new FilesPlugin())];
}
```

同时在应用 `oh-package.json5` 添加 `@ohos-rs/ability-plugin-files`。HAR 的具体依赖和 plugin 说明见
[ArkTS README](../../plugins/files/README.md)。

## Rust 使用方式

`FilesExt::show_file_dialog` 是异步 facade，可在 Rust worker 中调用。参数用 `FileDialogOptions`
builder 组装，filter 的 name/pattern 在 ArkTS 插件内部转换成系统语法：

```rust
use openharmony_ability_plugin_files::{
    dialog_type, FileDialogFilter, FileDialogOptions, FilesExt,
};

let options = FileDialogOptions::new(dialog_type::OPEN_FILE)
    .allow_many(true)
    .filters(vec![
        FileDialogFilter::new().name("Text").pattern("txt;md"),
        FileDialogFilter::new().name("Images").pattern("png;jpg"),
    ]);
let response = app.show_file_dialog(options).await?;
// response.files: Vec<String>，用户取消时为空
```

`dialog_type` 支持 `OPEN_FILE`、`SAVE_FILE` 与 `FOLDER`；`SAVE_FILE` 可带 `default_location`
（如 `file://docs`）。folder 选择依赖设备能力，非 2-in-1 设备会返回明确错误。

## 线程与生命周期限制

- 异步 action：request/response 必须是 `Send + 'static` 的 Rust 所有权数据，经 TSFN 传输；不保存
  `Env`、`napi_value` 或 ArkTS 对象到 worker。
- 系统对话框关闭后才返回；Ability 销毁会导致调用以错误结束。
- 参数与结果都是具名 N-API object，不存在 JSON transport。

完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。
