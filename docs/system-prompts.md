# System prompts

`WindowClient::show_prompt` uses the target window's `UIContext.showAlertDialog` for
up to three buttons and `UIContext.showActionSheet` for larger choices. ArkUI owns
the layout, colors, fonts, animation, and placement. No custom component is built.
Rust owns the typed request and future; the existing ArkTS window plugin owns the
UIContext and system callbacks.

This is an intentional breaking change to `ohos.window.PromptRequest`. Upgrade the
Rust crate and HAR together and rebuild consumers. Remove `level`, `anchor`, and
`appearance` from requests, and remove imports of `WindowPromptAnchor` and
`WindowPromptAppearance`. Set `cancel_on_touch_outside` (`cancelOnTouchOutside` on
the wire) explicitly: `false` for modal confirmations, `true` for dismissible
action sheets. The latter requires a valid `cancel_index`.

Buttons retain their original result indices. For an action sheet, the cancel
button becomes the system confirmation footer, even if it was in the middle of
the original list. Back/Esc returns `cancel_index`; without one, an explicit button
selection is required. The result completes on `onDidDisappear`, so a subsequent
prompt starts after the first prompt's exit animation and focus teardown.

Call cancellation or plugin teardown rejects the pending operation immediately
and makes callbacks inert. These system APIs provide no imperative close handle:
a visible prompt may remain until the user dismisses it or its window closes.
After cancellation, Back can dismiss even a prompt that originally required a
button selection. No custom-dialog fallback is used.

System behavior references: [AlertDialog](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-arkui/arkui-ts/ts-methods-alert-dialog-box.md),
[ActionSheet](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/reference/apis-arkui/arkui-ts/ts-methods-action-sheet.md).
