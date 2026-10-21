# Ability video plugin

Register `VideoBridgePlugin::new()` in Rust and `new LazyPlugin(() => new VideoPlugin())`
in the NativeAbility host. The paired capability requires `ui-context` and API 12.

`VideoClient` accepts owned named requests: `create` attaches the ArkTS player to
an existing `NativeAttachment`, `configure` updates presentation, `set-source`
selects or clears a URL, `set-bytes` loads owned bytes through a temporary file,
`seek` uses seconds, and `dispose` detaches before releasing resources. Media URL
and resource access policy belongs to the application. Codec support follows the
installed platform. Native controls provide play/pause and seek.

`VideoEvents::new(app, id, target_id, callback)` belongs to the registered plugin
instance and exact attachment generation. Dropping an old subscription cannot
remove its replacement. Callbacks carry owned data; workers retain no SDK object.

Each player serializes source changes, playback settings, state transitions and
release. Closing detaches synchronously in the hook's cleanup scope; asynchronous
release never reuses that scope. `onDispose` awaits all releases and continues
other entries after a failure. A rejected native detach retains the node owner;
a failed player release also retains its file/surface resources.

The demo has a native-video ContentSlot, URL input, raw-resource load and release
buttons. For the resource path, add an application-owned `demo.mp4` to the demo
entry's `resources/rawfile` directory. Production host tests run with
`node --test plugins/video/tests/*.test.mjs`.
