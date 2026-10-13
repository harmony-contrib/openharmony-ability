import { inputConsumer } from "@kit.InputKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeTypedValue,
  BridgeContextRequirement,
  BridgeAcknowledgement,
  DOMAIN,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

// ── Bridge type name contracts ────────────────────────────────────────────────
// These must match the Rust-side `impl_bridge_napi_type!` TYPE_NAME values.

const REGISTER_REQUEST_TYPE = "ohos.global-shortcut.RegisterRequest";
const UNREGISTER_REQUEST_TYPE = "ohos.global-shortcut.UnregisterRequest";
const UNREGISTER_ALL_REQUEST_TYPE = "ohos.global-shortcut.UnregisterAllRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.global-shortcut.Acknowledgement";
const TRIGGERED_EVENT_TYPE = "ohos.global-shortcut.TriggeredEvent";

// ── Modifier name → OHOS KeyCode mapping ──────────────────────────────────────
// Keys use the cross-platform Modifier enum names defined by the embedding runtime: "Control", "Shift", "Alt", "Super".
// (The legacy helper used "Ctrl" / "Meta"; the bridge plugin uses the updated names.)

const MODIFIER_MAP: Map<string, number> = new Map([
  ["Control", 2072], // KEYCODE_CTRL_LEFT
  ["Shift", 2047],   // KEYCODE_SHIFT_LEFT
  ["Alt", 2045],     // KEYCODE_ALT_LEFT
  ["Super", 2076],   // KEYCODE_META_LEFT
]);

// ── Key name → OHOS KeyCode mapping ───────────────────────────────────────────
// Covers letters A-Z, digits 0-9, function keys F1-F24, and common special keys.

const KEY_MAP: Map<string, number> = new Map([
  // Letters: KEYCODE_A (2017) through KEYCODE_Z (2042)
  ["A", 2017], ["B", 2018], ["C", 2019], ["D", 2020],
  ["E", 2021], ["F", 2022], ["G", 2023], ["H", 2024],
  ["I", 2025], ["J", 2026], ["K", 2027], ["L", 2028],
  ["M", 2029], ["N", 2030], ["O", 2031], ["P", 2032],
  ["Q", 2033], ["R", 2034], ["S", 2035], ["T", 2036],
  ["U", 2037], ["V", 2038], ["W", 2039], ["X", 2040],
  ["Y", 2041], ["Z", 2042],
  // Digits: KEYCODE_0 (2000) through KEYCODE_9 (2009)
  ["0", 2000], ["1", 2001], ["2", 2002], ["3", 2003], ["4", 2004],
  ["5", 2005], ["6", 2006], ["7", 2007], ["8", 2008], ["9", 2009],
  // Function keys F1-F12
  ["F1", 2090], ["F2", 2091], ["F3", 2092], ["F4", 2093],
  ["F5", 2094], ["F6", 2095], ["F7", 2096], ["F8", 2097],
  ["F9", 2098], ["F10", 2099], ["F11", 2100], ["F12", 2101],
  // F13-F24
  ["F13", 2816], ["F14", 2817], ["F15", 2818], ["F16", 2819],
  ["F17", 2820], ["F18", 2821], ["F19", 2822], ["F20", 2823],
  ["F21", 2824], ["F22", 2825], ["F23", 2826], ["F24", 2827],
  // Special keys
  // NOTE: "Home" maps to KeyCode 1 (KEYCODE_HOME) which is the system Home button,
  //       NOT the keyboard Home key (move cursor to line start). OHOS has no
  //       independent keyboard Home key code. This limitation is inherited from
  //       the legacy implementation and retained for compatibility.
  ["Space", 2050],     // KEYCODE_SPACE
  ["Enter", 2054],     // KEYCODE_ENTER
  ["Escape", 2070],    // KEYCODE_ESCAPE
  ["Tab", 2049],       // KEYCODE_TAB
  ["Backspace", 2055], // KEYCODE_DEL
  ["Delete", 2071],    // KEYCODE_FORWARD_DEL
  ["Insert", 2083],    // KEYCODE_INSERT
  ["Home", 1],         // KEYCODE_HOME — system Home button, not keyboard Home
  ["End", 2082],       // KEYCODE_MOVE_END
  ["PageUp", 2068],    // KEYCODE_PAGE_UP
  ["PageDown", 2069],  // KEYCODE_PAGE_DOWN
  ["ArrowUp", 2012],   // KEYCODE_DPAD_UP
  ["ArrowDown", 2013], // KEYCODE_DPAD_DOWN
  ["ArrowLeft", 2014], // KEYCODE_DPAD_LEFT
  ["ArrowRight", 2015],// KEYCODE_DPAD_RIGHT
]);

