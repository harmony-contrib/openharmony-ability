import { ControlledText } from "./ControlledText";
import { BuilderNode } from "@ohos.arkui.node";
import { FrameCallback } from "@ohos.arkui.UIContext";
import {
  BridgeCallContext,
  BridgePluginContext,
  BridgeTypedValue,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

interface EditorSettings {
  id: string;
  targetId: number;
  multiline: boolean;
  secure: boolean;
  text: string;
  count: number;
  width: number;
  height: number;
  placeholder: string;
  fontSize: number;
  fontWeight: number;
  fontFamily?: string | null;
  italic: boolean;
  color: number;
  placeholderColor: number;
  caretColor: number;
  selectionColor: number;
  editable: boolean;
  hitTest: number;
  align: number;
  rtl: boolean;
  capitalize: number;
  keyboard: string;
  enterKey: string;
  blurOnSubmit: boolean;
  maxLength?: number | null;
  autoFill: boolean;
  contentType?: string | null;
  autoFocus: boolean;
  accessibility?: EditorAccessibility | null;
}
interface EditorAccessibility {
  label: string;
  hint: string;
  hidden: boolean;
  accessible?: boolean | null;
  disabled: boolean;
}
interface EditorCommand {
  id: string;
  kind: string;
  start: number;
  end: number;
}
interface EditorBatch {
  updates: EditorSettings[];
  commands: EditorCommand[];
  remove: string[];
}
interface Acknowledgement {
  accepted: boolean;
}
const inputTypes: Map<string, InputType> = new Map([
  ["normal", InputType.Normal],
  ["number", InputType.Number],
  ["decimal", InputType.NUMBER_DECIMAL],
  ["phone", InputType.PhoneNumber],
  ["email", InputType.Email],
  ["password", InputType.Password],
  ["number-password", InputType.NUMBER_PASSWORD],
]);
const areaTypes: Map<string, TextAreaType> = new Map([
  ["normal", TextAreaType.NORMAL],
  ["number", TextAreaType.NUMBER],
  ["decimal", TextAreaType.NUMBER_DECIMAL],
  ["phone", TextAreaType.PHONE_NUMBER],
  ["email", TextAreaType.EMAIL],
]);
const enterTypes: Map<string, EnterKeyType> = new Map([
  ["go", EnterKeyType.Go],
  ["next", EnterKeyType.Next],
  ["search", EnterKeyType.Search],
  ["send", EnterKeyType.Send],
  ["newline", EnterKeyType.NEW_LINE],
  ["done", EnterKeyType.Done],
]);
const contentTypes: Map<string, ContentType> = new Map([
  ["username", ContentType.USER_NAME],
  ["password", ContentType.PASSWORD],
  ["new-password", ContentType.NEW_PASSWORD],
  ["email", ContentType.EMAIL_ADDRESS],
  ["tel", ContentType.FULL_PHONE_NUMBER],
  ["name", ContentType.PERSON_FULL_NAME],
  ["given-name", ContentType.PERSON_FIRST_NAME],
  ["family-name", ContentType.PERSON_LAST_NAME],
  ["nickname", ContentType.NICKNAME],
  ["street-address", ContentType.FULL_STREET_ADDRESS],
  ["address-line2", ContentType.DETAIL_INFO_WITHOUT_STREET],
  ["city", ContentType.CITY_ADDRESS],
  ["region", ContentType.PROVINCE_ADDRESS],
  ["country", ContentType.COUNTRY_ADDRESS],
  ["credit-card", ContentType.BANK_CARD_NUMBER],
]);
function inputType(value: string): InputType {
  const result = inputTypes.get(value);
  if (result === undefined) {
    throw new Error("Invalid editor keyboard");
  }
  return result;
}
function areaType(value: string): TextAreaType {
  const result = areaTypes.get(value);
  if (result === undefined) {
    throw new Error("Invalid multiline editor keyboard");
  }
  return result;
}
function enterType(value: string): EnterKeyType {
  const result = enterTypes.get(value);
  if (result === undefined) {
    throw new Error("Invalid editor return key");
  }
  return result;
}
function contentType(value?: string | null): ContentType | undefined {
  if (value == null) {
    return undefined;
  }
  const result = contentTypes.get(value);
  if (result === undefined) {
    throw new Error("Invalid editor autofill type");
  }
  return result;
}

class EditorEvent {
  readonly id: string;
  readonly targetId: number;
  readonly kind: string;
  readonly text: string;
  readonly count: number;
  readonly start: number;
  readonly end: number;
  readonly width: number;
  readonly height: number;
  constructor(
    entry: EditorEntry,
    kind: string,
    text: string,
    start = 0,
    end = 0,
    width = 0,
    height = 0,
  ) {
    this.id = entry.settings.id;
    this.targetId = entry.settings.targetId;
    this.kind = kind;
    this.text = text;
    this.count = entry.count;
    this.start = start;
    this.end = end;
    this.width = width;
    this.height = height;
  }
}

class EditorModifier implements AttributeModifier<TextInputAttribute | TextAreaAttribute> {
  private entry: EditorEntry;
  constructor(entry: EditorEntry) {
    this.entry = entry;
  }
  applyNormalAttribute(node: TextInputAttribute | TextAreaAttribute): void {
    const s = this.entry.settings;
    node
      .width(s.width)
      .height(s.height)
      .padding(0)
      .borderWidth(0)
      .backgroundColor(Color.Transparent)
      .fontSize(s.fontSize)
      .fontWeight(s.fontWeight)
      .fontFamily(s.fontFamily ?? "HarmonyOS Sans")
      .fontStyle(s.italic ? FontStyle.Italic : FontStyle.Normal)
      .fontColor(s.color)
      .placeholderColor(s.placeholderColor)
      .caretColor(s.caretColor)
      .selectedBackgroundColor(s.selectionColor)
      .enabled(s.editable && s.accessibility?.disabled !== true)
      .accessibilityText(s.accessibility?.label ?? "")
      .accessibilityDescription(s.accessibility?.hint ?? "")
      .accessibilityLevel(
        s.accessibility?.hidden === true
          ? "no-hide-descendants"
          : s.accessibility?.accessible === false
            ? "no"
            : "yes",
      )
      .textAlign(s.align as TextAlign)
      .direction(s.rtl ? Direction.Rtl : Direction.Ltr)
      .autoCapitalizationMode(s.capitalize as AutoCapitalizationMode)
      .enterKeyType(enterType(s.enterKey))
      .maxLength(s.maxLength ?? 2147483647)
      .enableAutoFill(s.autoFill)
      .contentType(contentType(s.contentType))
      .hitTestBehavior(s.hitTest as HitTestMode);
    if (s.multiline) {
      (node as TextAreaAttribute).type(areaType(s.keyboard));
    } else {
      (node as TextInputAttribute)
        .type(
          s.secure
            ? s.keyboard === "number"
              ? InputType.NUMBER_PASSWORD
              : InputType.Password
            : inputType(s.keyboard),
        )
        .showPasswordIcon(false)
        .showUnderline(false);
    }
  }
}

@Builder
function editorContent(entry: EditorEntry) {
  if (entry.settings.multiline) {
    TextArea({ text: entry.text, placeholder: entry.settings.placeholder, controller: entry.area })
      .id(entry.settings.id)
      .attributeModifier(new EditorModifier(entry))
      .onChange((text: string) => entry.change(text))
      .onFocus(() => entry.emit("focus"))
      .onBlur(() => entry.emit("blur"))
      .onSubmit((_key: EnterKeyType, event?: SubmitEvent) => entry.submit(event))
      .onTextSelectionChange((start: number, end: number) =>
        entry.emit("selection", "", start, end),
      )
      .onDidInsert((value: InsertValue) => entry.emit("key", value.insertValue))
      .onDidDelete(() => entry.emit("key", "Backspace"))
      .onAppear(() => entry.appeared());
  } else {
    TextInput({ text: entry.text, placeholder: entry.settings.placeholder, controller: entry.line })
      .id(entry.settings.id)
      .attributeModifier(new EditorModifier(entry))
      .onChange((text: string) => entry.change(text))
      .onFocus(() => entry.emit("focus"))
      .onBlur(() => entry.emit("blur"))
      .onSubmit((_key: EnterKeyType, event: SubmitEvent) => entry.submit(event))
      .onTextSelectionChange((start: number, end: number) =>
        entry.emit("selection", "", start, end),
      )
      .onDidInsert((value: InsertValue) => entry.emit("key", value.insertValue))
      .onDidDelete(() => entry.emit("key", "Backspace"))
      .onAppear(() => entry.appeared());
  }
}

// Failed retirement cannot release a BuilderNode still borrowed by native code.
const quarantinedEditors: EditorEntry[] = [];
class EditorSizeCallback extends FrameCallback {
  private entry: EditorEntry;
  constructor(entry: EditorEntry) {
    super();
    this.entry = entry;
  }
  onIdle(_timeLeft: number): void {
    this.entry.measureSize();
  }
}
class EditorEntry {
  readonly node: BuilderNode<[EditorEntry]>;
  readonly line: TextInputController = new TextInputController();
  readonly area: TextAreaController = new TextAreaController();
  settings: EditorSettings;
  private value: ControlledText;
  get text(): string {
    return this.value.text;
  }
  get count(): number {
    return this.value.count;
  }
  private updating: boolean = false;
  private closed: boolean = false;
  private retirementFailure?: Error;
  private focusedOnce: boolean = false;
  private context: BridgeCallContext;
  private sizePending: boolean = false;
  private contentWidth: number = -1;
  private contentHeight: number = -1;
  constructor(settings: EditorSettings, context: BridgeCallContext) {
    this.context = context;
    this.settings = settings;
    this.value = new ControlledText(settings.text, settings.count);
    this.node = new BuilderNode<[EditorEntry]>(context.getUIContext());
  }
  create(): void {
    this.updating = true;
    try {
      this.node.build(wrapBuilder(editorContent), this);
      const response = this.context.invokeNativeSync(
        "native-node-ready",
        "ohos.node.NativeNodeReady",
        "ohos.node.Acknowledgement",
        { targetId: this.settings.targetId, content: this.node.getFrameNode() },
      ) as Acknowledgement;
      if (response.accepted !== true) {
        throw new Error("Native editor target is no longer live");
      }
    } catch (error) {
      this.dispose();
      throw new Error(String(error));
    } finally {
      this.updating = false;
    }
  }
  update(settings: EditorSettings): void {
    if (
      settings.targetId !== this.settings.targetId ||
      settings.multiline !== this.settings.multiline
    ) {
      throw new Error("Editor replacement requires a new generation");
    }
    this.value.update(settings.text, settings.count);
    this.settings = settings;
    this.refresh();
  }
  private refresh(): void {
    this.updating = true;
    try {
      this.node.update(this);
    } finally {
      this.updating = false;
    }
    this.scheduleSize();
  }
  change(text: string): void {
    if (this.updating || this.closed || !this.value.change(text)) {
      return;
    }
    this.emit("change", text);
    this.scheduleSize();
  }
  submit(event?: SubmitEvent): void {
    if (!this.settings.blurOnSubmit) {
      event?.keepEditableState();
    }
    this.emit("submit");
  }
  private scheduleSize(): void {
    if (this.sizePending || this.closed) {
      return;
    }
    this.sizePending = true;
    this.context.getUIContext().postFrameCallback(new EditorSizeCallback(this));
  }
  measureSize(): void {
    this.sizePending = false;
    if (this.closed || !this.context.isActive()) {
      return;
    }
    const rect = this.settings.multiline
      ? this.area.getTextContentRect()
      : this.line.getTextContentRect();
    if (rect.width !== this.contentWidth || rect.height !== this.contentHeight) {
      this.contentWidth = rect.width;
      this.contentHeight = rect.height;
      this.emit("size", "", 0, 0, rect.width, rect.height);
    }
  }
  emit(kind: string, text = "", start = 0, end = 0, width = 0, height = 0): void {
    if (this.updating || this.closed || !this.context.isActive()) {
      return;
    }
    this.context.invokeNativeSync(
      "editor-event",
      "ohos.arkui.EditorEvent",
      "ohos.node.Acknowledgement",
      new EditorEvent(this, kind, text, start, end, width, height),
    );
  }
  appeared(): void {
    this.scheduleSize();
    if (!this.focusedOnce && this.settings.autoFocus) {
      this.focusedOnce = true;
      this.context.getUIContext().getFocusController().requestFocus(this.settings.id);
    }
  }
  command(command: EditorCommand): void {
    if (command.kind === "focus") {
      this.context.getUIContext().getFocusController().requestFocus(this.settings.id);
    } else if (command.kind === "blur") {
      if (this.settings.multiline) {
        this.area.stopEditing();
      } else {
        this.line.stopEditing();
      }
    } else if (command.kind === "selection") {
      if (this.settings.multiline) {
        this.area.setTextSelection(command.start, command.end);
      } else {
        this.line.setTextSelection(command.start, command.end);
      }
    } else {
      throw new Error(`Unsupported editor command '${command.kind}'`);
    }
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
      const response = cleanup.invokeNativeSync(
        "native-node-retiring",
        "ohos.node.NativeNodeRetiring",
        "ohos.node.Acknowledgement",
        { targetId: this.settings.targetId },
      ) as Acknowledgement;
      if (response.accepted !== true) {
        throw new Error("Native editor retirement was rejected");
      }
      this.node.dispose();
    } catch (error) {
      quarantinedEditors.push(this);
      this.retirementFailure = new Error(`Native editor retirement failed: ${String(error)}`);
      throw this.retirementFailure;
    }
  }
}

