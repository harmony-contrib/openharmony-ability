# openharmony-ability-derive

## Introduce

openharmony-ability-derive is a macro crate for the openharmony-ability project. It provides a macro for generating code to accept the OpenHarmony/HarmonyNext ability's lifecycle callbacks.


## Install

```bash
cargo add openharmony-ability-derive
```

## Example

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