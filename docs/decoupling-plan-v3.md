# openharmony-ability ↔ Tauri 解耦方案（v3 — 三轮审计收敛后终版）

> **状态**：基于 2026-08-20 三轮审计修复 + 死代码清理完成后的代码现状（ohdev @ 1dfc477），经双代理实证审计（本体仓 + 8 个下游消费仓）
> **前置**：v1（`origin` 仓 docs/decoupling-plan.md，5 组接缝）→ v2（2026-08-12 bridge 迁移审计版）→ 本版
> **判据**（不变）：「是否 Tauri-shaped」是判据，「是否组合了 OHOS API」不是

## 〇、v2 以来的完成情况（v2 大部分阶段已落地，本版为收敛残项）

| v2 条目 | 现状 | 证据 |
|---|---|---|
| 接缝 3 cursor 全局 | ✅ 已删，tao 本地 `CURSOR_X/Y: AtomicU64`（tao mod.rs:41-42） | 核心仓零 `CURSOR_POSITION` 命中 |
| 接缝 4 旧 channel（ability::menu/statusbar） | ✅ 已删（含 statusbar/ 模块整目录、menu 五子模块） | `crates/ability/src/menu/` 仅剩 mod.rs |
| 接缝 5 dispatcher | ✅ init_forwarder/DISPATCHER 已删，global-shortcut 全套经 `GlobalShortcutClient`（plugins-workspace lib.rs:303,343,449） | init_forwarder 当前工作仓零命中（origin 基线快照仓除外） |
| 接缝 2 deep-link 旧 API | ✅ take_initial_want_uri/take_want_parameters 函数已删，deep-link + single-instance 均经 `DeepLinkClient`（take_initial_uri/take_want_parameters 方法） | plugins-workspace 深链/单实例零核心 `::` 命中 |
| N4 start_popup_forwarder | ✅ 已删，MenuBridgePlugin facade 取代（tauri menu/plugin.rs:933-942 注释自述） | |
| N5/N7/N11/N12/N13/N14 consumer 切 facade | ✅ 全部完成（window 运维/menu 三 API/webview/statusbar/clipboard/autostart/url/全局快捷键） | 见 §二 消费面总表 |
| N8 tauri_window_id 键 | ❌ 未处理（见 P0-1） | NativeAbility.ets:492,506 |
| N9 helper/webview.rs 死模块 | ✅ 已删 | helper/ 仅剩 4 个子模块（+ mod.rs） |
| N10 drag_and_drop 空壳 feature | ✅ 已移除 | 两处 Cargo.toml 零命中 |
| N16 blanket re-export | ✅ tao/tauri 均收敛为显式命名列表 | tao ohos.rs:134-140、tauri ohos.rs:11-16 |
| ArkHelper.ets 删除（v2 阶段 4） | ✅ 已删（含 9 个 ArkTS helper + `_legacy/`） | 死代码清理 commit 1dfc477 |
| §3.4 unsoundness helper/mod.rs | ✅ 已修（无 mem::forget/ptr::read/ManuallyDrop） | helper/mod.rs:25-34 |
| §3.4 on_back_press_intercept transmute | ✅ 已修（签名改 `'static`） | app.rs:756-758 |
| MenuPlugin.ets/StatusbarPlugin.ets（v2 §十一） | ✅ 已创建并注册 | plugins/menu、plugins/statusbar |

---

## 一、架构现状（v3 基线）

```
┌─ tauri 生态仓（tao / wry / muda / tray-icon / tauri core / plugins-workspace / window-vibrancy）
│    经 facade client / ext trait 消费；业务 API 已 100% facade 化
│    ↓ 仅剩三类核心直调：运行时入口类型 / 窗口创建原语 / close 队列
├─ crates/plugin-*（14 个桥接 facade，全部只依赖核心 + napi/serde 系）
│    对 Tauri 零认知：零 tauri 系 Cargo 依赖、零横向依赖、无 muda/tray-icon/EventLoopProxy 注释
│    事件模式两种：注入 sender（menu/statusbar，channel 归消费者）/ 自持 receiver（global-shortcut/webview print）
└─ crates/ability（核心）
     运行时集成层：OpenHarmonyApp / Event+run_loop(单消费者) / waker / close 队列 ←─ 剩余耦合集中区
     遗留死代码：helper/{account,opener,updater} + 对应 legacy 模块（全部 #[deprecated]，零 plugin 消费者）
```

**已达标**：第三方非 Tauri 插件可仅凭 openharmony-ability（plugin facade + 核心能力）实现功能；tauri 仓单向依赖；plugin crate 层对 Tauri 零认知。

