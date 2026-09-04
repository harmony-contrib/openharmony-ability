import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { DOMAIN } from '../helper/constants';

// Phase 3 (design.md D5): typed wrappers replacing ESObject, eliminating
// arkts-limited-esobj WARN. These carry windowId through the NAPI boundary.
// Lives here (not WindowManager) so the throttle owns its payload types;
// WindowManager re-exports both for its existing importers.
export interface WindowSizeEventWrap {
  windowId: number;
  width: number;
  height: number;
}
export interface WindowRectEventWrap {
  windowId: number;
  reason: window.RectChangeReason;
  rect: window.Rect;
}

/**
 * Phase 3 (design.md D2/D4/D6): per-window leading+trailing throttle for
 * rect/size events. Extracted from WindowManager (issue #87 major-5) — this
 * class owns ONLY the throttle state machine; window lifetime (the `destroying`
 * flag) is injected as a callback so the class stays decoupled from the window
 * registry.
 *
 * - Leading: first event within a 16ms window fires immediately (hilog edge=leading).
 * - Trailing: subsequent events within the window are stored as pending; when the timer
 *   fires, only the last pending payload is dispatched (hilog edge=trailing).
 * - destroying guard: if the injected isDestroying(windowId) returns true (set by
 *   destroyWindow/closeWindow before win.destroyWindow()), events are discarded.
 *   Main window (id=0) is not in the windows Map; undefined→falsy→unaffected.
 *
 * Callers MUST create the payload with field-copied values (not system object refs),
 * per design.md D5 (pending payload deep-copy). dispatch() itself does not re-copy —
 * it stores the caller-constructed wrapped object reference, which is safe because
 * the caller already deep-copied rect fields.
 *
 * Q1 (design.md Open Questions): stale listeners after onWindowStageDestroy may still
 * fire — the try/catch around dispatch swallows errors. If hilog shows stale triggers,
 * add win.off() in unregisterUIAbilityStage.
 *
 * Q2 (design.md Open Questions): BridgeHost and NativeAbility register on possibly
 * different window instances (main window vs component window) — [THROTTLE-IN] hilog
 * shows whether the two sources interleave for windowId=0.
 */
export class RectThrottle {
  private static readonly THROTTLE_MS: number = 16;
  // rect throttle state
  private rectTimers: Map<number, number> = new Map();
  private rectPending: Map<number, WindowRectEventWrap> = new Map();
  private rectLeading: Map<number, boolean> = new Map();
  // size throttle state
  private sizeTimers: Map<number, number> = new Map();
  private sizePending: Map<number, WindowSizeEventWrap> = new Map();
  private sizeLeading: Map<number, boolean> = new Map();

  // Injected window-lifetime probe: true = window is being torn down, discard events.
  private readonly isDestroying: (windowId: number) => boolean;

  constructor(isDestroying: (windowId: number) => boolean) {
    this.isDestroying = isDestroying;
  }

  dispatch(
    windowId: number,
    payload: object,
    dispatchFn: (w: object) => void,
    kind: string,
  ): void {
    hilog.debug(DOMAIN, 'WindowManager', `[THROTTLE-IN] wid=${windowId} kind=${kind}`);
    // Discard events for windows being destroyed (main window id=0 not in Map → unaffected)
    if (this.isDestroying(windowId)) {
      return;
    }

    const timersMap = kind === 'rect' ? this.rectTimers : this.sizeTimers;
    const pendingMap = kind === 'rect' ? this.rectPending : this.sizePending;
    const leadingMap = kind === 'rect' ? this.rectLeading : this.sizeLeading;

    // Leading: first event in the window fires immediately
    if (!leadingMap.get(windowId)) {
      leadingMap.set(windowId, true);
      hilog.debug(DOMAIN, 'WindowManager', `[THROTTLE-OUT] wid=${windowId} kind=${kind} edge=leading`);
      try {
        dispatchFn(payload);
      } catch (e) {
        hilog.warn(DOMAIN, 'WindowManager', `[THROTTLE] leading dispatch failed wid=${windowId} kind=${kind}: ${String(e)}`);
      }
      // Set timer to end the leading window and flush trailing
      const timer = setTimeout(() => {
        try {
          // Re-check destroying in case the window was destroyed during the timer
          if (this.isDestroying(windowId)) {
            timersMap.delete(windowId);
            pendingMap.delete(windowId);
            leadingMap.delete(windowId);
            return;
          }
          const pending = pendingMap.get(windowId);
          if (pending !== undefined) {
            hilog.debug(DOMAIN, 'WindowManager', `[THROTTLE-OUT] wid=${windowId} kind=${kind} edge=trailing`);
            dispatchFn(pending);
          }
        } catch (e) {
          hilog.warn(DOMAIN, 'WindowManager', `[THROTTLE] trailing dispatch failed wid=${windowId} kind=${kind}: ${String(e)}`);
        } finally {
          timersMap.delete(windowId);
          pendingMap.delete(windowId);
          leadingMap.delete(windowId);
        }
      }, RectThrottle.THROTTLE_MS);
      timersMap.set(windowId, timer);
    } else {
      // Trailing: store pending (caller already deep-copied fields into the wrapped object)
      if (kind === 'rect') {
        this.rectPending.set(windowId, payload as WindowRectEventWrap);
      } else {
        this.sizePending.set(windowId, payload as WindowSizeEventWrap);
      }
    }
  }

  // Clear all throttle state (timers + pending + leading) for a window.
  // clearTimeout is the "already removed" guard (ArkTS single-threaded event loop
  // guarantees timer callback cannot interleave with a synchronous clear).
  clearWindow(windowId: number): void {
    const rectTimer = this.rectTimers.get(windowId);
    if (rectTimer !== undefined) { clearTimeout(rectTimer); }
    const sizeTimer = this.sizeTimers.get(windowId);
    if (sizeTimer !== undefined) { clearTimeout(sizeTimer); }
    this.rectTimers.delete(windowId);
    this.rectPending.delete(windowId);
    this.rectLeading.delete(windowId);
    this.sizeTimers.delete(windowId);
    this.sizePending.delete(windowId);
    this.sizeLeading.delete(windowId);
  }
}
