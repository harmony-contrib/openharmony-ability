const STATE_MAP_PREFIX = "ohos.rs.ability.state-map.v1:";

/** Deterministic, non-bridge encoding for per-module Ability recovery state. */
export class AbilityStateCodec {
  static decode(rawState: string): Record<string, string> {
    if (!rawState.startsWith(STATE_MAP_PREFIX)) {
      return {};
    }

    try {
      const mapped: Record<string, string> = {};
      const encodedEntries = rawState.slice(STATE_MAP_PREFIX.length);
      if (!encodedEntries) {
        return mapped;
      }
      for (const entry of encodedEntries.split("&")) {
        const separator = entry.indexOf("=");
        if (separator <= 0) {
          return {};
        }
        const moduleName = decodeURIComponent(entry.slice(0, separator));
        const state = decodeURIComponent(entry.slice(separator + 1));
        if (!moduleName) {
          return {};
        }
        mapped[moduleName] = state;
      }
      return mapped;
    } catch {
      return {};
    }
  }

  static encode(stateMap: Record<string, string>): string {
    const entries: string[] = [];
    for (const moduleName of Object.keys(stateMap).sort()) {
      entries.push(`${encodeURIComponent(moduleName)}=${encodeURIComponent(stateMap[moduleName])}`);
    }
    return STATE_MAP_PREFIX + entries.join("&");
  }
}
