import { NativeMenuItem, NativeMenuCleanup, pasteAction } from "./NativeMenus";
import { BuilderNode, ComponentContent, NodeContent } from "@ohos.arkui.node";
import { UIContext } from "@ohos.arkui.UIContext";
import deviceInfo from "@ohos.deviceInfo";
import {
  BridgeCallContext,
  BridgePluginContext,
  BridgeTypedValue,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

interface ViewAction {
  name: string;
  label: string;
}
interface ViewMenu {
  generation: number;
  visible: boolean;
  x: number;
  y: number;
  items: NativeMenuItem[];
}
interface Settings {
  id: string;
  targetId: number;
  testId?: string | null;
  width: number;
  height: number;
  hue: number;
  semantic: boolean;
  clickable: boolean;
  disabled: boolean;
  accessible?: boolean | null;
  hidden: boolean;
  label: string;
  hint: string;
  value: string;
  role: string;
  checked?: boolean | null;
  selected: boolean;
  api23: boolean;
  api26: boolean;
  actions: ViewAction[];
  menu?: ViewMenu | null;
}
interface Batch {
  updates: Settings[];
  remove: string[];
}
interface ViewParameters {
  entry: ViewEntry;
  settings: Settings;
}
interface MenuParameters {
  entry: ViewEntry;
  menu: ViewMenu;
}
interface MenuLease {
  content: ComponentContent<MenuParameters>;
  generation: number;
  opening: Promise<void>;
  retired: boolean;
}
interface Acknowledgement {
  accepted: boolean;
}
interface CustomAction {
  name: string;
  onAction: () => void;
}
// A structural interface keeps API-26 methods behind both feature and runtime guards.
interface ActionsAttribute {
  accessibilityCustomActions(actions: CustomAction[]): CommonAttribute;
}
interface StateAttribute {
  accessibilityStateDescription(description: string): CommonAttribute;
}
const quarantinedViews: ViewEntry[] = [];
const roles: Map<string, AccessibilityRoleType> = new Map([
  ["button", AccessibilityRoleType.BUTTON],
  ["checkbox", AccessibilityRoleType.CHECKBOX],
  ["switch", AccessibilityRoleType.SWITCH],
  ["radio", AccessibilityRoleType.RADIO],
  ["slider", AccessibilityRoleType.SLIDER],
  ["image", AccessibilityRoleType.IMAGE],
  ["link", AccessibilityRoleType.HYPERLINK],
  ["list", AccessibilityRoleType.LIST],
  ["grid", AccessibilityRoleType.GRID],
  ["progress", AccessibilityRoleType.PROGRESS],
  ["search", AccessibilityRoleType.SEARCH],
  ["menuitem", AccessibilityRoleType.MENU_ITEM],
  ["text", AccessibilityRoleType.TEXT],
]);
function role(value: string): AccessibilityRoleType | undefined {
  if (value === "") {
    return undefined;
  }
  const result = roles.get(value);
  if (result === undefined) {
    throw new Error("Invalid native wrapper role");
  }
  return result;
}

class ViewModifier implements AttributeModifier<StackAttribute> {
  private entry: ViewEntry;
  private settings: Settings;
  constructor(entry: ViewEntry, settings: Settings) {
    this.entry = entry;
    this.settings = settings;
  }
  applyNormalAttribute(node: StackAttribute): void {
    const s = this.settings;
    node
      .id(s.testId ?? s.id)
      .width(s.width)
      .height(s.height)
      .hueRotate(s.hue)
      .clip(false)
      .hitTestBehavior(HitTestMode.Transparent)
      .accessibilityText(s.label)
      .accessibilityDescription(
        s.api23 ? s.hint : [s.hint, s.value].filter((value) => value.length > 0).join(", "),
      )
      .accessibilityLevel(
        s.hidden ? "no-hide-descendants" : !s.semantic || s.accessible === false ? "no" : "yes",
      )
      .accessibilityGroup(s.accessible === true)
      .accessibilitySelected(s.selected);
    node.accessibilityRole(role(s.role));
    node.accessibilityChecked(s.checked === null ? undefined : s.checked);
    node.enabled(!s.disabled).onClick(s.clickable ? (): void => {} : undefined);
    if (s.api23 && typeof (node as StateAttribute).accessibilityStateDescription === "function") {
      (node as StateAttribute).accessibilityStateDescription(s.value);
    }
    if (s.api26 && typeof (node as ActionsAttribute).accessibilityCustomActions === "function") {
      const actions: CustomAction[] = s.actions.map((action: ViewAction): CustomAction => {
        return {
          name: action.label,
          onAction: (): void => {
            this.entry.action(action.name);
          },
        };
      });
      (node as ActionsAttribute).accessibilityCustomActions(actions);
    } else if (s.api26 && s.actions.length > 0) {
      throw new Error("The runtime has no ArkUI accessibilityCustomActions implementation");
    }
  }
}
@Component
struct ViewMenuContent {
  entry!: ViewEntry;
  @Prop menu!: ViewMenu;
  @Builder
  pasteItem(item: NativeMenuItem) {
    PasteButton().onClick((_event: ClickEvent, result: PasteButtonOnClickResult): void => {
      if (result === PasteButtonOnClickResult.SUCCESS) {
        this.entry.paste(item.name, this.menu.generation);
      }
    });
  }
  build() {
    Menu() {
      ForEach(
        this.menu.items,
        (item: NativeMenuItem) => {
          if (pasteAction(item) !== undefined) {
            MenuItem(this.pasteItem.bind(this, item));
          } else {
            MenuItem({ content: item.label }).onClick((): void => {
              this.entry.action(item.name, "menu", this.menu.generation);
            });
          }
        },
        (item: NativeMenuItem): string => item.name,
      )
    }.padding(8);
  }
}
@Builder
function menuContent(params: MenuParameters) {
  ViewMenuContent({ entry: params.entry, menu: params.menu });
}
@Builder
function nativeView(params: ViewParameters) {
  Stack({ alignContent: Alignment.TopStart }) {
    ContentSlot(params.entry.slot)
  }
  .attributeModifier(new ViewModifier(params.entry, params.settings))
  .onAccessibilityActionIntercept(
    (action: AccessibilityAction): AccessibilityActionInterceptResult => {
      if (action === AccessibilityAction.ACCESSIBILITY_CLICK && params.entry.action("activate")) {
        return AccessibilityActionInterceptResult.ACTION_INTERCEPT;
      }
      return AccessibilityActionInterceptResult.ACTION_CONTINUE;
    },
  );
}
class ViewEntry {
  private current: Settings;
  readonly slot: NodeContent = new NodeContent();
  private node: BuilderNode<[ViewParameters]>;
  private context: BridgeCallContext;
  private ui: UIContext;
  private menus: NativeMenuCleanup;
  private closed: boolean = false;
  private retirementFailure?: Error;
  private menuLease?: MenuLease;
  constructor(settings: Settings, context: BridgeCallContext, menus: NativeMenuCleanup) {
    this.current = settings;
    this.menus = menus;
    this.context = context;
    this.ui = context.getUIContext();
    this.node = new BuilderNode<[ViewParameters]>(this.ui);
  }
  get settings(): Settings {
    return this.current;
  }
  create(): void {
    try {
      const params: ViewParameters = { entry: this, settings: this.settings };
      this.node.build(wrapBuilder(nativeView), params, { nestingBuilderSupported: true });
      const response = this.context.invokeNativeSync(
        "native-subtree-ready",
        "ohos.node.NativeSubtreeReady",
        "ohos.node.Acknowledgement",
        { targetId: this.settings.targetId, content: this.node.getFrameNode(), slot: this.slot },
      ) as Acknowledgement;
      if (response.accepted !== true) {
        throw new Error("Native wrapper attachment was rejected");
      }
      this.syncMenu();
    } catch (error) {
      this.dispose();
      throw new Error(`Native wrapper construction failed: ${String(error)}`);
    }
  }
  update(settings: Settings): void {
    if (settings.targetId !== this.settings.targetId) {
      throw new Error("Native wrapper target cannot change");
    }
    this.current = settings;
    const params: ViewParameters = { entry: this, settings: settings };
    this.node.update(params);
    this.syncMenu();
  }
  private syncMenu(): void {
    try {
      this.applyMenu();
    } catch (error) {
      console.error(`[ArkUI] native menu construction failed: ${String(error)}`);
      const lease = this.menuLease;
      this.menuLease = undefined;
      if (lease) {
        this.retireMenu(lease);
      }
      this.action("", "menu-dismiss", this.settings.menu?.generation);
    }
  }
  private applyMenu(): void {
    const menu = this.settings.menu;
    const previous = this.menuLease;
    if (this.closed || menu?.visible !== true) {
      this.menuLease = undefined;
      if (previous) {
        this.retireMenu(previous);
      }
      return;
    }
    if (previous?.generation === menu.generation) {
      previous.content.update({ entry: this, menu: menu });
      return;
    }
    if (previous) {
      this.retireMenu(previous);
    }
    const ui = this.ui;
    const frame = this.node.getFrameNode();
    if (!frame) {
      return;
    }
    const content = new ComponentContent<MenuParameters>(
      ui,
      wrapBuilder(menuContent),
      { entry: this, menu: menu },
      { nestingBuilderSupported: true },
    );
    const lease: MenuLease = {
      content: content,
      generation: menu.generation,
      opening: Promise.resolve(),
      retired: false,
    };
    this.menuLease = lease;
    lease.opening = ui
      .getPromptAction()
      .openMenu(content, { id: frame.getUniqueId() }, this.menuOptions());
    lease.opening.catch((error: Error): void => {
      console.error(`[ArkUI] native menu open failed: ${String(error)}`);
      if (this.menuLease === lease) {
        this.menuLease = undefined;
        this.action("", "menu-dismiss", lease.generation);
      }
      this.retireMenu(lease);
    });
  }
  private retireMenu(lease: MenuLease): void {
    if (lease.retired) {
      return;
    }
    lease.retired = true;
    this.menus.retire(
      lease,
      lease.opening,
      (): Promise<void> => this.ui.getPromptAction().closeMenu(lease.content),
      (): void => lease.content.dispose(),
    );
  }

  paste(name: string, generation: number | undefined): void {
    if (
      generation === undefined ||
      this.settings.menu?.generation !== generation ||
      this.settings.menu?.visible !== true ||
      this.closed ||
      !this.settings.menu.items.some(
        (item: NativeMenuItem): boolean => item.kind === "paste" && item.name === name,
      )
    ) {
      return;
    }
    this.action(name, "menu", generation);
  }
  menuOptions(): MenuOptions {
    const menu = this.settings.menu;
    return {
      placement: Placement.TopLeft,
      offset: { x: menu?.x ?? 0, y: -(menu?.y ?? 0) },
      showInSubWindow: false,
      onDisappear: (): void => {
        // Every popup retains its own generation, including during replacement.
        const generation = menu?.generation;
        if (generation !== undefined) {
          this.action("", "menu-dismiss", generation);
        }
      },
    };
  }
  action(name: string, kind?: string, generation?: number): boolean {
    if (
      this.closed ||
      !this.context.isActive() ||
      (kind !== undefined && generation !== this.settings.menu?.generation)
    ) {
      return false;
    }
    const response = this.context.invokeNativeSync(
      "view-action",
      "ohos.arkui.NativeViewAction",
      "ohos.node.Acknowledgement",
      {
        targetId: this.settings.targetId,
        id: this.settings.id,
        action: name,
        kind: kind,
        generation: generation,
      },
    ) as Acknowledgement;
    return response.accepted === true;
  }
  dispose(cleanup: BridgePluginContext = this.context): void {
    if (this.closed) {
      if (this.retirementFailure) {
        throw this.retirementFailure;
      }
      return;
    }
    this.closed = true;
    try {
      if (this.menuLease) {
        this.retireMenu(this.menuLease);
        this.menuLease = undefined;
      }
      // Retirement is also required after partial construction: attachment may have failed after mounting the wrapper.
      const response = cleanup.invokeNativeSync(
        "native-node-retiring",
        "ohos.node.NativeNodeRetiring",
        "ohos.node.Acknowledgement",
        { targetId: this.settings.targetId },
      ) as Acknowledgement;
      if (response.accepted !== true) {
        throw new Error("Native wrapper retirement was rejected");
      }
      this.node.dispose();
    } catch (error) {
      quarantinedViews.push(this);
      this.retirementFailure = new Error(`Native wrapper retirement failed: ${String(error)}`);
      throw this.retirementFailure;
    }
  }
}
export class NativeViews {
  private entries: Map<string, ViewEntry> = new Map();
  private menus: NativeMenuCleanup = new NativeMenuCleanup();
  apply(payload: BridgeTypedValue, context: BridgeCallContext): BridgeTypedValue {
    expectBridgeRequestType(
      payload,
      "ohos.arkui",
      "apply-native-views",
      "ohos.arkui.NativeViewBatch",
    );
    const batch = payload.value as Batch;
    if (!batch || !Array.isArray(batch.updates) || !Array.isArray(batch.remove)) {
      throw new Error("Invalid native wrapper batch");
    }
    const ids: Set<string> = new Set();
    for (const s of batch.updates) {
      if (
        !s ||
        typeof s.id !== "string" ||
        !s.id ||
        !Number.isInteger(s.targetId) ||
        s.targetId <= 0 ||
        s.targetId > 0xffffffff ||
        ids.has(s.id) ||
        !Number.isFinite(s.width) ||
        !Number.isFinite(s.height) ||
        s.width < 0 ||
        s.height < 0 ||
        !Number.isFinite(s.hue) ||
        !Array.isArray(s.actions) ||
        new Set(s.actions.map((action: ViewAction): string => action.name)).size !==
          s.actions.length ||
        s.actions.some(
          (action: ViewAction): boolean =>
            !action ||
            typeof action.name !== "string" ||
            !action.name ||
            typeof action.label !== "string" ||
            !action.label,
        ) ||
        typeof s.semantic !== "boolean" ||
        typeof s.clickable !== "boolean" ||
        typeof s.disabled !== "boolean" ||
        typeof s.hidden !== "boolean" ||
        typeof s.selected !== "boolean" ||
        typeof s.api23 !== "boolean" ||
        typeof s.api26 !== "boolean" ||
        typeof s.label !== "string" ||
        typeof s.hint !== "string" ||
        typeof s.value !== "string" ||
        typeof s.role !== "string" ||
        (s.accessible != null && typeof s.accessible !== "boolean") ||
        (s.checked != null && typeof s.checked !== "boolean") ||
        (s.testId != null && typeof s.testId !== "string") ||
        (s.menu != null &&
          (!Number.isInteger(s.menu.generation) ||
            s.menu.generation <= 0 ||
            typeof s.menu.visible !== "boolean" ||
            s.menu.generation > 4294967295 ||
            !Number.isFinite(s.menu.x) ||
            !Number.isFinite(s.menu.y) ||
            !Array.isArray(s.menu.items) ||
            new Set(s.menu.items.map((item: NativeMenuItem): string => item.name)).size !==
              s.menu.items.length ||
            s.menu.items.length === 0 ||
            s.menu.items.some(
              (item: NativeMenuItem): boolean =>
                !item ||
                typeof item.name !== "string" ||
                !item.name ||
                typeof item.label !== "string" ||
                !item.label ||
                !["action", "paste"].includes(item.kind),
            ))) ||
        (s.api26 && deviceInfo.sdkApiVersion < 26) ||
        (s.api23 && deviceInfo.sdkApiVersion < 23)
      ) {
        throw new Error("Invalid native wrapper settings");
      }
      ids.add(s.id);
      role(s.role);
      const previous = this.entries.get(s.id);
      if (previous && !batch.remove.includes(s.id) && previous.settings.targetId !== s.targetId) {
        throw new Error("Native wrapper target cannot change");
      }
    }
    if (batch.remove.some((id: string): boolean => typeof id !== "string" || !id)) {
      throw new Error("Invalid retiring wrapper ID");
    }
    for (const id of batch.remove) {
      this.entries.get(id)?.dispose();
      this.entries.delete(id);
    }
    for (const s of batch.updates) {
      const previous = this.entries.get(s.id);
      if (previous) {
        previous.update(s);
      } else {
        const entry = new ViewEntry(s, context, this.menus);

        entry.create();
        this.entries.set(s.id, entry);
      }
    }
    return { typeName: "ohos.node.Acknowledgement", value: { accepted: true } };
  }
  async settled(): Promise<void> {
    await this.menus.settled();
  }
  dispose(cleanup: BridgePluginContext): void {
    let failure: Error | undefined;
    for (const entry of this.entries.values()) {
      try {
        entry.dispose(cleanup);
      } catch (error) {
        failure ??= new Error(String(error));
      }
    }
    this.entries.clear();
    if (failure) {
      throw failure;
    }
  }
}
