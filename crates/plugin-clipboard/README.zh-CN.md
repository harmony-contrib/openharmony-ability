# openharmony-ability-plugin-clipboard

[English](README.md) | 简体中文

异步读写系统剪贴板中的文本、HTML、图片、文件 URI 和有序多记录内容。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-clipboard` |
| ArkTS HAR | `@ohos-rs/ability-plugin-clipboard` |
| 插件 ID | `ohos.clipboard` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-clipboard = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_clipboard::ClipboardBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(ClipboardBridgePlugin::default())
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new ClipboardPlugin({ metadataMimeType: "application/x-my-app-metadata-v1" }))];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/clipboard/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_clipboard::ClipboardExt;

async fn copy_and_read(app: &OpenHarmonyApp) -> Result<Option<String>> {
    let clipboard = app.clipboard()?;
    clipboard.write_text("Hello OpenHarmony").await?;
    clipboard.read_text().await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `read_text / write_text` | `read-text / write-text` | 读写文本，空剪贴板读出 None。 |
| `read_content / read_records` | `read-content / read-records` | 读取聚合内容或有序原生记录。 |
| `write_records` | `write-records` | 写入 1–512 条记录，可携带文本元数据。 |
| `write_image / write_encoded_image` | `write-image / write-encoded-image` | 写入 RGBA 像素或编码图片。 |
| `write_uris / write_html / clear` | `write-uris / write-html / clear` | 写入文件 URI、HTML，或清空剪贴板。 |

## 行为与生命周期

- ArkTS factory 必须配置应用自己的 `metadataMimeType`；共享元数据的读写方必须使用同一 MIME，具体约束见 ArkTS README。
- `ClipboardRecord` 的 `text`、`encoded_image`、`uri` 必须恰有一个；`metadata` 只能与文本一起使用。文件 URI 使用 `file://`。
- `write_image` 要求字节数恰为 `width * height * 4`。平台 PixelMap 留在 ArkTS，由单次操作释放。
- 读取被权限或签名 ACL 阻止时会返回诊断错误，需检查 `ohos.permission.READ_PASTEBOARD` 和签名配置。
- 变化计数位于注册的 `ClipboardBridgePlugin::revision()`，不是 `ClipboardClient` 的方法；可通过 `app.registered_plugin::<ClipboardBridgePlugin>()?` 取得实例。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