// ── Registration tracking ────────────────────────────────────────────────────

interface RegisterRequestPayload {
  id: number;
  modifiers: string[];
  key: string;
  // Operation sequence number taken by the Rust side at dispatch time.
  // A register arriving with a generation older than the newest request
  // served for this id (or older than the global unregister-all floor) is
  // stale and rejected — see the ghost-hotkey race note on the class.
  generation: number;
}

interface UnregisterRequestPayload {
  id: number;
  // Raises the per-id generation watermark: an in-flight register for the
  // same id dispatched before this call (smaller generation) is rejected
  // when it arrives.
  generation: number;
}

interface UnregisterAllRequestPayload {
  // Raises the global generation floor: any in-flight register dispatched
  // before this sweep (smaller generation) is rejected on arrival instead
  // of resurrecting a hotkey the Rust side no longer tracks.
  generation: number;
}

class ShortcutTriggeredEventPayload {
  readonly id: number;
  readonly state: string;

  constructor(id: number, state: string) {
    this.id = id;
    this.state = state;
  }
}

interface RegisteredHotkey {
  options: inputConsumer.HotkeyOptions;
  callback: (hotkey: inputConsumer.HotkeyOptions) => void;
}

function ack(accepted: boolean): BridgeTypedValue {
  return {
    typeName: ACKNOWLEDGEMENT_TYPE,
    value: new BridgeAcknowledgement(accepted),
  };
}

export class GlobalShortcutPlugin extends AsyncPluginBase {
  readonly id = "ohos.global-shortcut";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  private registeredHotkeys: Map<number, RegisteredHotkey> = new Map();

  // ── Registration generations (ghost-hotkey race) ──────────────────────────
  // Registration on the Rust side is fire-and-forget: the local store is
  // updated synchronously while the physical `inputConsumer.on()` happens
  // here, asynchronously and possibly out of order. Without a guard, an
  // in-flight register dispatched before a later unregister / unregister-all
  // would arrive afterwards and resurrect a physical registration the Rust
  // side no longer tracks: a "ghost hotkey" that still triggers, reports
  // `isRegistered: false`, and can never be cleared through the plugin API.
  //
  // Every request carries a monotonic `generation` (the Rust side's global
  // operation counter, sampled at dispatch time). We track the highest
  // generation served — globally (`generationFloor`) and per id
  // (`idGenerations`) — and reject any request carrying an older one. The
  // rejection flows back as a normal registration error, whose Rust-side
  // cleanup is a no-op against the already-updated store.

  // Highest unregister-all generation served; registers carrying a smaller
  // generation predate that sweep and are rejected on arrival.
  private generationFloor: number = 0;

