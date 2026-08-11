import { BuilderNode, FrameNode } from "@ohos.arkui.node";
import {
  BridgeCallContext,
  BridgeTypedValue,
  BridgePluginContext,
  BridgePluginHookContext,
  AsyncPluginBase,
  BridgeContextRequirement,
  BridgeLifecycleEvent,
} from "@ohos-rs/ability";

interface BadgeData {
  title: string;
}

@Builder
function BuildBadge(data: BadgeData) {
  Row() {
    Text(data.title)
      .fontSize(12)
      .fontColor("#ffffff")
  }
  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
  .backgroundColor("#663f51b5")
  .borderRadius(10)
  .alignSelf(ItemAlign.End);
}

const badgeBuilder = wrapBuilder<[BadgeData]>(BuildBadge);

/** Demonstrates that a bridge plugin can mount a normal ArkUI BuilderNode, not only WebView. */
export class DemoNodePlugin extends AsyncPluginBase {
  readonly id = "demo.node-badge";
  readonly requires: BridgeContextRequirement[] = ["ui-context"];

  private mounted = false;

  onInstall(context: BridgePluginHookContext): void {
    this.mount(context);
  }

  override onLifecycle(event: BridgeLifecycleEvent, context: BridgePluginHookContext): void {
    if (event.kind === "ui-context-destroy") {
      // BridgeHost owns the detached tree and runs its cleanup; do not address a replacement
      // window through this plugin's session-scoped context.
      this.mounted = false;
    } else if (event.kind === "ui-context-ready" && !this.mounted) {
      this.mount(context);
    }
  }

  private mount(context: BridgePluginContext): void {
    // This module's component root exists before ui-context-ready, so plugins mount their
    // nodes directly without slots, registries or readiness waiters.
    const node = new BuilderNode<[BadgeData]>(context.getUIContext());
    node.build(badgeBuilder, { title: "ordinary BuilderNode plugin" });
    const frameNode = node.getFrameNode();
    if (frameNode === null) {
      throw new Error("BuilderNode did not produce a FrameNode");
    }
    const mountedNode: FrameNode = frameNode;
    context.appendChild("demo.node-badge", mountedNode, () => mountedNode.dispose());
    this.mounted = true;
  }

  async invokeAsync(
    action: string,
    _payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    throw new Error(`Unsupported demo.node-badge action '${action}'`);
  }

  onDispose(context: BridgePluginHookContext): void {
    if (this.mounted) {
      context.removeChild("demo.node-badge");
      this.mounted = false;
    }
  }
}