---

## 二、消费面总表（下游审计结论，作为 v3 决策输入）

**仍绕过 facade 的直调（4 处）**：

| 符号 | 消费方 | 位置 | 性质 |
|---|---|---|---|
| `create_os_window` / `WindowCreateParams` | tao | tao mod.rs:12,1020,1034 | plugin-window 无窗口创建 API（facade 缺口） |
| `drain_pending_window_closes` | tao（re-export） | tao ohos.rs:136 | 接缝 1 残留（见 §三-D） |
| `HuaweiAccount` / `AccountInfo` | plugins/huawei-account | ohos.rs:30,41,52; models.rs:28,29 | 无 plugin-account facade（见 §三-C） |
| `OpenHarmonyApp::updater()`（`Updater` via helper/updater TSFN） | plugins/updater | updater ohos.rs:61,98（经 `tauri::ohos::APP`，不直 import 核心，**消费审计需经方法调用链才能发现**） | 核心特权能力（见 §三-P2-1） |

**合法核心耦合（运行时入口类型，不迁）**：`OpenHarmonyApp`（6 仓 set_ohos_app/RuntimeInitArgs）、`BridgeRuntime`（tao/wry）、`get_main_thread_env`（tao/tauri）、事件/输入类型族（tao）。tauri-runtime `RuntimeInitArgs.app` 已注释自述 "legitimate coupling"（tauri-runtime lib.rs:404-406）。

**冗余核心 Cargo 依赖（源码零核心引用，可直接移除）**：muda Cargo.toml:86；plugins-workspace 的 clipboard-manager:42 / opener:65 / single-instance:45 / deep-link:51 / autostart:33 / global-shortcut:34。

---

## 三、剩余解耦项（按优先级）

### P0 — 命名耦合渗入平台代码（本仓内，零跨仓协同）

**P0-1 ArkTS `tauri_window_id`/`tauri_transparent` want 键 — 死读取，直接删除**
- 位置：`NativeAbility.ets:492,506`（读取），调用方 :242,:371-372,:470
- 事实：**全工作区零写入方**（tao/wry/tauri/tray-icon/模板/gen 目录 grep 均无），readWindowId 恒返 0、readTransparent 恒返 false；多窗口实际走 WindowManager 悬浮子窗口，不经多 ability 实例。这是旧"多实例传参"契约的尸体。
- 修法：删除两个读取函数 + 3 处调用点改字面量 `0`/`false`（或直接内联默认值）。与 Rust 侧 window/mod.rs:272 注释（"ohos_window_id 协议已不使用"）的口径统一为"want 传参协议已废弃"。
- 风险：低（现网行为即 0/false，删除不改行为）。

**P0-2 UrlPlugin.ets `file://com.tauri.api` 沙箱标记 — 硬编码消费者 bundle 名**
- 位置：`plugins/url/.../UrlPlugin.ets:60`（SANDBOX_MARKERS）
- 事实：用示例应用 bundle 名硬编码检测"自身沙箱路径"。任何其他 bundle 的 Tauri OHOS 应用此标记永不命中（另两个标记 `/data/storage/`、`/data/app/` 已覆盖通用场景，此条冗余且具误导性）。
- 修法：删除该条目，或改为运行时拼 `file://` + `context.applicationContext.applicationInfo.bundleName` 动态生成。
- 风险：低。

### P1 — 结构接缝（需小范围跨仓协同或设计决策）

**P1-1 huawei-account facade 缺口**
- 事实：plugins-workspace/huawei-account 直调核心 `HuaweiAccount::new()/login()/silent_login()/logout()` + `AccountInfo`（ohos.rs:30,41,52），无 plugin-account crate。
- 决策点（二选一）：
  - **A（推荐）**：确认"华为账号一键登录"为**核心特权能力**，在核心仓标注合法保留，与 `RuntimeInitArgs.app` 同级归类。**已有先例支撑**：updater 走的就是同款模式（`OpenHarmonyApp::updater()` ext 方法 + 核心 helper TSFN，见 P2-1）——核心特权能力经 app handle 方法暴露是既有惯例；
  - B：新建 plugin-account facade（成本中，收益仅是形式统一——账号 API 本身无 Tauri 形状）。
- 倾向 A：判据是"是否 Tauri-shaped"而非"是否在核心仓"；HuaweiAccount API 是纯 OHOS 能力，**放核心仓不违反判据**。

