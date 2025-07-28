# openharmony-ability-derive

## Introduce

openharmony-ability-derive is a macro crate for the openharmony-ability project. It provides a macro for generating code to accept the OpenHarmony/HarmonyNext ability's lifecycle callbacks.


## Install

```bash
cargo add openharmony-ability-derive
```

## Mode

We support two different mode to render.

### xcomponent
Using `XComponent` to render code that can use OpenGL or Vulkan.

**Example**

```rust
use openharmony_ability_derive::ability;

#[ability]
fn openharmony_app(app: OpenHarmonyApp) {
    app.run_loop(|types| match types {
        Event::Input(k) => match k {
            InputEvent::TextInputEvent(s) => {
                hilog_info!(format!("ohos-rs macro input_text: {:?}", s).as_str());
            }
            _ => {
                hilog_info!(format!("ohos-rs macro input:").as_str());
            }
        },
        Event::WindowRedraw(_) => {}
        _ => {
            hilog_info!(format!("ohos-rs macro: {:?}", types.as_str()).as_str());
        }
    });
}
```

### webview

Using `ArkWeb` to render everything.

**Example**

```rust
use openharmony_ability_derive::ability;

#[ability(webview)]
fn openharmony_app(app: OpenHarmonyApp) {
    app.run_loop(|types| match types {
        Event::Input(k) => match k {
            InputEvent::TextInputEvent(s) => {
                hilog_info!(format!("ohos-rs macro input_text: {:?}", s).as_str());
            }
            _ => {
                hilog_info!(format!("ohos-rs macro input:").as_str());
            }
        },
        Event::WindowRedraw(_) => {}
        _ => {
            hilog_info!(format!("ohos-rs macro: {:?}", types.as_str()).as_str());
        }
    });
}
```

And we also support custom protocols. Just add them into ability:

```rust
use openharmony_ability_derive::ability;

#[ability(webview, protocol = "custom,hello")]
fn openharmony_app(app: OpenHarmonyApp) {
    app.run_loop(|types| match types {
        Event::Input(k) => match k {
            InputEvent::TextInputEvent(s) => {
                hilog_info!(format!("ohos-rs macro input_text: {:?}", s).as_str());
            }
            _ => {
                hilog_info!(format!("ohos-rs macro input:").as_str());
            }
        },
        Event::WindowRedraw(_) => {}
        _ => {
            hilog_info!(format!("ohos-rs macro: {:?}", types.as_str()).as_str());
        }
    });
}
```