# 1.0.0-beta.3

- Add window-specific surfaces, redraw, input, resize, focus and close events, with per-window
  native handles, geometry, avoid areas, IME state and wake/redraw routing.
- **Breaking**: `Event::WindowResize` now carries `{ window_id, size }`; applications must update
  event matches and route sub-window events by window ID.
- Add optional ArkUI keyboard snapshots and synchronous key consumption (`keyboard`), API 18
  mouse cancellation (`mouse`), stylus support (`stylus`), and native file drag/drop (`drag`).
  Keep raw XComponent keyboard/pointer delivery available without these optional features.
- Add window creation and API 22 cursor-grab helpers, SDK/distribution version queries, and
  feature-gated logging macros; `log` and `window` are enabled by default.
- Store launch URI, Want parameters and continuation restore state on the app session; expose
  a source-side continuation snapshot for the synchronous platform save callback.
- Improve IME editing, render frame delivery and teardown; release native render callbacks and
  gestures before their ArkUI root is dropped.
- Resolve the event-loop waker at wake time so proxies created before lifecycle initialization
  can still deliver worker-thread events after the lifecycle is ready.
- Allow interactive bridge calls to opt into timeouts up to five minutes while keeping the
  default timeout at 15 seconds.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