**P1-2 `INITIAL_WANT_URI`/`WANT_PARAMETERS` pub static 跨 crate 直读**
- 事实：核心 pub static（app.rs:858,872），plugin-deep-link 直接 lock 读写（lib.rs:110,121）；注释自述 "Made pub so the plugin-deep-link facade can read it without a separate accessor"。
- 修法：核心侧改 `pub fn take_initial_want_uri() -> String` / `pub fn take_want_parameters() -> String` 访问器（take 语义封在核心），plugin-deep-link 改调访问器，static 转 `pub(crate)`。纯本仓 + plugin-deep-link 两处改动。
- 风险：低（机械重构）。

**P1-3 `run_loop` unsafe transmute（unsoundness 残项）**
- 位置：app.rs:742-749（`Box<dyn FnMut(Event)+'a>` → `'static` transmute，靠 HAS_EVENT 单次调用 + app 存活保证）
- 修法：签名改 `'static`（同 on_back_press_intercept 已修先例），由调用方（tao）负责闭包所有权。需同步改 tao 侧调用一处。
- 风险：低-中（闭包内引用需在 tao 侧消解）。

**P1-4 `unsafe impl Send/Sync for OpenHarmonyApp` + `// TODO: Can we remove this?`**
- 位置：app.rs:777-779
- 修法：审计 OpenHarmonyAppInner 字段的线程安全性（napi Env/ObjectRef 的跨线程约束），要么给出安全性论证补 SAFETY 注释删 TODO，要么改 Arc<Mutex> 内部可变性消除 unsafe impl。属 unsoundness 收尾，非 Tauri 耦合本体。

### P2 — 死代码与噪音清理（零行为变化）

**P2-1 helper/ legacy 处置 — 审计修正：opener 是死代码，account/updater 是活代码**

> ⚠️ 初稿曾把三者都判为死代码，实地复核推翻：account/updater 有活消费者，仅 opener 可删。判死标准必须包含"经 app handle ext 方法（`app.updater()`）的间接消费链"，不能只 grep 直接 import。

| 模块 | 状态 | 证据 | 处置 |
|---|---|---|---|
| `opener.rs` + `helper/opener.rs` | **死代码** | 下游 opener 插件经 `UrlExt` facade（open.rs:40,82 / reveal_item_in_dir.rs:108），核心 opener 零消费者 | 删除 + lib.rs re-export 收缩 |
| `account.rs` + `helper/account.rs` | **TSFN 链已断，运行时必失败** | huawei-account 插件 `features=["account"]` 直调 `HuaweiAccount`（Cargo.toml:33），但 `set_helper` 零调用 + ArkTS helper 已删 | 保留；按 P1-1 决策 A 定性为核心特权。**2026-08-21 修复为 bridge plugin 模式**：新增 `plugins/account/AccountPlugin.ets`（`ohos.account` AsyncPluginBase），`account.rs` 改经 `app.bridge()` `call_async` 调 login/silentLogin/logout action；删 `helper/account.rs` + `parse_account_info` 手动解析（Response 自动反序列化）；`HuaweiAccount::new(&OpenHarmonyApp) -> Result<Self>`（破坏性） |
| `updater.rs` + `helper/updater.rs` | **TSFN 链已断，运行时必失败** | updater 在 **default features**（ability Cargo.toml:9），plugins-workspace updater 插件经 `tauri::ohos::APP` 调 `app.updater()`，但 `set_helper` 零调用 + ArkTS helper 已删 | 保留；同上。**2026-08-21 修复为 bridge plugin 模式**：新增 `plugins/updater/UpdaterPlugin.ets`（`ohos.updater` AsyncPluginBase），`updater.rs` 改经 `app.bridge()` `call_async` 调 check/downloadAndInstall action；删 `helper/updater.rs` + `parse_check_result` 手动解析；`app.updater()` 改 `-> Result<Updater>`（破坏性）。**updater 保留在 default features**：曾评估移出，但移出需联动 tauri 核心仓 feature 声明，漏改会致 updater 插件静默编译失败，故保留 + Cargo.toml:9 注释说明（选项 A） |
| `helper/window_info.rs` | 死代码 | #[allow(dead_code)] 零调用 | 删除 |

- 删除 opener 的前置确认：全工作区 grep `openharmony_ability::opener`/`open_with_system`（核心路径形态）为零即可执行。
- account/updater 的 TSFN→bridge 迁移已**于 2026-08-21 完成**：TSFN 链已断（`set_helper` 零调用 + ArkTS helper 已删），原实现运行时必失败；现已迁移为 bridge plugin 模式（`AccountPlugin.ets` / `UpdaterPlugin.ets`），经 `OpenHarmonyApp::bridge()` 路由。

