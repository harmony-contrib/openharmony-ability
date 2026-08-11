import { Module } from "../ability/type";

/** Module loading is framework runtime infrastructure, not a capability Helper. */
export class NativeModuleLoader {
  private static modules: Record<string, Module> = {};

  private static isCurrentModule(value: ESObject): boolean {
    return (
      value !== null &&
      typeof value === "object" &&
      typeof value.init === "function" &&
      typeof value.disposeBridge === "function" &&
      typeof value.render === "function" &&
      typeof value.disposeRender === "function" &&
      typeof value.disposeAllRenders === "function"
    );
  }

  static resolveModuleNames(name: string | string[]): string[] {
    const names = Array.isArray(name) ? name : [name];
    const resolved: string[] = [];

    for (const item of names) {
      const moduleName = item.trim();
      if (!moduleName) {
        throw new Error("moduleName entries must not be empty");
      }
      if (resolved.indexOf(moduleName) !== -1) {
        throw new Error(
          `Native module '${moduleName}' is declared more than once; every DefaultXComponent needs a distinct module`,
        );
      }
      if (moduleName.startsWith("lib") || moduleName.endsWith(".so")) {
        throw new Error(`moduleName must not include lib/.so wrapper: ${moduleName}`);
      }
      resolved.push(moduleName);
    }

    return resolved;
  }

  static async load(moduleName: string, mode: "async" | "sync" = "async"): Promise<Module> {
    const resolvedModuleName = NativeModuleLoader.resolveModuleNames(moduleName)[0] ?? "";
    const cached = NativeModuleLoader.modules[resolvedModuleName];
    if (cached) {
      return cached;
    }

    const libraryName = `lib${resolvedModuleName}.so`;
    let currentModule: ESObject;
    if (mode === "async") {
      currentModule = await import(libraryName);
    } else {
      try {
        currentModule = loadNativeModule(libraryName);
      } catch (error) {
        throw new Error(`${libraryName} failed to load: ${String(error)}`);
      }
    }

    let module: Module | null = null;
    if (NativeModuleLoader.isCurrentModule(currentModule)) {
      module = currentModule as Module;
    } else if (NativeModuleLoader.isCurrentModule(currentModule?.default)) {
      module = currentModule.default as Module;
    }

    if (!module) {
      throw new Error(
        `${libraryName} does not implement the current native module session/render contract`,
      );
    }

    NativeModuleLoader.modules[resolvedModuleName] = module;
    return module;
  }

  /**
   * Invokes a loaded module's synchronous back-press interceptor. This is intentionally separate
   * from loading: ArkTS requires `onBackPress` to return synchronously, so a page must not trigger
   * a dynamic import while deciding whether to consume the system back action.
   */
  static invokeBackPressInterceptor(moduleName: string): boolean {
    const module = NativeModuleLoader.modules[moduleName.trim()];
    if (module === undefined) {
      return false;
    }
    try {
      if (typeof module.onBackPressIntercept === "function") {
        return module.onBackPressIntercept();
      }
      if (typeof module.on_back_press_intercept === "function") {
        return module.on_back_press_intercept();
      }
    } catch (error) {
      console.error(`Native back-press interceptor failed: ${String(error)}`);
    }
    return false;
  }
}
