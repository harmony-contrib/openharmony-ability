# Clipboard plugin

[English](README.md) | 简体中文

## Install

```bash
ohpm install @ohos-rs/ability-plugin-clipboard
```

## 装配

每个 factory 必须通过构造参数对象配置文本元数据 MIME：

```ts
import { LazyPlugin } from "@ohos-rs/ability";
import { ClipboardPlugin } from "@ohos-rs/ability-plugin-clipboard";

new LazyPlugin(() => new ClipboardPlugin({ metadataMimeType: "application/x-my-app-metadata-v1" }));
```

实例以此 MIME 写入和读取文本记录的 `metadata` 字段。
需要共享元数据的读写方必须使用同一 MIME。元数据按带框架版本字节的 UTF-8 编码，
空元数据字符串也包含版本字节。
使用不带 MIME 参数、最长 1024 个 ASCII 字符的自定义 `type/subtype`。
构造函数拒绝平台内容 MIME 和旧的无版本元数据 MIME。

框架不提供默认 MIME。读取也兼容
`application/x-gpui-ohos-text-metadata-v1` 和原始无版本的
`application/x-gpui-ohos-text-metadata`，保留既有剪贴板内容兼容性。
平台文本、HTML、URI 和图片记录使用 SDK 标准内容类型。

## License

可选择 [MIT](LICENSE-MIT) 或 [Apache-2.0](LICENSE-APACHE)。
