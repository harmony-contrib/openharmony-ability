# Named N-API contract reference

The canonical type names, object layouts and plugin mode/context declarations are
generated from Rust in [docs/napi-contracts.md](../../../../docs/napi-contracts.md).
Do not maintain a second inventory in this skill.

After changing Rust declarations, run:

```sh
cargo run -p xtask -- contracts
cargo run -p xtask -- contracts --check
```

Keep ArkTS type names and layouts identical to those declarations. The generator
does not infer action routing or platform failure policies; document those in the
[plugin standard](../../../../docs/plugin-development-standard.md), especially
sections 3.3 and 7.1 for action semantics and reverse WebView events.

Native attachment callbacks carry callback-scoped FrameNode/NodeContent values in
addition to their owned Rust marker fields. Their generated inventory links the
explicit decoders; the attachment lifecycle and ownership rules remain in the
plugin standard. These platform values must never be stored on workers.

Requests, responses and reverse events use named N-API values, never JSON.
Reverse callbacks use `context.invokeNativeSync` inside the active N-API callback;
do not retain platform objects or N-API references on workers.
