# @ohos-rs/ability-plugin-audio

[English](README.md) | 简体中文

驱动可复用的具名 `AVPlayer` 音频播放会话，并显式管理文件描述符所有权。

这是 [`openharmony-ability-plugin-audio`](../../crates/plugin-audio/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-audio
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-audio": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { AudioPlugin } from "@ohos-rs/ability-plugin-audio";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new AudioPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `AudioBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-audio/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.audio` |
| `execution` | `async` |
| `requires` | `["ability"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `AudioClient::update` | `update` | 替换音源、更新音量/播放状态或释放具名播放器会话。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应（`ohos.audio.UpdateRequest` → `ohos.audio.UpdateResponse`）；平台对象留在 ArkTS。

## 运行限制

- 通过 `AudioClient::update` 单独传入 `BorrowedFd`，播放配置中不包含调用方自填的整型描述符；保持源文件打开直至更新确认返回。
- ArkTS 在等待播放器创建或释放旧播放器前，同步使用 `fs.dup` 复制文件描述符；插件持有生成的 `fs.File` 直至播放器完全释放，不会关闭借用的源描述符。
- 替换音源会等待前一个播放管线释放后再创建新播放器；清空或释放播放器仅在清理完成后返回确认；`onDispose` 也会等待挂起的创建和替换任务完成。
- 创建、配置、准备、播放及解码器回调失败时会自动释放播放器并关闭复制句柄；SDK 复制描述符失败会直接拒绝本次更新并保持现有播放器不变。
- 更新返回成功仅确认所有权交接并调度播放，不代表异步解码或播放已完成；`reportErrors` 开启时会在本地输出包含 SDK 错误和音源标签的告警日志。

当前实现见 [插件源码](src/main/ets/AudioPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE).
