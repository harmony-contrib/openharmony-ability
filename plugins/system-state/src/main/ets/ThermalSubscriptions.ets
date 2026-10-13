import thermal from "@ohos.thermal";

/** The platform has one thermal callback on the ArkTS thread, shared by all hosts. */
export class ThermalSubscriptions {
  private static readonly listeners: Set<(level: thermal.ThermalLevel) => void> = new Set();
  private static registered: boolean = false;
  private static readonly dispatch = (level: thermal.ThermalLevel): void => {
    for (const listener of Array.from(ThermalSubscriptions.listeners)) {
      if (!ThermalSubscriptions.listeners.has(listener)) {
        continue;
      }
      try {
        listener(level);
      } catch (error) {
        console.warn(`[SystemState] thermal listener failed: ${String(error)}`);
      }
    }
  };

  static subscribe(listener: (level: thermal.ThermalLevel) => void): () => void {
    ThermalSubscriptions.listeners.add(listener);
    if (!ThermalSubscriptions.registered) {
      try {
        thermal.registerThermalLevelCallback(ThermalSubscriptions.dispatch);
        ThermalSubscriptions.registered = true;
      } catch (error) {
        ThermalSubscriptions.listeners.delete(listener);
        throw error as Error;
      }
    }
    let released = false;
    return (): void => {
      if (released) {
        return;
      }
      released = true;
      ThermalSubscriptions.listeners.delete(listener);
      if (ThermalSubscriptions.listeners.size === 0 && ThermalSubscriptions.registered) {
        try {
          thermal.unregisterThermalLevelCallback();
        } finally {
          // A later subscription can replace a stale platform callback if unregister failed.
          ThermalSubscriptions.registered = false;
        }
      }
    };
  }
}
