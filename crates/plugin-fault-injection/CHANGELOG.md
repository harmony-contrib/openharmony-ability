# 1.0.0-beta.3

- Introduce the optional `ohos.fault-injection` plugin and named requests to set and clear
  dispatch fault rules.
- Install interception through the host's generic dispatch-hook API; fault injection stays
  disabled unless explicitly registered and configured.
- `set_fault_rule` enables the registry before adding a rule; `clear_fault_rules` clears rules
  without disabling it. Delay/timeout outcomes apply only to async dispatch.
- Inherit version `1.0.0-beta.3`, Rust edition `2021`, and license `MIT OR Apache-2.0`
  from the Cargo workspace.
