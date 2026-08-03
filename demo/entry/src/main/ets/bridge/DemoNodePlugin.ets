import { BuilderNode, FrameNode } from "@ohos.arkui.node";
import {
  AsyncBridgePlugin,
  BridgeCallContext,
  BridgeNodeSlot,
  BridgeNodeSlotRegistry,
  BridgeTypedValue,
  BridgePluginContext,
  BridgePluginFactory,
  DEFAULT_PLUGIN_NODE_SLOT,
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
class DemoNodePlugin implements AsyncBridgePlugin {
  readonly id = "demo.node-badge";
  readonly version = 1;
  readonly execution: "async" = "async";
  readonly requires: ["ui-context"] = ["ui-context"];
  private slot?: BridgeNodeSlot;

  onInstall(context: BridgePluginContext): void {
    const slot = BridgeNodeSlotRegistry.require(
      context.sessionId,
      context.moduleName,
      DEFAULT_PLUGIN_NODE_SLOT,
    );
    const node = new BuilderNode<[BadgeData]>(context.getUIContext());
    node.build(badgeBuilder, { title: "ordinary BuilderNode plugin" });
    const frameNode = node.getFrameNode();
    if (frameNode === null) {
      throw new Error("BuilderNode did not produce a FrameNode");
    }
    const mountedNode: FrameNode = frameNode;
    slot.mount("demo.node-badge", mountedNode, () => mountedNode.dispose());
    this.slot = slot;
  }

  async invokeAsync(
    action: string,
    _payload: BridgeTypedValue,
    _context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    throw new Error(`Unsupported demo.node-badge action '${action}'`);
  }

  onDispose(): void {
    this.slot?.unmount("demo.node-badge");
    this.slot = undefined;
  }
}

export function createDemoNodePlugin(): BridgePluginFactory {
  return {
    id: "demo.node-badge",
    version: 1,
    execution: "async",
    requires: ["ui-context"],
    modules: ["demo_native"],
    create: (_context: BridgePluginContext): AsyncBridgePlugin => new DemoNodePlugin(),
  };
}
