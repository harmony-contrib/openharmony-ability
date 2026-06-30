import web_webview from '@ohos.web.webview';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ComponentContent } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x1999;

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

    // Web content
    Web({ src: '', controller: params.controller })
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
 * Opens a new window dialog with the given WebviewController.
 * Uses promptAction.openCustomDialog via the provided UIContext.
 */
export function openNewWindowDialog(
  uiContext: UIContext,
  controller: web_webview.WebviewController,
  url: string
): void {
  try {
    // Close any existing dialog first
    closeDialog();

    const prompt = uiContext.getPromptAction();
    const contentNode = new ComponentContent(
      uiContext,
      wrapBuilder(newWindowDialogBuilder),
      { controller: controller, url: url }
    );

    // Store references for later closing
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