**P2-2 冗余核心 Cargo 依赖移除（7 处）**
- muda:86 + plugins-workspace 6 插件（见 §二清单）。机械删除 + cargo check 验证。
- ⚠️ 前置确认：global-shortcut（features=["global_shortcut"]）与 clipboard-manager（features=["clipboard"]）删除后，确认 feature unification 仍有其他启用方（如对应 plugin facade crate 的依赖声明），否则核心侧 feature-gated 代码失活导致编译失败——cargo check 双侧验证兜底。

### P3 — 注释/词汇中性化（纯文档，验收标准的清零任务）

| 位置 | 内容 | 处理 |
|---|---|---|
| waker.rs:7-8,18,21,23 + app.rs:163 | EventLoopProxy/tauri entry/MainEvent::UserEvent 时序契约 | 中性化为 "embedding runtime's event-loop proxy"；时序事实保留 |
| app.rs:791,797 | CloseRequested/Destroyed RunEvent 词汇 | 改 "close-requested → destroyed 生命周期（由嵌入方运行时定义）" |
| window/mod.rs:134-275 | 7 处考古注释（记录已删 get_helper 代码，点名 tao/tauri/wry） | 删除（git 历史可查） |
| plugin-webview:373 | `tauri.localhost` URL scheme | 改 "consumer-registered custom protocol" |
| plugin-webview:683 | "emit a tauri event via AppHandle" | 改 "emit an event to the embedding runtime" |
| plugin-window:377 | `set_ignore_cursor_events`（tao API 名） | 改 "consumer's ignore-cursor-events API" |
| plugin-deep-link:173-174 | 测试数据 `tauri://app/page` | 改 `myapp://page`（测试语义不变） |
| ArkTS DefaultWebview.ets:52,495-496,701 / WebviewPlugin.ets:1280-1283,1419 / GlobalShortcutPlugin.ets:23 | 消费方事实性注释 | 中性化或保留（事实性，可选） |

### D — 设计决策记录（不迁、立此存照）

**D-1 运行时集成层 = 合法耦合边界（v1/v2 反复摇摆，v3 定论）**
`OpenHarmonyApp` / `Event` + `run_loop`（单消费者）/ `create_waker` / `HAS_EVENT` / `Event::UserEvent` / `get_main_thread_env` —— 这组 API 是 OHOS ability 单主线程事件循环的镜像，**任何嵌入方**（不止 Tauri）都需要恰好一次 run_loop + 一个 waker；单消费者模型是 OHOS 平台事实（单 ability 主线程）而非 Tauri 假设。判定：**核心运行时集成层，合法保留**，仅需 P3 注释中性化。与 tauri-runtime `RuntimeInitArgs.app` 的既有定性一致。

**D-2 close 队列（接缝 1）— 机制保留 + 命名中性化，不再迁移**
- 事实：`PENDING_WINDOW_CLOSES`/`notify_window_close`/`drain_pending_window_closes`（app.rs:793-829）是 OHOS 事件系统不透传 window identity 的**平台变通**，任何嵌入方关窗都需要等价机制；v2 的"迁 tauri-runtime-wry 自建队列"方案需要 NAPI 注册入口留在 ArkTS 可达处，迁移后复杂度上升、收益为零。
- 修法：仅 P3 注释中性化（去 CloseRequested/Destroyed 词汇）+ 可选改名 `drain_window_close_requests`（tao 一处同步）。机制定为核心能力。

**D-3 `create_os_window`/`WindowCreateParams` 直调 — 接受为运行时集成层**
- 事实：窗口创建需要同步返回 window handle 给事件循环初始化路径，且语义上属"OS 级窗口创建"（任何 OHOS 应用都要的能力），plugin-window facade 定位是"已存在窗口的运维"。
- 判定：与 `OpenHarmonyApp` 同级，属 tao↔核心的运行时集成边界，**合法直调**。不做 facade 化（强行 facade 化会把创建时序的复杂性移进插件层，无净收益）。

**D-4 plugin 层事件双轨（注入 sender vs 自持 receiver）**
- 事实：menu/statusbar 用注入 sender（channel 归消费者），global-shortcut/webview print 自持 receiver。
- 判定：两种模式都是中性 bridge 模式，非 Tauri 耦合；**接受现状**，仅要求后续新增插件沿用注入 sender 模式（消费者持有 channel 生命周期更干净）。写入 plugin-development-standard.md。

---

## 四、迁移顺序（收敛版——量级远小于 v2）

