import webview from "@ohos.web.webview";

export const ASYNC_SCRIPT_RESPONSE_TYPE = "ohos.webview.AsyncScriptResponse";
export const ASYNC_EVAL_PROXY_NAME = "__abilityAsyncEval";

const DEFAULT_EVAL_TIMEOUT_MS = 55_000;
const MIN_EVAL_TIMEOUT_MS = 100;
const MAX_EVAL_TIMEOUT_MS = 300_000;

export class WebviewAsyncScriptResponse {
  readonly ok: boolean;
  readonly value?: string;
  readonly error?: string;
  readonly isSyntaxError: boolean;

  constructor(
    ok: boolean,
    value: string | undefined,
    error: string | undefined,
    isSyntaxError: boolean,
  ) {
    this.ok = ok;
    if (value !== undefined) {
      this.value = value;
    }
    if (error !== undefined) {
      this.error = error;
    }
    this.isSyntaxError = isSyntaxError;
  }
}

interface PendingAsyncEval {
  settle: (response: WebviewAsyncScriptResponse) => void;
}

class AsyncEvalJsProxy {
  private readonly onComplete: (
    token: string,
    ok: boolean,
    hasValue: boolean,
    payload: string,
  ) => void;

  constructor(
    onComplete: (token: string, ok: boolean, hasValue: boolean, payload: string) => void,
  ) {
    this.onComplete = onComplete;
  }

  complete(token: string, ok: boolean, hasValue: boolean, payload: string): void {
    this.onComplete(
      typeof token === "string" ? token : "",
      Boolean(ok),
      Boolean(hasValue),
      typeof payload === "string" ? payload : "",
    );
  }
}

function unwrapQuotedLiteral(raw: string): string {
  if (raw.length >= 2 && raw.startsWith('"') && raw.endsWith('"')) {
    return raw.slice(1, -1);
  }
  return raw;
}

function clampTimeoutMs(timeoutMs?: number | null): number {
  if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return DEFAULT_EVAL_TIMEOUT_MS;
  }
  return Math.min(Math.max(Math.round(timeoutMs), MIN_EVAL_TIMEOUT_MS), MAX_EVAL_TIMEOUT_MS);
}

/**
 * Event-driven async JavaScript evaluator backed by an ArkWeb JS proxy.
 *
 * Registers `__abilityAsyncEval` on controller attachment so async script
 * promises resolve immediately via a native callback without polling. Falls back
 * to a bounded backoff poll only when a page lacks the injected proxy (for
 * example, an unnavigated blank document).
 */
export class WebviewAsyncEvaluator {
  private readonly pending: Map<string, PendingAsyncEval> = new Map();
  private readonly proxy: AsyncEvalJsProxy;
  private proxyRegistered = false;
  private nextToken = 1;

  constructor() {
    this.proxy = new AsyncEvalJsProxy(
      (token: string, ok: boolean, hasValue: boolean, payload: string): void => {
        const entry = this.pending.get(token);
        if (!entry) {
          return;
        }
        entry.settle(
          ok
            ? new WebviewAsyncScriptResponse(true, hasValue ? payload : undefined, undefined, false)
            : new WebviewAsyncScriptResponse(false, undefined, payload, false),
        );
      },
    );
  }

  attach(controller: webview.WebviewController): void {
    if (this.proxyRegistered) {
      return;
    }
    controller.registerJavaScriptProxy(this.proxy, ASYNC_EVAL_PROXY_NAME, ["complete"]);
    this.proxyRegistered = true;
  }

  detach(controller: webview.WebviewController): void {
    this.cancelAll("async script cancelled");
    if (this.proxyRegistered) {
      this.proxyRegistered = false;
      try {
        controller.deleteJavaScriptRegister(ASYNC_EVAL_PROXY_NAME);
      } catch {}
    }
  }

  onNavigationStart(): void {
    this.cancelAll("async script state cleared during navigation");
  }

  private cancelAll(reason: string): void {
    const entries = Array.from(this.pending.values());
    this.pending.clear();
    for (const entry of entries) {
      entry.settle(new WebviewAsyncScriptResponse(false, undefined, reason, false));
    }
  }

