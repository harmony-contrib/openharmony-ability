# openharmony-ability-plugin-audio

[English](README.md) | 简体中文

通过 Ability 桥接驱动可复用的具名 `AVPlayer` 音频播放会话，并显式管理文件描述符所有权。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-audio` |
| ArkTS HAR | `@ohos-rs/ability-plugin-audio` |
| 插件 ID | `ohos.audio` |
| 执行模式 | `AsyncBridge` / `invokeAsync` |
| 前置 context | `["ability"]` |

## 接入

在已有 `openharmony-ability` 应用中添加依赖，并在 `#[ability]` 初始化时注册 Rust facade：

```toml
[dependencies]
openharmony-ability-plugin-audio = "1.0.0-beta.3"
```

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;
use openharmony_ability_plugin_audio::AudioBridgePlugin;

#[ability]
fn configure_ability(app: OpenHarmonyApp) {
    app.register_plugin(AudioBridgePlugin)
        .expect("register the plugin once");
}
```

应用还需安装对应 HAR，将 factory 合入已有 `NativeAbility.bridgePlugins`，保留 native module 和页面配置：

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AudioPlugin } from "@ohos-rs/ability-plugin-audio";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AudioPlugin())];
}
```

HAR 依赖和平台实现见 [ArkTS README](../../plugins/audio/README.zh-CN.md)。

## Rust 使用方式

在应用已有的 Rust executor/worker 中调用异步函数；不要在 N-API 主线程 `block_on` 等待桥接 future。

```rust
use std::os::fd::AsFd;
use napi_ohos::Result;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_audio::{AudioClient, AudioExt, AudioUpdateRequest};

async fn play_sound(app: &OpenHarmonyApp, file: &std::fs::File) -> Result<()> {
    let client: AudioClient = app.audio()?;
    client
        .update(
            AudioUpdateRequest {
                player: "bell".into(),
                replace: true,
                release: false,
                play: true,
                volume: 0.8,
                report_errors: true,
                label: "bell.wav".into(),
            },
            Some(file.as_fd()),
        )
        .await
}
```

| Rust API | action | 行为 |
| --- | --- | --- |
| `AudioClient::update` | `update` | 替换音源、更新音量/播放状态或释放具名播放器会话。 |

## 行为与生命周期

- 通过 `AudioClient::update` 单独传入 `BorrowedFd`，`AudioUpdateRequest` 不接受原始整型 fd；调用方需保持源文件打开直到 `update` 返回。
- ArkTS 在等待播放器创建或释放旧播放器之前，会同步调用 `fs.dup` 复制文件描述符；插件持有复制出的 `fs.File` 直至播放器完全释放，且不会关闭借用的源描述符。
- 替换音源会等待前一个播放管线释放完成后再创建新播放器；清空或释放（`release: true` 或 `replace: true` 且 `source = None`）在清理完成后才返回确认。
- `volume` 必须为 `0.0..=1.0` 内的有限浮点数，`player` 不能为空，`source.is_some()` 要求 `replace: true`，`release: true` 时不可同时传入 `source` 或设置 `play: true`。
- 更新返回成功仅代表描述符已复制并已调度播放器状态转换，不代表异步解码或播放已完成；`report_errors: true` 时会在本地输出包含 SDK 错误和 `label` 的告警日志。

client 绑定创建时的 bridge session；session 关闭后重新从当前 app 获取。完整契约见 [Rust 源码](src/lib.rs) 及 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE).