```
阶段 1（本仓 P0，半天级）
        P0-1 删 tauri_window_id/tauri_transparent 死读取
        P0-2 UrlPlugin 沙箱标记去 tauri 化
        → pack.bat 重建 HAR + 真机 smoke（app 启动/子窗口/tray/菜单）
阶段 2（跨仓小改 + 本仓结构，1-2 天级）
        P1-2 want static 访问器化（核心 + plugin-deep-link）
        P1-3 run_loop 'static 化（核心 + tao 一处）
        P2-2 冗余 Cargo 依赖移除（muda + 6 插件）
        P1-4 Send/Sync TODO 处置
        → Windows + OHOS 双侧 cargo check + 真机回归
阶段 3（决策落地 + 删除，视 P1-1 决策）
        P1-1 huawei-account 定性（推荐 A：核心特权，注释标注；account/updater 同批定性）
        P2-1 opener 死代码删除（account/updater 保留定性；TSFN→bridge 迁移列为可选技术债）
        → HAR 重建 + 全量 autotest
阶段 4（注释清零，纯文档）
        P3 全表 + 验收标准复核
```

依赖约束：阶段 2 的 P1-3 需 tao 同步改，先核心后 tao；阶段 3 的 P2-1 删除前必须确认下游零引用（判死标准沿用：barrel 之外直接 importer 为零 + 下游消费面 grep）。

---

## 五、验收标准（v3 终版）

- [ ] P0 两项归零：ArkTS 无 `tauri_window_id`/`tauri_transparent`/`com.tauri.api` 字符串（grep native_ability + plugins 为空）
- [ ] P1-2：核心无 pub static WANT_PARAMETERS/INITIAL_WANT_URI（改 pub(crate) + 访问器）
- [ ] P1-3：crates/ 内 `transmute` 仅剩 mouse_event.rs C-API 回调一处（run_loop 处为零）
- [ ] P2-1：opener.rs + helper/opener.rs + helper/window_info.rs 删除；account/updater 保留（核心特权定性 + 解除 deprecated 矛盾或迁 bridge）；lib.rs 无 #[allow(deprecated)] re-export
- [ ] P2-2：muda + 6 插件 Cargo.toml 无 openharmony-ability 核心声明（huawei-account 除外，视 P1-1 决策）
- [ ] P3：非版权头 tauri/tao/wry/muda/tray-icon/AppHandle/EventLoopProxy 注释命中 = 0（事实性消费方注释按 P3 表中性化后计入）
- [ ] 双侧 cargo check 0 error（aarch64-unknown-linux-ohos + Windows host）；真机全量 autotest + smoke 通过
- [ ] 行为零回归：close 批量 drain、deep-link 冷启动/温启动、热键派发、菜单/statusBar 点击、子窗口创建/销毁

---

## 六、与 v2 差异总结

| 维度 | v2（08-12） | v3（本版） |
|---|---|---|
| 定位 | bridge 迁移后的全面清单（5 接缝 + N1-N16） | 收敛残项（v2 绝大多数条目已落地，见 §〇） |
| 剩余量 | 5 阶段、16 项遗漏、39 处注释 | 2 项 P0 + 4 项 P1 + 2 项 P2 + 注释清零 |
| 运行时集成层 | 未定性（N2/N15 悬而未决） | **定性为合法耦合边界**（D-1/D-2/D-3 定论，结束摇摆） |
| plugin crate channel | 要求"二次迁移到 muda/tray-icon" | **撤销**：channel 模式是中性 bridge 模式（D-4），plugin 层已零 Tauri 认知 |
| huawei-account | "新建 plugin-account 或确认核心特权" | 明确推荐"确认核心特权"（判据是不 Tauri-shaped，非是否在核心仓） |
| 新发现 | — | tauri_window_id 零写入方死读取（P0-1）、com.tauri.api 硬编码（P0-2）、7 处冗余 Cargo 依赖（P2-2）、account/updater 是经 app handle ext 方法消费的活代码且仍走 deprecated TSFN（P2-1 修正） |

## 七、一句话总结

pluginize 重构 + 三轮审计 + 死代码清理后，**facade 迁移已实质完成**（下游业务 API 100% 经 facade、plugin 层零 Tauri 认知）；剩余工作是两处渗入平台代码的 Tauri 命名（P0，零写入方死代码级）、四项小结构接缝（P1）、一组 helper legacy 死代码（P2）和注释清零（P3），外加把 v1/v2 悬而未决的"运行时集成层"正式定性为合法耦合边界（D-1/D-2/D/3）——解耦工程到此收敛。
