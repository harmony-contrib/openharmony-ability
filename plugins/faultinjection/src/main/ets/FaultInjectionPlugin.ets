/**
 * Fault injection registry + bridge plugin for coverage testing.
 *
 * A regular `@ohos-rs/ability-plugin-fault-injection` HAR (paired with
 * `crates/plugin-fault-injection`), installed on demand like every other
 * plugin: apps list `new LazyPlugin(() => new FaultInjectionPlugin())` in
 * `NativeAbility#bridgePlugins` and register the Rust
 * `FaultInjectionBridgePlugin` declaration.
 *
 * Interception runs through the generic `BridgeHost` dispatch-hook seam: the
 * plugin registers one `BridgeDispatchHook` in `onInstall`, and the host
 * consults it before every plugin invocation (including this plugin's own
 * actions). Outcome kinds map onto hook primitives:
 * - `error` / `exception` / `timeout` → throw (fails the call)
 * - `delay` → returned Promise (delays async dispatch; the sync path cannot
 *   await one, so delay/timeout rules are consumed with no effect there —
 *   same behavior as the former built-in version)
 *
 * The registry flag `enabled` defaults to `false` and `match()` short-circuits
 * on its first line — production builds that never call "enable" pay zero
 * overhead.
 */

import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeDispatchHook,
  BridgePluginHookContext,
  BridgeTypedValue,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

const FAULT_PLUGIN_ID = "ohos.fault-injection";
const NOOP_REQUEST_TYPE = "ohos.fault-injection.NoopRequest";
const SET_RULE_REQUEST_TYPE = "ohos.fault-injection.SetRuleRequest";
const ACK_TYPE = "ohos.fault-injection.Ack";

/** Outcome descriptor — mirrors the Rust `FaultOutcomeWire` struct (camelCase via NAPI). */
interface FaultOutcome {
  kind: string; // "error" | "exception" | "delay" | "timeout"
  code?: number;
  message?: string;
  ms?: number;
}

/** Wire shape of a fault rule — mirrors Rust `FaultRuleWire` (camelCase via NAPI). */
interface FaultRuleWire {
  pluginId: string;
  action?: string;
  outcome: FaultOutcome;
  hits?: number;
}

/** Internal rule with bookkeeping fields. */
interface FaultRule {
  pluginId: string;
  action: string; // "" = match all actions of this plugin
  outcome: FaultOutcome;
  hits: number; // remaining hits; -1 = permanent until clear
  consumed: number;
}

class FaultInjectionRegistry {
  private rules: FaultRule[] = [];
  private enabled: boolean = false;

  enable(): void {
    this.enabled = true;
  }

  disable(): void {
    this.enabled = false;
    this.rules = [];
  }

  setRule(rule: FaultRule): void {
    this.rules.unshift(rule);
  }

  clear(): void {
    this.rules = [];
  }

  match(pluginId: string, action: string): FaultOutcome | undefined {
    if (!this.enabled) {
      return undefined;
    }
    for (let i = 0; i < this.rules.length; i++) {
      const r = this.rules[i];
      if (r.pluginId !== pluginId) {
        continue;
      }
      if (r.action !== "" && r.action !== action) {
        continue;
      }
      const outcome = r.outcome;
      r.consumed++;
      if (r.hits !== -1) {
        r.hits--;
        if (r.hits <= 0) {
          this.rules.splice(i, 1);
        }
      }
      return outcome;
    }
    return undefined;
  }
}

/** Module-level singleton — rules survive Ability sessions, like the former built-in. */
const FAULT_REGISTRY = new FaultInjectionRegistry();

/** Acknowledgement response class — mirrors the Rust `FaultInjectionAck` type. */
class FaultInjectionAck {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

/** Throws the injected outcome for the error/exception kinds; no-op otherwise. */
const throwIfImmediate = (fault: FaultOutcome): void => {
  if (fault.kind === "error") {
    throw new Error(`${fault.code}:${fault.message ?? "fault-injected"}`);
  }
  if (fault.kind === "exception") {
    throw new Error(fault.message ?? "fault-injected exception");
  }
};

/**
 * Fault injection bridge plugin for ArkTS.
 *
 * Actions: "enable", "disable", "clear", "set-rule". `requires: []` — no
 * context dependency, available immediately after installation.
 */
export class FaultInjectionPlugin extends AsyncPluginBase {
  readonly id = FAULT_PLUGIN_ID;
  readonly requires: BridgeContextRequirement[] = [];

  private readonly hook: BridgeDispatchHook = {
    onDispatchAsync: (pluginId: string, action: string): void | Promise<void> => {
      const fault = FAULT_REGISTRY.match(pluginId, action);
      if (fault === undefined) {
        return undefined;
      }
      if (fault.kind === "delay") {
        // delay falls through to normal invokeAsync after the wait
        return new Promise<void>((r) => setTimeout(r, fault.ms ?? 0));
      }
      if (fault.kind === "timeout") {
        throw new Error(`Bridge call '${pluginId}.${action}' timed out after injected timeout`);
      }
      throwIfImmediate(fault);
      return undefined;
    },
    onDispatchSync: (pluginId: string, action: string): void => {
      const fault = FAULT_REGISTRY.match(pluginId, action);
      if (fault === undefined) {
        return;
      }
      // Sync path only supports error/exception — delay/timeout would block
      // the NAPI callback thread (rule consumed, call proceeds, parity with
      // the former built-in version).
      throwIfImmediate(fault);
    },
  };

  onInstall(context: BridgePluginHookContext): void {
    context.registerDispatchHook(this.hook);
  }

  async invokeAsync(
    action: string,
    request: BridgeTypedValue,
    _ctx: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (action === "enable" || action === "disable" || action === "clear") {
      expectBridgeRequestType(request, FAULT_PLUGIN_ID, action, NOOP_REQUEST_TYPE);
      if (action === "enable") {
        FAULT_REGISTRY.enable();
      } else if (action === "disable") {
        FAULT_REGISTRY.disable();
      } else {
        FAULT_REGISTRY.clear();
      }
      return { typeName: ACK_TYPE, value: new FaultInjectionAck(true) };
    }
    if (action === "set-rule") {
      expectBridgeRequestType(request, FAULT_PLUGIN_ID, action, SET_RULE_REQUEST_TYPE);
      const r = request.value as FaultRuleWire;
      FAULT_REGISTRY.setRule({
        pluginId: r.pluginId,
        action: r.action ?? "",
        outcome: r.outcome,
        hits: r.hits ?? -1,
        consumed: 0,
      });
      return { typeName: ACK_TYPE, value: new FaultInjectionAck(true) };
    }
    throw new Error(`Unsupported ohos.fault-injection action '${action}'`);
  }
}
