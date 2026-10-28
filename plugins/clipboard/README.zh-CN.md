# @ohos-rs/ability-plugin-clipboard

[English](README.md) | 简体中文

这是 `openharmony-ability-plugin-clipboard` 的 ArkTS HAR。它只提供成对注册身份，剪贴板数据
操作全部通过 Rust facade 的原生 `OH_Pasteboard` 完成；HAR 不导入 pasteboard、不传输剪贴板
数据、不弹出权限提示、不做图片转换，也不安装变更监听。

## Install

```bash
ohpm install @ohos-rs/ability-plugin-clipboard
```

## 装配

在应用 `oh-package.json5` 中添加同版本依赖：

```json5
{
  "dependencies": {
    "@ohos-rs/ability": "1.0.0-beta.4",
    "@ohos-rs/ability-plugin-clipboard": "1.0.0-beta.4"
  }
}
```

```ts
import { LazyPlugin, NativeAbility } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

export default class EntryAbility extends NativeAbility {
  public bridgePlugins = [new LazyPlugin(() => new ClipboardPlugin())];
}
```

Rust 侧需注册 `ClipboardBridgePlugin` 并直接调用剪贴板 facade，示例见
[Rust facade README](../../crates/plugin-clipboard/README.zh-CN.md)。

## Plugin 契约

| 字段 | 值 |
| --- | --- |
| `id` | `ohos.clipboard` |
| `execution` | `async` |
| `requires` | `["ability"]` |

HAR 不包含任何剪贴板 action。`invokeAsync` 对所有 action 直接报错并指向 Rust 原生 facade，
这是有意设计，不存在回退路径。文本、HTML、编码图片、URI 和多 MIME record 的读写都通过
`ClipboardClient` 完成。

## 运行限制

- metadata MIME 在 Rust 侧通过 `ClipboardClient::with_metadata_mime_type` 配置；HAR
  构造函数不接受任何选项。
- Rust crate 与 HAR 必须来自**同一个源码版本**。
- `read_authorized_records` 不会弹出授权提示。需通过应用自身的权限流程获取原生粘贴访问权或
  `ohos.permission.READ_PASTEBOARD`，再调用 `read_records`。
- revision 是原生拉取查询（crate feature `api-18`），桥接层没有订阅或变更事件。

线程、生命周期与契约验收规则见[插件开发规范](../../docs/plugin-development-standard.md)。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
