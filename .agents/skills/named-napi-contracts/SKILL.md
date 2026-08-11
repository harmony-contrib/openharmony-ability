---
name: named-napi-contracts
description: >-
  openharmony-activity 仓库内置插件（crates/plugin-* 与 plugins/* 成对开发）的编码规范：
  实现或修改插件 action 的 request/response 时，必须优先使用具名 N-API 类型
  （#[napi(object)] + impl_bridge_napi_type!），不得使用 JSON 协议
  （BridgeJson / call_json / bridgeJson / requireBridgeJson）。
  ArkTS → Rust 的反向平台事件同样必须使用具名 N-API 类型；并给出 Rust 侧与 ArkTS 侧的
  完整实现步骤与验证清单。
  当任务涉及新增插件、新增 action、修改现有内置插件契约、或 review 插件代码时使用。
---

# 具名 N-API 契约优先（Named N-API Contracts）

本仓库（openharmony-ability）在 0.4.0-beta.7 → 1.0.0 重构后，所有内置插件的
request/response 已从 JSON envelope 迁移为**具名 N-API 类型**。新代码必须遵守同样规则。

## 1. 为什么不用 JSON

- JSON envelope 丢失类型信息：Rust 侧 `String`、`Vec<u8>`、`#[napi(object)]` 在桥上是
  不同的 N-API value，JSON 会把它们全部压平成字符串，且无法区分。
- `typeName` 是稳定 ABI 契约：Rust 与 ArkTS 两端按名字校验，类型不匹配在边界上
  **确定性报错**，而不是运行时悄悄丢字段。
- 零序列化开销：具名类型直接以真实 N-API value 传输（object / string / Uint8Array），
  不经过 JSON.stringify / JSON.parse。
- 文档依据：`docs/plugin-development-standard.md` §3「请求与响应：具名 N-API 类型，不使用 JSON」。

## 2. 必须遵守的规则

### 规则 1：内置插件 request/response 一律具名 N-API

新建或修改任何内置插件 action（permission、app-control、window、webview 及未来插件），
请求与响应**都必须是** `#[napi(object)]` + `impl_bridge_napi_type!`，禁止：

- Rust 侧 `BridgeJson<T>` / `BridgeClient::call_json`
- ArkTS 侧 `bridgeJson` / `requireBridgeJson`
- 任何把 payload 包成 JSON 字符串再传输的做法

### 规则 2：没有 JSON 例外

当前 bridge 没有供插件使用的 JSON event port。request、response 以及 ArkTS → Rust 的平台回调
全部使用具名 N-API value；历史 `BridgeJson<T>`、`call_json`、`bridgeJson`、`requireBridgeJson` 和
`context.emit(..., JSON.stringify(...))` 一律不得在新代码中出现。反向回调使用
`context.invokeNativeSync(event, requestTypeName, responseTypeName, value)`，Rust 在
`BridgePlugin::on_main_thread_event` 中同步处理。

### 规则 3：typeName 命名约定

- 内置插件：以完整 plugin ID 为前缀，如 `ohos.webview.CreateRequest`、
  `ohos.permission.PermissionResponse`、`ohos.window.AvoidAreaResponse`、
  `ohos.app_control.TerminateRequest`。
- 业务类型：`<domain>.<TypeName>`，如 `account.LoginToken`、`demo.Profile`。
- 内置标量：`std.string`、`std.bytes`、`std.bool`、`std.i32`、`std.f64`。
- typeName 字符集：`^[A-Za-z0-9._-]+$`（`validate_identifier` 强制）。

### 规则 4：action 命名与 ABI 演进

- action 使用 kebab-case 动词短语：`create`、`set-visible`、`load-url`、
  `get-avoid-area`、`evaluate-script`、`clear-all-browsing-data`。
- 插件没有独立数字版本。已有 action/typeName 的字段和语义必须稳定；不兼容修改应新增
  action/typeName（必要时使用新插件 ID），并在 Rust/ArkTS 两端同时实现。
- ArkTS factory 不配置 native module。Rust registry 在初始化后导出 `{ id, execution, requires }`，
  `BridgeHost` 自动选择同 ID factory 并硬校验模式/context。

## 3. Rust 侧实现步骤

以 `crates/plugin-permission/src/lib.rs` 为模板：

```rust
#[napi(object)]
#[derive(Clone, Debug)]
pub struct PermissionRequestPayload {
    pub permissions: Vec<String>,
}

impl_bridge_napi_type!(PermissionRequestPayload, "ohos.permission.PermissionRequest");

#[napi(object)]
#[derive(Clone, Debug)]
pub struct PermissionResponsePayload {
    pub codes: Vec<i32>,
}

impl_bridge_napi_type!(PermissionResponsePayload, "ohos.permission.PermissionResponse");
```

要点：

1. 字段用 **snake_case**（N-API 自动映射为 ArkTS camelCase）。
2. 调用入口是 `BridgeRuntime::call_async::<P, Req, Resp>`，`Req`/`Resp` 由类型系统
   固定 typeName，Rust 侧无需运行时校验 typeName。
3. 业务校验放 Rust facade：非空、非法值、结果长度匹配
   （参考 `validate_request` 与 `codes.len() != permissions.len()` 检查）。
4. 每个契约类型都要有单元测试断言 TYPE_NAME，防止意外改名：

```rust
#[test]
fn permission_uses_stable_named_napi_contracts() {
    assert_eq!(
        <PermissionRequestPayload as BridgeNapiType>::TYPE_NAME,
        "ohos.permission.PermissionRequest"
    );
}
```

## 4. ArkTS 侧实现步骤

以 `plugins/permission/src/main/ets/PermissionPlugin.ets` 为模板：

1. 顶部定义 typeName 常量：

```ts
const PERMISSION_REQUEST_TYPE = "ohos.permission.PermissionRequest";
const PERMISSION_RESPONSE_TYPE = "ohos.permission.PermissionResponse";
```

2. 定义 camelCase 接口与响应类：

```ts
interface PermissionRequestPayload {
  permissions: string[];
}

class PermissionResponse {
  readonly codes: number[];
  constructor(codes: number[]) {
    this.codes = codes;
  }
}
```

3. 解析入口**必须校验 typeName**，不匹配直接 throw（不能静默接收）：

```ts
function parsePermissions(payload: BridgeTypedValue): string[] {
  if (payload.typeName !== PERMISSION_REQUEST_TYPE || typeof payload.value !== "object") {
    throw new Error(`requires bridge type ${PERMISSION_REQUEST_TYPE}`);
  }
  // ...语义校验（非空数组、非空字符串）
}
```

4. 返回时**必须回填响应 typeName**，且响应类型名与 Rust 侧 `impl_bridge_napi_type!`
   的第二个参数一字不差：

```ts
return { typeName: PERMISSION_RESPONSE_TYPE, value: new PermissionResponse(codes) };
```

5. `invokeAsync` / `invokeSync` 开头校验 `context.isActive()`，action 不支持时
   `throw new Error(\`Unsupported <plugin-id> action '${action}'\`)`。

## 5. ArkTS → Rust 平台回调

平台回调若需要 Rust 立即决策，ArkTS 使用具名 N-API direct event：

```ts
const response = context.invokeNativeSync(
  "navigation-request",
  "ohos.webview.NavigationRequest",
  "ohos.webview.NavigationResponse",
  request,
);
```

Rust 在 `BridgePlugin::on_main_thread_event` 中立即解码 request 并返回对应 response。不得保存
ArkTS object/function，也不得将响应交给 worker 后再返回。完整线程与生命周期规则见
`docs/plugin-development-standard.md` §4、§5、§7。

## 6. 新增插件的完整落地清单

- [ ] Rust crate：`crates/plugin-<name>/src/lib.rs`
  - [ ] `#[napi(object)]` 请求/响应结构体 + `impl_bridge_napi_type!`
  - [ ] `impl BridgePlugin`：`type Mode`、`ID`、`REQUIRED_CONTEXTS`
  - [ ] 扩展 trait（如 `PermissionExt`）挂在 `OpenHarmonyApp` 上，core 不感知
  - [ ] `validate_*` 业务校验
  - [ ] 单测断言 typeName / 请求校验 / 响应字段完整
- [ ] ArkTS HAR：`plugins/<name>/src/main/ets/<Name>Plugin.ets`
  - [ ] 导出 plugin class 并由 `LazyPlugin(() => new <Name>Plugin())` 创建（id/execution/requires 与 Rust 一致，不配置 module）
  - [ ] typeName 常量 + 解析校验 + 响应回填
  - [ ] `execution` 与 Rust `type Mode` 一致：async → `invokeAsync`，sync → `invokeSync`
- [ ] `Cargo.toml` workspace 与 `native_ability/oh-package.json5` 登记
- [ ] demo 接入（如 `demo/entry/.../EntryAbility.ets` 的 `bridgePlugins` 数组）
- [ ] 文档：`docs/plugin-development-standard.md` §3.3 契约基线补充新行
- [ ] 验证：`cargo check --workspace`、`cargo clippy --workspace --all-targets`、
  `cargo test -p openharmony-ability-plugin-<name> --lib`、`pnpm run format:check`

## 7. Review 时快速排查

```bash
# 新插件/新文件里出现 JSON 桥用法 = 违规
rg -n "BridgeJson|call_json|bridgeJson|requireBridgeJson" crates/plugin-* plugins/*/src

# 确认 request/response 都有 impl_bridge_napi_type
rg -n "impl_bridge_napi_type" crates/plugin-*/src

# 确认 ArkTS 侧解析入口校验了 typeName
rg -n "typeName !==|typeName ===" plugins/*/src
```

## 参考

- 现有契约表：见 [references/contract-table.md](references/contract-table.md)
- 开发规范：`docs/plugin-development-standard.md`（§3 命名契约、§4 线程模式）
- 核心实现：`crates/ability/src/bridge/mod.rs`（`impl_bridge_napi_type!`、
  `BridgeNapiType`、`BridgePlugin`）
- 完整范例：`crates/plugin-permission` + `plugins/permission`（异步、ability 上下文）、
  `crates/plugin-app-control` + `plugins/app-control`（同步、主线程 Env）
