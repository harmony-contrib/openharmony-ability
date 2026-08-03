import { NativeModuleLoader } from "./NativeModuleLoader";

/**
 * Dispatches an `@Entry` page's synchronous `onBackPress` callback to its already-loaded native
 * module. Return this value directly from the page callback: `true` consumes back, `false` lets
 * ArkUI perform its default navigation.
 */
export function invokeNativeBackPressInterceptor(moduleName: string): boolean {
  return NativeModuleLoader.invokeBackPressInterceptor(moduleName);
}
