# 1.0.0-beta.3

- Introduce the `ohos.updater` async plugin backed by Huawei AppGallery Update Kit.
- Return update-check metadata without opening a dialog; launch the platform-managed download
  and installation flow only for the explicit `download-and-install` action.
- Align the package version to `1.0.0-beta.3` and resolve internal HAR dependencies
  through `workspace:*`.
