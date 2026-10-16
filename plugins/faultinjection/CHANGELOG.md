# 1.0.0-beta.3

- Introduce the optional `ohos.fault-injection` plugin with named enable, disable, set-rule
  and clear actions; the registry is disabled by default.
- Register dispatch interception through `BridgePluginContext.registerDispatchHook` during
  installation; the core HAR does not import this plugin.
- Support error/exception injection on sync and async calls, plus delay/timeout injection on
  async calls. Sync delay/timeout rules are consumed without blocking the main thread.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