  // Highest generation served per hotkey id; requests (register or
  // unregister) carrying a smaller generation for the same id are stale.
  private idGenerations: Map<number, number> = new Map();

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Bridge session is no longer active");
    }

    if (action === "register") {
      const request = expectBridgeRequestType(payload, "ohos.global-shortcut", action, REGISTER_REQUEST_TYPE) as RegisterRequestPayload;
      hilog.info(DOMAIN, "GlobalShortcut", "register ENTER id=%{public}d key=%{public}s modifiers=[%{public}s] generation=%{public}d",
        request.id, request.key, request.modifiers.join(','), request.generation);
      return ack(this.registerHotkey(request));
    }

    if (action === "unregister") {
      const request = expectBridgeRequestType(payload, "ohos.global-shortcut", action, UNREGISTER_REQUEST_TYPE) as UnregisterRequestPayload;
      hilog.info(DOMAIN, "GlobalShortcut", "unregister id=%{public}d generation=%{public}d", request.id, request.generation);
      return ack(this.unregisterHotkey(request));
    }

    if (action === "unregister-all") {
      const request = expectBridgeRequestType(payload, "ohos.global-shortcut", action, UNREGISTER_ALL_REQUEST_TYPE) as UnregisterAllRequestPayload;
      hilog.info(DOMAIN, "GlobalShortcut", "unregister-all generation=%{public}d", request.generation);
      return ack(this.unregisterAllHotkeys(request.generation));
    }

    throw new Error(`Unsupported ohos.global-shortcut action '${action}'`);
  }

  onDispose(): void {
    // MAX_SAFE_INTEGER raises the floor past every live generation: nothing
    // may re-register after dispose.
    this.unregisterAllHotkeys(Number.MAX_SAFE_INTEGER);
  }

  // ── Registration logic ──────────────────────────────────────────────────────

  private registerHotkey(request: RegisterRequestPayload): boolean {
    const id = request.id;

    // Stale-generation guards (see the class comment): a register dispatched
    // before a later unregister-all / unregister / re-register must not
    // (re)create a physical registration the Rust side no longer tracks.
    if (request.generation < this.generationFloor) {
      hilog.info(DOMAIN, "GlobalShortcut",
        "stale register id=%{public}d generation=%{public}d < floor=%{public}d (superseded by unregister-all), rejected",
        id, request.generation, this.generationFloor);
      return false;
    }
    const served = this.idGenerations.get(id);
    if (served !== undefined && request.generation < served) {
      hilog.info(DOMAIN, "GlobalShortcut",
        "stale register id=%{public}d generation=%{public}d < served=%{public}d (superseded by a later request for this id), rejected",
        id, request.generation, served);
      return false;
    }

    // Resolve modifier key codes
    const preKeys: number[] = [];
    for (const modifierName of request.modifiers) {
      const code = MODIFIER_MAP.get(modifierName);
      if (code === undefined) {
        hilog.error(DOMAIN, "GlobalShortcut", "Unknown modifier '%{public}s' for id=%{public}d", modifierName, id);
        return false;
      }
      preKeys.push(code);
    }

    // Resolve final key code
    const finalKey = KEY_MAP.get(request.key);
    if (finalKey === undefined) {
      hilog.error(DOMAIN, "GlobalShortcut", "Unknown key '%{public}s' for id=%{public}d", request.key, id);
      return false;
    }

    if (preKeys.length === 0) {
      hilog.error(DOMAIN, "GlobalShortcut", "No valid modifiers for id=%{public}d", id);
      return false;
    }

    const hotkeyOptions: inputConsumer.HotkeyOptions = {
      preKeys: preKeys,
      finalKey: finalKey,
      isRepeat: false,
    };

    // If re-registering the same ID, unregister the old one first
    // (reached only after the stale-generation guards above, so this is a
    // genuinely newer registration replacing an older one).
    if (this.registeredHotkeys.has(id)) {
      this.unregisterHotkeyById(id);
    }

    // Create the callback that pushes Pressed + Released events back to Rust
    const pluginContext = this.getContext();
    const callback = (_hotkey: inputConsumer.HotkeyOptions): void => {
      hilog.info(DOMAIN, "GlobalShortcut", "hotkeyChange callback fired id=%{public}d", id);
      // OHOS inputConsumer only fires on key-down; synthesize both Pressed and Released.
      try {
        pluginContext.invokeNativeSync(
          "on-shortcut-triggered",
          TRIGGERED_EVENT_TYPE,
          "std.bool",
          new ShortcutTriggeredEventPayload(id, "Pressed") as ESObject,
        );
        hilog.info(DOMAIN, "GlobalShortcut", "Pressed event dispatched id=%{public}d", id);
      } catch (error) {
        hilog.error(DOMAIN, "GlobalShortcut", "Failed to dispatch Pressed event for id=%{public}d: %{public}s", id, String(error));
      }
      try {
        pluginContext.invokeNativeSync(
          "on-shortcut-triggered",
          TRIGGERED_EVENT_TYPE,
          "std.bool",
          new ShortcutTriggeredEventPayload(id, "Released") as ESObject,
        );
      } catch (error) {
        hilog.error(DOMAIN, "GlobalShortcut", "Failed to dispatch Released event for id=%{public}d: %{public}s", id, String(error));
      }
    };

    try {
      inputConsumer.on("hotkeyChange", hotkeyOptions, callback);
      this.registeredHotkeys.set(id, { options: hotkeyOptions, callback });
      // Raise the per-id watermark only after the physical registration
      // succeeded, so the generation we served is the one that is live.
      this.idGenerations.set(id, request.generation);
      hilog.info(DOMAIN, "GlobalShortcut", "Registered hotkey id=%{public}d key=%{public}s modifiers=%{public}s",
        id, request.key, request.modifiers.join('+'));
      return true;
    } catch (err) {
      const error = err as BusinessError;
      const code = error.code ?? -1;
      if (code === 801) {
        // Device does not support inputConsumer capability — not an error, just unsupported.
        hilog.info(DOMAIN, "GlobalShortcut", "inputConsumer not supported on this device (error 801), skipping id=%{public}d", id);
      } else if (code === 4200002) {
        hilog.warn(DOMAIN, "GlobalShortcut", "Hotkey id=%{public}d is occupied by the system", id);
      } else if (code === 4200003) {
        hilog.warn(DOMAIN, "GlobalShortcut", "Hotkey id=%{public}d is already subscribed by another app", id);
      } else {
        hilog.error(DOMAIN, "GlobalShortcut", "Failed to register hotkey id=%{public}d: code=%{public}d, message=%{public}s",
          id, code, error.message);
      }
      return false;
    }
  }

  private unregisterHotkey(request: UnregisterRequestPayload): boolean {
    const id = request.id;

    // Stale-generation guard, symmetric with register: an unregister
    // dispatched before a later re-register of the same id must not remove
    // the newer physical registration.
    const served = this.idGenerations.get(id);
    if (served !== undefined && request.generation < served) {
      hilog.info(DOMAIN, "GlobalShortcut",
        "stale unregister id=%{public}d generation=%{public}d < served=%{public}d, skipped",
        id, request.generation, served);
      return true;
    }

    // Raise the per-id watermark even when nothing is physically registered
    // (idempotent unregister): an in-flight register for this id dispatched
    // before this call carries a smaller generation and will be rejected on
    // arrival.
    this.idGenerations.set(id, request.generation);
    return this.unregisterHotkeyById(id);
  }

  private unregisterHotkeyById(id: number): boolean {
    const entry = this.registeredHotkeys.get(id);
    if (!entry) {
      // Idempotent — unregistering an unknown ID is a no-op.
      return true;
    }
    try {
      inputConsumer.off("hotkeyChange", entry.options, entry.callback);
      hilog.info(DOMAIN, "GlobalShortcut", "Unregistered hotkey id=%{public}d", id);
    } catch (err) {
      const error = err as BusinessError;
      hilog.error(DOMAIN, "GlobalShortcut", "Failed to unregister hotkey id=%{public}d: code=%{public}d, message=%{public}s",
        id, error.code, error.message);
    }
    this.registeredHotkeys.delete(id);
    return true;
  }

  private unregisterAllHotkeys(generation: number): boolean {
    // Raise the global generation floor: register requests carrying a
    // smaller generation predate this sweep and are rejected on arrival —
    // the ArkTS-side half of the ghost-hotkey race fix. Every recorded
    // per-id watermark is smaller than this sweep's generation (the Rust
    // counter is monotonic), so the floor subsumes them.
    if (generation > this.generationFloor) {
      this.generationFloor = generation;
    }
    this.idGenerations.clear();
    const ids = Array.from(this.registeredHotkeys.keys());
    for (const id of ids) {
      this.unregisterHotkeyById(id);
    }
    return true;
  }
}
