import { Module } from "../ability/type";

export class Loadable {
  private static modMap: Record<string, Module> = {};

  static resolveModuleNames(name: string | string[]): string[] {
    const names = Array.isArray(name) ? name : [name];
    const resolved: string[] = [];

    for (const item of names) {
      const moduleName = item.trim();
      if (!moduleName || resolved.indexOf(moduleName) !== -1) {
        continue;
      }
      if (moduleName.startsWith("lib") || moduleName.endsWith(".so")) {
        throw new Error(`moduleName must not include lib/.so wrapper: ${moduleName}`);
      }
      resolved.push(moduleName);
    }

    return resolved;
  }

  static resolvePrimaryModuleName(name: string | string[]): string {
    const names = Loadable.resolveModuleNames(name);
    return names.length > 0 ? names[0] : "";
  }

  static toLibraryName(moduleName: string): string {
    return `lib${moduleName}.so`;
  }

  static async load(moduleName: string, mode: "async" | "sync" = "async"): Promise<Module> {
    const resolvedModuleName = Loadable.resolvePrimaryModuleName(moduleName);
    const cached = Loadable.modMap[resolvedModuleName];
    if (cached) {
      return cached;
    }

    const libraryName = Loadable.toLibraryName(resolvedModuleName);
    let currentMod: ESObject;
    if (mode === "async") {
      currentMod = await import(libraryName);
    } else {
      try {
        currentMod = loadNativeModule(libraryName);
      } catch (error) {
        throw new Error(`${libraryName} failed to load: ${String(error)}`);
      }
    }

    let loadedModule: Module | null = null;
    if (typeof currentMod?.render === "function" && typeof currentMod?.init === "function") {
      loadedModule = currentMod as Module;
    } else if (
      typeof currentMod?.default?.render === "function" &&
      typeof currentMod?.default?.init === "function"
    ) {
      loadedModule = currentMod.default as Module;
    }

    if (!loadedModule) {
      throw new Error(`${libraryName} is not a valid dynamic library`);
    }

    Loadable.modMap[resolvedModuleName] = loadedModule;
    return loadedModule;
  }
}
