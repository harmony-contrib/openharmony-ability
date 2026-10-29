# OpenHarmony Ability

[English](README.md) | 简体中文

> 本项目仍在开发中，API 尚未稳定。

`openharmony-ability` 为 OpenHarmony 应用提供 native 集成：Rust 生命周期管理，以及可由 Rust 和 C/SDL native module 共用的 ArkTS 入口。

发布说明和各包变更见 [changelog](CHANGELOG.md)。

## 架构

OpenHarmony 应用由回调驱动，需要遵守两项约束：

1. 不要阻塞主线程。
2. `run_loop` 不会替业务保留资源；需要跨初始化阶段存活的资源必须具有稳定的所有权。

![架构](/fixtures/openharmony-ability.png)

## 仓库结构

- `crates/ability` — Rust 生命周期与运行时支持
- `crates/derive` — `#[ability]` 宏
- `native_ability` — Rust 和 C/SDL native module 共用的 ArkTS 包
- `plugins/*` — 独立 ArkTS 能力包
- `demo` — 统一 Harmony demo 工程
- `rust_example/demo_native` — 统一 native demo 实现

## 开发环境

```bash
pnpm install
```

这会从 `ohpm-cli` 0.5.0 安装 `ohpm-rs`，再安装 workspace 包和 demo 的 ArkTS 依赖。
内部 ArkTS 依赖使用 `workspace:*`，解析到 `ohpm-workspace.yaml` 中的源码包。
修改清单后运行 `pnpm run install:ohpm` 重新安装 ArkTS 依赖。

仓库命令使用 Node 和 Rust 工具，支持 Linux 与 macOS。原生 Windows 尚未在本仓库验证，
请使用 WSL 下的 Linux 工具和 SDK。

运行 `npm run pack`，为每个 workspace 包生成 HAR 到 `dist/`。

运行 `npm run format` 格式化 Rust 与 ArkTS。Git hooks 通过 prek 执行格式和 lint 检查；
CI 对所有文件运行 prek，并对支持的 OpenHarmony target 执行 Rust clippy。

## 使用

1. 添加 Rust 依赖：

```bash
cargo add openharmony-ability
cargo add openharmony-ability-derive
cargo add napi-ohos
cargo add napi-derive-ohos
cargo add napi-build-ohos
```

2. 实现 native 入口（Rust 示例）：

```rust
use ohos_hilog_binding::hilog_info;
use openharmony_ability::OpenHarmonyApp;
use openharmony_ability_derive::ability;

#[ability]
fn openharmony_app(app: OpenHarmonyApp) {
    app.run_loop(|event| {
        hilog_info!(format!("event: {:?}", event.as_str()).as_str());
    });
}
```

3. 在 ArkTS 中使用 `NativeAbility`：

```ts
import { NativeAbility } from "@ohos-rs/ability";
import Want from "@ohos.app.ability.Want";
import { AbilityConstant } from "@kit.AbilityKit";

export default class EntryAbility extends NativeAbility {
  public moduleName: string = "demo_native";

  onCreate(
    want: Want,
    launchParam: AbilityConstant.LaunchParam
  ): void {
    super.onCreate(want, launchParam);
  }
}
```

4. 构建 native module：

```bash
cd rust_example/demo_native
ohrs build --arch arm64
```

## Demo

- Harmony demo 工程：`demo`
- Native demo（Rust）：`rust_example/demo_native/src/lib.rs`
- ArkTS 包源码：`native_ability`

## 插件配置

插件 factory 使用业务提供的协议配置：

```ts
new LazyPlugin(() => new ClipboardPlugin({ metadataMimeType: "application/x-my-app-metadata-v1" }));
new LazyPlugin(() => new NotificationPlugin({ scheme: "my-app-notification" }));
```

将独立插件的 factory 注册到 Ability 的 `bridgePlugins` 数组。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
