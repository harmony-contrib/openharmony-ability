import webview from "@ohos.web.webview";
import { BridgePluginContext, BridgeAcknowledgement } from "@ohos-rs/ability";

export interface NativeWebviewSettings {
  id: string;
  scrollEnabled: boolean;
  injectedJavascript?: string | null;
  htmlBaseUrl?: string | null;
}
export function parseNativeSettings(settings: NativeWebviewSettings): NativeWebviewSettings {
  if (
    !settings ||
    typeof settings.id !== "string" ||
    !settings.id.trim() ||
    typeof settings.scrollEnabled !== "boolean" ||
    (settings.injectedJavascript !== undefined &&
      settings.injectedJavascript !== null &&
      typeof settings.injectedJavascript !== "string") ||
    (settings.htmlBaseUrl !== undefined &&
      settings.htmlBaseUrl !== null &&
      typeof settings.htmlBaseUrl !== "string")
  ) {
    throw new Error("Invalid native WebView settings");
  }
  return settings;
}
export interface NativeWebviewData {
  id: string;
  nativeTag: string;
  nativeTarget: number | null;
  nativeGeneration: number;
  nativeActive: boolean;
  nativeAttached: boolean;
  nativeControllerAttached: boolean;
  nativeTasks: Set<Promise<void>>;
  javascriptEnabled?: boolean | null;
  nativeSettings: NativeWebviewSettings | null;
  nativeLoading: boolean;
  nativeEpoch: number;
  controller: webview.WebviewController;
}
class NativeWebviewEvent {
  readonly id: string;
  readonly targetId: number;
  readonly generation: number;
  readonly phase: string;
  readonly url: string;
  readonly title: string;
  readonly loading: boolean;
  readonly canGoBack: boolean;
  readonly canGoForward: boolean;
  readonly message?: string;
  readonly code?: number;
  constructor(data: NativeWebviewData, phase: string, message?: string, code?: number) {
    this.id = data.id;
    this.targetId = data.nativeTarget!;
    this.generation = data.nativeGeneration;
    this.phase = phase;
    this.url = data.controller.getUrl();
    this.title = data.controller.getTitle();
    this.loading = data.nativeLoading;
    this.canGoBack = data.controller.accessBackward();
    this.canGoForward = data.controller.accessForward();
    this.message = message;
    this.code = code;
  }
}
export function nativeEvent(
  context: BridgePluginContext,
  data: NativeWebviewData,
  phase: string,
  message?: string,
  code?: number,
): void {
  if (data.nativeTarget === null || !data.nativeActive) {
    return;
  }
  if (phase === "start") {
    data.nativeLoading = true;
    data.nativeEpoch++;
  }
  if (phase === "finish" || phase === "error") {
    data.nativeLoading = false;
  }
  try {
    const response = context.invokeNativeSync(
      "native-event",
      "ohos.webview.NativeEvent",
      "ohos.webview.EventAcknowledgement",
      new NativeWebviewEvent(data, phase, message, code),
    ) as BridgeAcknowledgement;
    if (response?.accepted !== true) {
      throw new Error("Native WebView event was rejected");
    }
  } catch (error) {
    console.error("Native WebView event: " + String(error));
  }
}
export async function nativePageEnd(
  context: BridgePluginContext,
  data: NativeWebviewData,
): Promise<void> {
  if (data.nativeTarget === null || !data.nativeActive) {
    return;
  }
  const epoch = data.nativeEpoch;
  const script = data.nativeSettings?.injectedJavascript;
  if (script && data.javascriptEnabled !== false) {
    try {
      await data.controller.runJavaScript(script);
    } catch (error) {
      if (data.nativeActive && epoch === data.nativeEpoch) {
        nativeEvent(context, data, "error", String(error));
      }
    }
  }
  if (data.nativeActive && epoch === data.nativeEpoch) {
    nativeEvent(context, data, "finish");
  }
}

export function trackNativePageEnd(context: BridgePluginContext, data: NativeWebviewData): void {
  if (data.nativeTarget === null || !data.nativeActive) {
    return;
  }
  const task = nativePageEnd(context, data);
  data.nativeTasks.add(task);
  task.then(
    () => data.nativeTasks.delete(task),
    () => data.nativeTasks.delete(task),
  );
}