  async evaluate(
    controller: webview.WebviewController,
    script: string,
    isActive: () => boolean,
    onCancel: (listener: () => void) => () => void,
    timeoutMs?: number | null,
  ): Promise<WebviewAsyncScriptResponse> {
    const token = `aeval_${this.nextToken++}`;
    const effectiveTimeout = clampTimeoutMs(timeoutMs);

    let settled = false;
    let timer: number | undefined;
    let unsubscribeCancel: () => void = (): void => {};
    let resolvePromise: (response: WebviewAsyncScriptResponse) => void = (): void => {};

    const resultPromise = new Promise<WebviewAsyncScriptResponse>((resolve) => {
      resolvePromise = resolve;
    });

    const settle = (response: WebviewAsyncScriptResponse): void => {
      if (settled) {
        return;
      }
      settled = true;
      this.pending.delete(token);
      if (timer !== undefined) {
        clearTimeout(timer);
        timer = undefined;
      }
      unsubscribeCancel();
      resolvePromise(response);
    };

    this.pending.set(token, { settle });
    timer = setTimeout((): void => {
      settle(new WebviewAsyncScriptResponse(false, undefined, "async script timed out", false));
    }, effectiveTimeout);
    unsubscribeCancel = onCancel((): void => {
      settle(new WebviewAsyncScriptResponse(false, undefined, "async script cancelled", false));
    });

    const starter =
      `(function(){` +
      `var p=globalThis.${ASYNC_EVAL_PROXY_NAME};` +
      `var hasP=!!(p&&typeof p.complete==="function");` +
      `var s=hasP?null:(globalThis.__abilityEval||(globalThis.__abilityEval=Object.create(null)));` +
      `if(s){s["${token}"]={d:false,o:false,h:false,v:""};}` +
      `Promise.resolve().then(async function(){\n${script}\n}).then(` +
      `function(v){var h=v!==undefined;var r=h?String(v):"";` +
      `if(hasP){p.complete("${token}",true,h,r);}else if(s){s["${token}"]={d:true,o:true,h:h,v:r};}},` +
      `function(e){var r=e&&e.stack?String(e.stack):String(e);` +
      `if(hasP){p.complete("${token}",false,false,r);}else if(s){s["${token}"]={d:true,o:false,h:false,v:r};}});` +
      `return hasP?"started":"fallback";})();`;

    let mode = "";
    let startError = "";
    let rawStarted = "";
    try {
      rawStarted = await controller.runJavaScript(starter);
      mode = unwrapQuotedLiteral(rawStarted);
    } catch (error) {
      startError = String(error);
    }

    if (mode !== "started" && mode !== "fallback") {
      let sanityOk = false;
      let probeRaw = "";
      try {
        probeRaw = await controller.runJavaScript('"ok"');
        sanityOk = unwrapQuotedLiteral(probeRaw) === "ok";
      } catch {}
      if (sanityOk) {
        settle(
          new WebviewAsyncScriptResponse(
            false,
            undefined,
            `SyntaxError: ${startError || "failed to compile async script"}`,
            true,
          ),
        );
        return await resultPromise;
      }
      settle(new WebviewAsyncScriptResponse(false, undefined, "start failed", false));
      throw new Error(
        `Unable to start async WebView script: ${startError || `rawStarted=${rawStarted} probe=${probeRaw}`}`,
      );
    }

    if (mode === "fallback") {
      void this.pollFallback(controller, token, isActive, (): boolean => settled, settle);
    }

    return await resultPromise;
  }

  private async pollFallback(
    controller: webview.WebviewController,
    token: string,
    isActive: () => boolean,
    isSettled: () => boolean,
    settle: (response: WebviewAsyncScriptResponse) => void,
  ): Promise<void> {
    // Fallback uses encodeURIComponent so runJavaScript returns pure ASCII without escape decoding.
    const pollScript =
      `(function(){var s=globalThis.__abilityEval;if(!s)return "m";var e=s["${token}"];` +
      `if(!e)return "m";if(!e.d)return "p";delete s["${token}"];` +
      `var tag=e.o?(e.h?"1":"2"):"0";return tag+encodeURIComponent(e.v);})();`;
    let delayMs = 15;
    while (!isSettled() && isActive()) {
      try {
        const pollRaw = await controller.runJavaScript(pollScript);
        if (isSettled()) {
          return;
        }
        const status = unwrapQuotedLiteral(pollRaw);
        if (status === "m") {
          settle(
            new WebviewAsyncScriptResponse(
              false,
              undefined,
              "async script state cleared during navigation",
              false,
            ),
          );
          return;
        }
        if (status === "2") {
          settle(new WebviewAsyncScriptResponse(true, undefined, undefined, false));
          return;
        }
        if (status.startsWith("1")) {
          settle(
            new WebviewAsyncScriptResponse(
              true,
              decodeURIComponent(status.substring(1)),
              undefined,
              false,
            ),
          );
          return;
        }
        if (status.startsWith("0")) {
          settle(
            new WebviewAsyncScriptResponse(
              false,
              undefined,
              decodeURIComponent(status.substring(1)),
              false,
            ),
          );
          return;
        }
      } catch {
        // Ignore transient poll errors while waiting for cancellation or timeout.
      }
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), delayMs);
      });
      delayMs = Math.min(delayMs * 2, 100);
    }
    try {
      await controller.runJavaScript(`delete (globalThis.__abilityEval||{})["${token}"];`);
    } catch {}
  }
}
