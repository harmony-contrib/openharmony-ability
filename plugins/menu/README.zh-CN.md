# @ohos-rs/ability-plugin-menu

[English](README.md) | 简体中文

管理窗口菜单栏、弹出菜单、可见性和预定义菜单动作。

这是 [`openharmony-ability-plugin-menu`](../../crates/plugin-menu/README.zh-CN.md) 的 ArkTS 平台实现。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-menu
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖；仓库内部依赖继续使用 `workspace:*`：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.3",
    "@ohos-rs/ability-plugin-menu": "1.0.0-beta.3"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { MenuPlugin } from "@ohos-rs/ability-plugin-menu";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new MenuPlugin())];
}
```

将 factory 合入已有 Ability，保留 native module 与页面配置。每个 session 创建新实例，不跨 Host 复用。Rust 侧还需在 `#[ability]` 中注册 `MenuBridgePlugin`，完整示例见 [Rust facade README](../../crates/plugin-menu/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.menu` |
| `execution` | `async` |
| `requires` | `["ui-context"]` |

| Rust API | action | 行为 |
| --- | --- | --- |
| `set_menubar / set_menu_json` | `set-menubar` | 替换指定窗口的菜单数据。 |
| `popup` | `popup` | 在指定窗口弹出菜单。 |
| `set_menubar_visible / is_menubar_visible` | `set-menubar-visible / —` | 修改可见性，或读取 Rust 缓存。 |
| `execute_predefined` | `execute-predefined` | 执行复制、粘贴、窗口操作等预定义动作。 |

业务通过 Rust facade 调用，Host 分发具名 N-API 请求和响应；平台对象留在 ArkTS。

## 运行限制

- 需要 `DefaultXComponent` 对应的 UI context 就绪及窗口菜单挂载回调；主窗口标识为 `main`，子窗口使用其数值 ID 的字符串。
- 菜单数据相关字段和模型见 `MenuSetMenubarRequest`、`MenuPopupRequest`、`MenuItemData` 源码；示例不需要创建新的桥接协议。
- `is_menubar_visible` 读取可见性与内容缓存，不是同步平台查询；只有最近成功更新的缓存可反映已提交状态。
- 通过 `register_menu_event_sender` 和 `register_menu_open_event_sender` 注入 crossbeam sender；第一次注册生效，业务方保留并消费 receiver。
- ArkTS 包负责菜单栏挂载、下拉状态、快捷键匹配和平台动作；core 不反向依赖菜单插件。

当前实现见 [插件源码](src/main/ets/MenuPlugin.ets)，完整规范见 [插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
