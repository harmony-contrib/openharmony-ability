# Unreleased

- Add API 12 status-bar visibility, content color and optional ARGB background through
  `WindowClient::set_status_bar`, separate from desktop tray APIs.
- Run the status-bar bridge regression suite in PR CI, including cancellation and
  native-operation failure coverage.

# 1.0.0-beta.3

- Expand window creation and control with display selection, decorations, transparency,
  fullscreen/focus, geometry, limits, visibility/state, topmost/title and attention requests.
- Add IME positioning, draggable/keep-screen-on settings, cursor visibility/style and real
  platform window-ID queries through named N-API requests.
- Add cancellable prompts anchored in window-content vp coordinates, display-filtered window
  stacking queries, validated RGBA custom cursors and window icons.
- Keep operations scoped to the component's actual window and await platform mutations.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
