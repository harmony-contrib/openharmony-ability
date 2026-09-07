import web_webview from '@ohos.web.webview';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ComponentContent } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { DOMAIN } from "@ohos-rs/ability";

// Module-level single-instance dialog references.
// Limitation: only one new-window dialog can exist at a time. Opening a second
// dialog force-closes the first. This matches typical browser popup behavior.
// If multi-dialog support is needed, refactor to a Map<number, DialogSession>.
let currentPrompt: Object | null = null;
let currentNode: ComponentContent<Record<string, ESObject>> | null = null;

/**
 * Builder function for the new window dialog content.
 * Embeds a Web component with the given controller.
 * multiWindowAccess is disabled to prevent infinite nesting.
 */
@Builder
export function newWindowDialogBuilder(params: { controller: web_webview.WebviewController, url: string }) {
  Column() {
    // Title bar with close button
    Row() {
      Text(params.url)
        .fontSize(12)
        .fontColor('#666666')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('✕')
        .fontSize(16)
        .fontColor('#333333')
        .fontWeight(FontWeight.Bold)
        .onClick(() => {
          hilog.info(DOMAIN, 'NewWindowDialog', 'Close button clicked');
          closeDialog();
        })
    }
    .width('100%')
    .height(36)
    .padding({ left: 12, right: 12 })
    .backgroundColor('#F5F5F5')

    // Web content — loads the target URL directly. ArkWeb's own popup is
    // cancelled (`setWebController(null)` in onWindowNew) to avoid deadlocking the
    // UI thread on an unhosted controller; this independent Web hosts the dialog's
    // own controller and navigates to the target URL, giving the OHOS equivalent of
    // "open in a new in-page window" (Allow). multiWindowAccess is disabled to
    // prevent infinite nesting.
    Web({ src: params.url, controller: params.controller })
      .width('100%')
      .layoutWeight(1)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .multiWindowAccess(false) // Prevent infinite nesting
      .onWindowExit(() => {
        hilog.info(DOMAIN, 'NewWindowDialog', 'onWindowExit fired, closing dialog');
        closeDialog();
      })
  }
  .width('90%')
  .height('80%')
  .backgroundColor(Color.White)
  .borderRadius(12)
  .clip(true)
}

function closeDialog(): void {
  if (currentPrompt && currentNode) {
    try {
      (currentPrompt as ESObject).closeCustomDialog(currentNode);
    } catch (e) {
      hilog.warn(DOMAIN, 'NewWindowDialog', 'closeCustomDialog failed: %{public}s', String(e));
    }
  }
  currentPrompt = null;
  currentNode = null;
}

/**
 * Synchronously builds the `ComponentContent` hosting the controller in a `Web`
 * component, so the controller has a host BEFORE it is passed to
 * `setWebController`. Returns the built content node (the `Web` component object
 * exists synchronously after `new ComponentContent(...)`).
 *
 * ArkWeb blocks `setWebController(controller)` if the controller has no `Web`
 * component host yet — the host must exist at the moment of the call. Building the
 * `ComponentContent` here constructs that host synchronously; the dialog is only
 * made visible afterwards (asynchronously) via `showNewWindowDialog`.
 */
export function buildNewWindowContent(
  uiContext: UIContext,
  controller: web_webview.WebviewController,
  url: string
): ComponentContent<Record<string, ESObject>> {
  // Close any existing dialog first.
  closeDialog();
  return new ComponentContent(
    uiContext,
    wrapBuilder(newWindowDialogBuilder),
    { controller: controller, url: url }
  );
}

/**
 * Makes a previously-built new-window content node visible as a custom dialog.
 * Asynchronous (returns a promise) — call this AFTER setWebController, which
 * only needs the host (built synchronously by buildNewWindowContent) to exist.
 */
export function showNewWindowDialog(
  uiContext: UIContext,
  contentNode: ComponentContent<Record<string, ESObject>>
): void {
  try {
    const prompt = uiContext.getPromptAction();
    currentPrompt = prompt;
    currentNode = contentNode;

    prompt.openCustomDialog(contentNode, {
      isModal: false,
      autoCancel: true,
      alignment: DialogAlignment.Center,
    }).then(() => {
      hilog.info(DOMAIN, 'NewWindowDialog', 'Dialog opened successfully');
    }).catch((err: BusinessError) => {
      currentPrompt = null;
      currentNode = null;
      hilog.error(DOMAIN, 'NewWindowDialog', 'Failed to open dialog: %{public}s', JSON.stringify(err));
    });
  } catch (e) {
    hilog.error(DOMAIN, 'NewWindowDialog', 'Exception opening dialog: %{public}s', JSON.stringify(e));
  }
}

/**
 * Legacy single-step entry retained for compatibility: builds + shows the dialog.
 * NOTE: in the onWindowNew path use `buildNewWindowContent` (synchronous, before
 * setWebController) + `showNewWindowDialog` (after) separately, to guarantee the
 * controller is hosted before setWebController runs.
 */
export function openNewWindowDialog(
  uiContext: UIContext,
  controller: web_webview.WebviewController,
  url: string
): void {
  const contentNode = buildNewWindowContent(uiContext, controller, url);
  showNewWindowDialog(uiContext, contentNode);
}
