# Audio playback

Pair this HAR with `openharmony-ability-plugin-audio` from the same revision.
`ohos.audio` is an asynchronous, Ability-scoped plugin with one named action:
`update` (`ohos.audio.UpdateRequest` → `ohos.audio.UpdateResponse`).

## Descriptor ownership

Pass a `BorrowedFd` separately to `AudioClient::update`; playback options cannot
contain caller-supplied descriptor integers. Keep the source open until the update
acknowledges it. ArkTS duplicates the descriptor synchronously with the API 10+
`fs.dup` before awaiting player creation or releasing the previous player. The
plugin retains the resulting `fs.File` until its player finishes releasing.
It never closes the borrowed source.

Replacement waits for the previous pipeline to release before creating another
player. Clearing or releasing a player acknowledges only after cleanup. Disposal
also waits for pending creation and replacement, including players created after
disposal begins. Failed creation, configuration, preparation, playback, and
decoder callbacks release the player and close its duplicate. SDK duplication
errors reject the update unchanged and leave the existing player intact.

An accepted update acknowledges ownership and schedules playback; it does not
claim that asynchronous decoding or playback succeeded. `reportErrors` enables
local warnings containing the SDK error and source label. State/error listeners
drive the local pipeline only; there are no Rust reverse events or subscriptions
for playback logging, seek, volume, or position changes.

## Execution regressions

CI executes the production ArkTS plugin and lifecycle owner through the SDK's
TypeScript compiler with controlled platform implementations. Set `OHOS_SDK_HOME`
to the SDK directory containing `ets/`; no per-file compiler arguments or separate
TypeScript installation are needed:

```bash
node --test plugins/audio/tests/*.cjs
```

These tests validate ownership, ordering, cancellation/disposal, SDK failures,
and absence of reverse bridge calls. They do not replace device playback checks.
