import web_webview from "@ohos.web.webview";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { ComponentContent, PromptAction } from "@kit.ArkUI";
import { BusinessError } from "@kit.BasicServicesKit";
import { DOMAIN } from "@ohos-rs/ability";

// Module-level single-instance dialog references.
// Limitation: only one new-window dialog can exist at a time. Opening a second
// dialog force-closes the first. This matches typical browser popup behavior.
let currentPrompt: PromptAction | null = null;
let currentNode: ComponentContent<NewWindowDialogParams> | null = null;

interface NewWindowDialogParams {
  controller: web_webview.WebviewController;
  url: string;
}

@Component
struct NewWindowCloseButton {
  onActivate: () => void = () => {};
  @State private hovered: boolean = false;
  @State private pressed: boolean = false;

  private buttonBackgroundColor(): ResourceColor {
    if (this.pressed) {
      return $r("sys.color.alert");
    }
    if (this.hovered) {
      return $r("sys.color.warning");
    }
    return Color.Transparent;
  }

  private iconColor(): Resource {
    if (this.hovered || this.pressed) {
      return $r("sys.color.icon_on_primary");
    }
    return $r("sys.color.icon_primary");
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      SymbolGlyph($r("sys.symbol.xmark"))
        .fontSize(16)
        .fontColor([this.iconColor()])
    }
    .width(28)
    .height(28)
    .margin({ left: 8 })
    .padding(0)
    .borderRadius($r("sys.float.corner_radius_level2"))
    .backgroundColor(this.buttonBackgroundColor())
    .hoverEffect(HoverEffect.None)
    .accessibilityText("Close")
    .onHover((hovered: boolean) => {
      this.hovered = hovered;
      if (!hovered) {
        this.pressed = false;
      }
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => this.onActivate());
  }
}

/**
 * Builder function for the new window dialog content.
 * Embeds a Web component with the given controller.
 * multiWindowAccess is disabled to prevent infinite nesting.
 */
@Builder
export function newWindowDialogBuilder(params: NewWindowDialogParams) {
  Column() {
    // Title bar with close button
    Row() {
      Text(params.url)
        .fontSize($r("sys.float.Body_S"))
        .fontColor($r("sys.color.font_secondary"))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      NewWindowCloseButton({
        onActivate: () => {
          hilog.info(DOMAIN, "NewWindowDialog", "Close button clicked");
          closeDialog();
        },
      })
    }
    .width("100%")
    .constraintSize({ minHeight: 40 })
    .padding({ left: 16, right: 8, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r("sys.color.comp_background_secondary"))
    .border({ width: { bottom: "1px" }, color: $r("sys.color.comp_divider") })

    // Web content — loads the target URL directly. ArkWeb's own popup is
    // cancelled (`setWebController(null)` in onWindowNew) to avoid deadlocking the
    // UI thread on an unhosted controller; this independent Web hosts the dialog's
    // own controller and navigates to the target URL, giving the OHOS equivalent of
    // "open in a new in-page window" (Allow). multiWindowAccess is disabled to
    // prevent infinite nesting.
    Web({ src: params.url, controller: params.controller })
      .width("100%")
      .layoutWeight(1)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .multiWindowAccess(false)
      .onWindowExit(() => {
        hilog.info(DOMAIN, "NewWindowDialog", "onWindowExit fired, closing dialog");
        closeDialog();
      })
  }
  .width("90%")
  .height("80%")
  .constraintSize({ minWidth: 360, maxWidth: 960, minHeight: 280, maxHeight: 720 })
  .backgroundColor($r("sys.color.comp_background_primary"))
  .borderRadius($r("sys.float.corner_radius_level8"))
  .border({ width: "1px", color: $r("sys.color.comp_divider") })
  .shadow(ShadowStyle.OUTER_FLOATING_MD)
  .clip(true);
}

function disposeDialogNode(node: ComponentContent<NewWindowDialogParams>): void {
  if (currentNode === node) {
    currentNode = null;
    currentPrompt = null;
  }
  try {
    node.dispose();
  } catch {}
}

function closeDialog(): void {
  const prompt = currentPrompt;
  const node = currentNode;
  currentPrompt = null;
  currentNode = null;
  if (prompt && node) {
    prompt
      .closeCustomDialog(node)
      .then(() => {
        try {
          node.dispose();
        } catch {}
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, "NewWindowDialog", "closeCustomDialog failed: %{public}s", String(e));
        try {
          node.dispose();
        } catch {}
      });
  } else if (node) {
    try {
      node.dispose();
    } catch {}
  }
}

/**
 * Synchronously builds the `ComponentContent` hosting the controller in a `Web`
 * component, so the controller has a host BEFORE it is passed to
 * `setWebController`. Returns the built content node (the `Web` component object
 * exists synchronously after `new ComponentContent(...)`).
 */
export function buildNewWindowContent(
  uiContext: UIContext,
  controller: web_webview.WebviewController,
  url: string,
): ComponentContent<NewWindowDialogParams> {
  closeDialog();
  const params: NewWindowDialogParams = {
    controller: controller,
    url: url,
  };
  return new ComponentContent(uiContext, wrapBuilder(newWindowDialogBuilder), params);
}

/**
 * Makes a previously-built new-window content node visible as a custom dialog.
 * Asynchronous (returns a promise) — call this AFTER setWebController, which
 * only needs the host (built synchronously by buildNewWindowContent) to exist.
 */
export function showNewWindowDialog(
  uiContext: UIContext,
  contentNode: ComponentContent<NewWindowDialogParams>,
): void {
  try {
    const prompt = uiContext.getPromptAction();
    currentPrompt = prompt;
    currentNode = contentNode;

    prompt
      .openCustomDialog(contentNode, {
        isModal: true,
        maskColor: $r("sys.color.mask_secondary"),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        onDidDisappear: () => {
          disposeDialogNode(contentNode);
        },
      })
      .then(() => {
        hilog.info(DOMAIN, "NewWindowDialog", "Dialog opened successfully");
      })
      .catch((err: BusinessError) => {
        disposeDialogNode(contentNode);
        hilog.error(DOMAIN, "NewWindowDialog", "Failed to open dialog: %{public}s", String(err));
      });
  } catch (e) {
    disposeDialogNode(contentNode);
    hilog.error(DOMAIN, "NewWindowDialog", "Exception opening dialog: %{public}s", String(e));
  }
}

/**
 * Single-step entry: builds + shows the dialog.
 */
export function openNewWindowDialog(
  uiContext: UIContext,
  controller: web_webview.WebviewController,
  url: string,
): void {
  const contentNode = buildNewWindowContent(uiContext, controller, url);
  showNewWindowDialog(uiContext, contentNode);
}
