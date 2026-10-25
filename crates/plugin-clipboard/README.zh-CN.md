# openharmony-ability-plugin-clipboard

[English](README.md) | 简体中文

基于原生 `OH_Pasteboard` 与 UDMF 的系统剪贴板访问插件。配套 HAR 保留 `ohos.clipboard` / async / `["ability"]` 的成对注册身份，数据读写完全在 Rust 原生层完成。

## 接入

```rust
use openharmony_ability_plugin_clipboard::{ClipboardBridgePlugin, ClipboardExt};

app.register_plugin(ClipboardBridgePlugin::default())?;
let clipboard = app.clipboard()?
    .with_metadata_mime_type("application/x-my-app-metadata-v1")?;
clipboard.write_text("Hello OpenHarmony").await?;
let records = clipboard.read_records().await?;
```

```ts
import { LazyPlugin } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

new LazyPlugin(() => new ClipboardPlugin());
```

完整接口与错误类型说明见 [English README](README.md)。