export class NativeEditors {
  private editors: Map<string, EditorEntry> = new Map();
  apply(payload: BridgeTypedValue, context: BridgeCallContext): BridgeTypedValue {
    expectBridgeRequestType(payload, "ohos.arkui", "apply-editors", "ohos.arkui.EditorBatch");
    const batch = payload.value as EditorBatch;
    if (
      !batch ||
      !Array.isArray(batch.updates) ||
      !Array.isArray(batch.commands) ||
      !Array.isArray(batch.remove)
    ) {
      throw new Error("Invalid editor batch");
    }
    const ids: Set<string> = new Set();
    for (const s of batch.updates) {
      if (
        !s ||
        typeof s.id !== "string" ||
        !s.id ||
        !Number.isInteger(s.targetId) ||
        s.targetId <= 0 ||
        !Number.isFinite(s.width) ||
        !Number.isFinite(s.height) ||
        s.width < 0 ||
        s.height < 0 ||
        typeof s.text !== "string" ||
        !Number.isInteger(s.count) ||
        s.count < 0 ||
        s.count > 4294967295 ||
        !Number.isInteger(s.capitalize) ||
        s.capitalize < 0 ||
        s.capitalize > 3 ||
        (s.multiline && s.secure) ||
        ids.has(s.id) ||
        s.targetId > 0xffffffff ||
        !Number.isFinite(s.fontSize) ||
        s.fontSize < 0 ||
        !Number.isInteger(s.fontWeight) ||
        s.fontWeight < 100 ||
        s.fontWeight > 900 ||
        s.fontWeight % 100 !== 0 ||
        !Number.isInteger(s.align) ||
        s.align < 0 ||
        s.align > 2 ||
        !Number.isInteger(s.hitTest) ||
        s.hitTest < 0 ||
        s.hitTest > 3 ||
        typeof s.placeholder !== "string" ||
        typeof s.multiline !== "boolean" ||
        typeof s.secure !== "boolean" ||
        typeof s.editable !== "boolean" ||
        typeof s.italic !== "boolean" ||
        typeof s.rtl !== "boolean" ||
        typeof s.blurOnSubmit !== "boolean" ||
        typeof s.autoFill !== "boolean" ||
        typeof s.autoFocus !== "boolean" ||
        [s.color, s.placeholderColor, s.caretColor, s.selectionColor].some(
          (color: number): boolean => !Number.isInteger(color) || color < 0 || color > 0xffffffff,
        ) ||
        (s.maxLength != null &&
          (!Number.isInteger(s.maxLength) || s.maxLength < 0 || s.maxLength > 0x7fffffff)) ||
        (s.fontFamily != null && typeof s.fontFamily !== "string") ||
        (s.accessibility != null &&
          (typeof s.accessibility.label !== "string" ||
            typeof s.accessibility.hint !== "string" ||
            typeof s.accessibility.hidden !== "boolean" ||
            typeof s.accessibility.disabled !== "boolean" ||
            (s.accessibility.accessible != null &&
              typeof s.accessibility.accessible !== "boolean")))
      ) {
        throw new Error("Invalid editor state");
      }
      ids.add(s.id);
      if (s.multiline) {
        areaType(s.keyboard);
      } else {
        inputType(s.keyboard);
      }
      enterType(s.enterKey);
      contentType(s.contentType);
      const previous = this.editors.get(s.id);
      if (
        previous &&
        !batch.remove.includes(s.id) &&
        (previous.settings.targetId !== s.targetId || previous.settings.multiline !== s.multiline)
      ) {
        throw new Error("Editor replacement requires a new generation");
      }
    }
    if (
      batch.remove.some((id: string): boolean => typeof id !== "string" || !id) ||
      batch.commands.some(
        (command: EditorCommand): boolean =>
          !command ||
          typeof command.id !== "string" ||
          !command.id ||
          !["focus", "blur", "selection"].includes(command.kind) ||
          !Number.isInteger(command.start) ||
          !Number.isInteger(command.end) ||
          command.start < 0 ||
          command.start > command.end ||
          command.end > 0x7fffffff,
      )
    ) {
      throw new Error("Invalid editor command");
    }
    for (const id of batch.remove) {
      this.editors.get(id)?.dispose();
      this.editors.delete(id);
    }
    for (const s of batch.updates) {
      const previous = this.editors.get(s.id);
      if (previous) {
        previous.update(s);
      } else {
        const entry = new EditorEntry(s, context);
        entry.create();
        this.editors.set(s.id, entry);
      }
    }
    for (const command of batch.commands) {
      this.editors.get(command.id)?.command(command);
    }
    return { typeName: "ohos.node.Acknowledgement", value: { accepted: true } };
  }
  dispose(cleanup: BridgePluginContext): void {
    let firstError: Error | undefined;
    for (const entry of this.editors.values()) {
      try {
        entry.dispose(cleanup);
      } catch (error) {
        firstError = firstError ?? new Error(String(error));
      }
    }
    this.editors.clear();
    if (firstError) {
      throw firstError;
    }
  }
}
