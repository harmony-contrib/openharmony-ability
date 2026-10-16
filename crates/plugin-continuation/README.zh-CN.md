# openharmony-ability-plugin-continuation

[English](README.md) | 简体中文

读取系统应用接续的恢复状态，并预存源设备的接续快照。它是 core 生命周期状态的同步 Rust facade，没有独立的 ArkTS HAR、BridgePlugin 或出站 action。

## 契约

| 项目 | 值 |
| --- | --- |
| Rust crate | `openharmony-ability-plugin-continuation` |
| 平台集成 | `NativeAbility.onCreate` / `onNewWant` / `onContinue` |
| 执行方式 | 同步读取 Rust app 状态；源快照由 core export 读取 |
| 插件注册 | 无需额外注册 |

## 接入

```toml
[dependencies]
openharmony-ability-plugin-continuation = "1.0.0-beta.3"
```

应用继续使用现有的 `NativeAbility` 与 `#[ability]` 生命周期接入。不要创建不存在的 `ContinuationBridgePlugin` 或 ArkTS factory。

## Rust 使用方式

```rust
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_plugin_continuation::{set_continuation_data, ContinuationExt};

fn restore(app: &OpenHarmonyApp) -> Option<String> {
    let continuation = app.continuation();
    if continuation.is_continuation_restore() {
        Some(continuation.take_continuation_data())
    } else {
        None
    }
}

fn prepare_snapshot(snapshot: String) {
    set_continuation_data(snapshot);
}
```

| API | 行为 |
| --- | --- |
| `is_continuation_restore` | 重复查询恢复标记，不消费数据。 |
| `take_continuation_data` | 取出并清空恢复数据，之后返回空字符串。 |
| `set_continuation_data` | 覆盖进程级源快照，等待系统调用 `onContinue`。 |

## 时序与限制

- 恢复数据在对应的 Ability 生命周期投递后才可用；不能假定初始化/setup 中已经收到冷启动接续状态。
- 源快照由 `onContinue` 同步读取但不消费，取消迁移后可重试。空快照会让平台接续回调拒绝迁移。
- 本 crate 不校验快照大小或应用数据格式，由业务遵守平台预算并处理恢复内容。
- 接续由系统 UI 发起，本 facade 不提供主动启动设备间迁移的 API。

实现见 [Rust 源码](src/lib.rs) 和 [ArkTS runtime](../../native_ability/README.zh-CN.md).

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
