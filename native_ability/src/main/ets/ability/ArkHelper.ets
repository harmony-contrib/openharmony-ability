import common from "@ohos.app.ability.common";
import window from "@ohos.window";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { statusBarManager } from "@kit.DeskTopExtensionKit";
import { emitter, BusinessError } from "@kit.BasicServicesKit";
import { image } from "@kit.ImageKit";
import {
  ArkHelper,
  StatusBarIconRgba,
  WebViewInitData as NativeWebViewInitData,
  WindowAvoidAreaInfo,
  WindowConfig,
} from "../ability/type";
import { exit, restart, check as updaterCheckFn, showUpdateDialog as updaterShowDialogFn, downloadAndInstall as updaterDownloadAndInstallFn, objectAssign, writeImageToClipboard, openAutostartSettings, getAutostartStatus } from "../helper";
import { requestPermission } from "../helper/permission";
import { getPredefinedActionExecutor } from "../helper/menu";
import { PredefinedType } from "../helper/menu_types";
import {
  EmbeddedWebviewManager,
  RustWebviewNodeController,
  WebviewStyle,
  WebviewInitData,
} from "../webview/DefaultWebview";
import { WindowManager } from "../window/WindowManager";
import { JsHelper, ProxyJsHelper } from "../webview/Utils";
import {
  getAbilityContext,
  createPixelMapFromRgba,
  fillMenuItemAbilityName,
  processMenuItemIcons,
  helperRef,
  reRegisterStatusBarClickHandlers,
} from "../helper/StatusBarUtils";
import { ConfigurationConstant } from '@kit.AbilityKit';
import { primaryWebviewControllerCallback, clearPrimaryWebviewControllerCallback } from "../components/DefaultXComponent";
import { DOMAIN, NATIVE_MODULE_STORAGE_KEY } from '../helper/constants';

/**
 * Global ArkHelper factory function.
 *
 * Design principles:
 * - Does not depend on any component instance's `this` pointer
 * - All window-related resources are managed centrally via WindowManager
 * - UIContext is obtained from WindowManager by windowId
 */
export function createArkHelper(): ArkHelper {
  // Per-window EmbeddedWebviewManager instances, keyed by windowId
  const embeddedManagers: Map<number, EmbeddedWebviewManager> = new Map();

  const getEmbeddedManager = (windowId: number): EmbeddedWebviewManager => {
    if (!embeddedManagers.has(windowId)) {
      const wm = WindowManager.getInstance();
      const uiCtx = wm.getUIContext(windowId);
      if (!uiCtx) {
        throw new Error(`UIContext not found for window ${windowId}`);
      }
      embeddedManagers.set(windowId, new EmbeddedWebviewManager(uiCtx));
    }
    return embeddedManagers.get(windowId)!;
  };

  const getUIAbilityContext = (): common.UIAbilityContext | null => {
    try {
      const wm = WindowManager.getInstance();
      // Prefer main window (windowId=0) for context
      const uiCtx = wm.getUIContext(0);
      if (uiCtx) {
        return uiCtx.getHostContext() as common.UIAbilityContext;
      }
    } catch (e) {
      hilog.error(DOMAIN, 'ArkHelper', 'Failed to get UIAbilityContext: %{public}s', JSON.stringify(e));
    }
    return null;
  };

  return {
    exit,
    restart,

    updaterCheck: async (): Promise<Object> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'updaterCheck: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        return await updaterCheckFn(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'updaterCheck failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    updaterShowDialog: async (): Promise<number> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'updaterShowDialog: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        return await updaterShowDialogFn(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'updaterShowDialog failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    updaterDownloadAndInstall: async (): Promise<void> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'updaterDownloadAndInstall: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        await updaterDownloadAndInstallFn(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'updaterDownloadAndInstall failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    requestPermission: async (permission: string | string[]): Promise<number | number[]> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'Failed to get UIAbilityContext for permission request');
          return -1;
        }
        return await requestPermission(context, permission);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'Permission request failed: %{public}s', JSON.stringify(err));
        return -1;
      }
    },

    getWindowAvoidArea: (type: number, windowId: number): WindowAvoidAreaInfo | undefined => {
      try {
        let win: window.Window | null = null;

        if (windowId === 0) {
          // Main window
          hilog.info(DOMAIN, 'ArkHelper', 'Getting avoid area for MAIN window');
          const context = getUIAbilityContext();
          if (context) {
            win = context.windowStage.getMainWindowSync();
          }
        } else {
          // Sub-window
          hilog.info(DOMAIN, 'ArkHelper', 'Getting avoid area for SUB window: %{public}d', windowId);
          try {
            const wm = WindowManager.getInstance();
            win = wm.getWindow(windowId) || null;
          } catch (e) {
            hilog.error(DOMAIN, 'ArkHelper', 'Failed to get WindowManager instance: %{public}s', JSON.stringify(e));
          }
        }

        if (!win) {
          hilog.error(DOMAIN, 'ArkHelper', 'Window not found for windowId: %{public}d', windowId);
          return undefined;
        }

        const avoidType = type as window.AvoidAreaType;
        return {
          type: avoidType,
          area: win.getWindowAvoidArea(avoidType),
        } as WindowAvoidAreaInfo;
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'getWindowAvoidArea failed: %{public}s', JSON.stringify(err));
        return undefined;
      }
    },

    createWebview: (data: NativeWebViewInitData) => {
      try {
        const windowId = data.windowId ?? 0;
        hilog.info(DOMAIN, 'ArkHelper', 'createWebview called with windowId: %{public}d, url: %{public}s', windowId, data.url || 'null');
        
        // 1. Look up Controller strictly by windowId
        let targetController: RustWebviewNodeController | null = null;
        try {
          const wm = WindowManager.getInstance();
          targetController = wm.getController(windowId);
        } catch (e) {
          hilog.error(DOMAIN, 'ArkHelper', 'Failed to get WindowManager: %{public}s', JSON.stringify(e));
        }

        // 2. Prepare Init data
        const rawInitScripts: string[] = data?.initializationScripts || [];

        const initScripts: ScriptItem[] = rawInitScripts.map((i) => {
          return {
            script: i,
            scriptRules: ["*"],
          } as ScriptItem;
        });
        const init: WebviewInitData = {
          webTag: data?.id,
          url: data?.url,
          windowId: windowId,
          html: data?.html,
          headers: data?.headers,
          style: (data.style || {}) as WebviewStyle,
          javascriptEnable: data?.javascriptEnable ?? true,
          userAgent: data?.userAgent,
          devtools: data?.devtools,
          autoplay: data?.autoplay,
          initializationScripts: initScripts,
          onDragAndDrop: data?.onDragAndDrop,
          onDownloadStart: data?.onDownloadStart,
          onDownloadEnd: data?.onDownloadEnd,
          onNavigationRequest: data?.onNavigationRequest,
          onTitleChange: data?.onTitleChange,
          onPageBegin: data?.onPageBegin,
          onPageEnd: data?.onPageEnd,
          onWindowNew: data?.onWindowNew,
          onCloseWindow: () => {
            try {
              // Notify Rust event loop to process the close through proper lifecycle:
              // CloseRequested → Destroyed → WindowsStore cleanup.
              // notifyWindowClose() is synchronous — pushes window ID to Rust queue.
              // destroyWindow() is async (Promise) — actual destruction happens later.
              // Rust's drain runs at the top of the next event loop iteration (synchronous),
              // so it reads stored Rust values before destroyWindow completes.
              const nativeModule: ESObject = AppStorage.get<ESObject>(NATIVE_MODULE_STORAGE_KEY);
              if (nativeModule && typeof nativeModule.notifyWindowClose === 'function') {
                nativeModule.notifyWindowClose(windowId);
                hilog.info(DOMAIN, 'ArkHelper', 'Window %{public}d close notified via NAPI', windowId);
              } else {
                hilog.warn(DOMAIN, 'ArkHelper', 'NAPI notifyWindowClose not available for window %{public}d', windowId);
              }

              // Destroy OHOS native window and clean up WindowManager.
              // removeWindow BEFORE destroyWindow so that aboutToDisappear
              // (which fires during async destruction) sees the window as
              // already handled and skips the system-close notification.
              const wm = WindowManager.getInstance();
              const win = wm.getWindow(windowId);
              if (win) {
                wm.removeWindow(windowId);
                win.destroyWindow().then(() => {
                  hilog.info(DOMAIN, 'ArkHelper', 'Window %{public}d destroyed and cleaned up', windowId);
                }).catch((e: Error) => {
                  hilog.error(DOMAIN, 'ArkHelper', 'Failed to destroy window %{public}d: %{public}s', windowId, JSON.stringify(e));
                });
              }
            } catch (e) {
              hilog.error(DOMAIN, 'ArkHelper', 'onCloseWindow failed: %{public}s', JSON.stringify(e));
            }
          },
        } as WebviewInitData;

        hilog.info(DOMAIN, 'ArkHelper',
          'createWebview event handlers: nav=%{public}s, title=%{public}s, dlStart=%{public}s, dlEnd=%{public}s, pgBegin=%{public}s, pgEnd=%{public}s',
          typeof init.onNavigationRequest === 'function' ? 'YES' : 'NO',
          typeof init.onTitleChange === 'function' ? 'YES' : 'NO',
          typeof init.onDownloadStart === 'function' ? 'YES' : 'NO',
          typeof init.onDownloadEnd === 'function' ? 'YES' : 'NO',
          typeof init.onPageBegin === 'function' ? 'YES' : 'NO',
          typeof init.onPageEnd === 'function' ? 'YES' : 'NO',
        );

        init.style = init.style || {};
        // OHOS: Set WebView transparent only when requested.
        // The Web component only respects .backgroundColor() at creation, not at runtime.
        // Window shell transparency is controlled separately by setWindowBackgroundColor().
        if (data?.transparent) {
          init.transparent = true;
          init.style.backgroundColor = Color.Transparent;
        }

        // 3. If Controller not ready, create proxy and enqueue
        if (!targetController) {
          hilog.warn(DOMAIN, 'ArkHelper', 'Controller not ready for window %{public}d. Creating proxy.', windowId);
          try {
            const wm = WindowManager.getInstance();
            wm.queueWebviewInit(windowId, init);
            
            // Create lightweight proxy object to return to Rust
            const proxy = new ProxyJsHelper();
            wm.registerPendingJsHelperProxy(windowId, proxy);
            return proxy;
          } catch (e) {
            hilog.error(DOMAIN, 'ArkHelper', 'Failed to queue init or create proxy: %{public}s', JSON.stringify(e));
            // Fallback: return ProxyJsHelper under extreme errors; operations are cached, not lost. TODO: handle errors on Rust side
            const fallbackProxy = new ProxyJsHelper();
            try {
              const wmFallback = WindowManager.getInstance();
              wmFallback.queueWebviewInit(windowId, init);
              wmFallback.registerPendingJsHelperProxy(windowId, fallbackProxy);
            } catch (e2) {
              hilog.error(DOMAIN, 'ArkHelper', 'Failed to queue fallback init: %{public}s', JSON.stringify(e2));
            }
            return fallbackProxy;
          }
        }

        // 4. Normal creation path
        const ret = targetController.addWebview(init);
        if (primaryWebviewControllerCallback && init.controller) {
          primaryWebviewControllerCallback(init.controller);
          clearPrimaryWebviewControllerCallback();
        }
        const applyStyle = (style: WebviewStyle) => {
          objectAssign(init.style as Record<string, ESObject>, style);
          targetController!.updateWebviewStyle(ret.webTag, init.style as WebviewStyle);
        };

        ret.controller.setBackgroundColor = (color: number) => {
          applyStyle({ backgroundColor: color });
        };

        ret.controller.setVisible = (visible: boolean) => {
          applyStyle({ visible });
        };

        ret.controller.setBounds = (x: number, y: number, width: number, height: number) => {
          applyStyle({ x, y, width, height });
        };

        ret.controller.dispose = () => {
          targetController!.removeWebview(ret.webTag);
        };

        return ret.controller;
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'createWebview failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    createEmbeddedWebview: (data: NativeWebViewInitData) => {
      try {
        const windowId = data.windowId ?? 0;
        const manager = getEmbeddedManager(windowId);

        const rawInitScripts: string[] = data?.initializationScripts || [];

        const initScripts: ScriptItem[] = rawInitScripts.map((i) => {
          return {
            script: i,
            scriptRules: ["*"],
          } as ScriptItem;
        });
        const init: WebviewInitData = {
          webTag: data?.id,
          url: data?.url,
          windowId: windowId,
          html: data?.html,
          headers: data?.headers,
          style: (data.style || {}) as WebviewStyle,
          javascriptEnable: data?.javascriptEnable ?? true,
          userAgent: data?.userAgent,
          devtools: data?.devtools,
          autoplay: data?.autoplay,
          initializationScripts: initScripts,
          onDragAndDrop: data?.onDragAndDrop,
          onDownloadStart: data?.onDownloadStart,
          onDownloadEnd: data?.onDownloadEnd,
          onNavigationRequest: data?.onNavigationRequest,
          onTitleChange: data?.onTitleChange,
          onPageBegin: data?.onPageBegin,
          onPageEnd: data?.onPageEnd,
          onWindowNew: data?.onWindowNew,
        } as WebviewInitData;

        hilog.info(DOMAIN, 'ArkHelper',
          'createWebview event handlers: nav=%{public}s, title=%{public}s, dlStart=%{public}s, dlEnd=%{public}s, pgBegin=%{public}s, pgEnd=%{public}s',
          typeof init.onNavigationRequest === 'function' ? 'YES' : 'NO',
          typeof init.onTitleChange === 'function' ? 'YES' : 'NO',
          typeof init.onDownloadStart === 'function' ? 'YES' : 'NO',
          typeof init.onDownloadEnd === 'function' ? 'YES' : 'NO',
          typeof init.onPageBegin === 'function' ? 'YES' : 'NO',
          typeof init.onPageEnd === 'function' ? 'YES' : 'NO',
        );

        init.style = init.style || {};
        // OHOS: Set WebView transparent only when requested (same as createWebview).
        if (data?.transparent) {
          init.transparent = true;
          init.style.backgroundColor = Color.Transparent;
        }

        const ret = manager.createWebview(init);
        const applyStyle = (style: WebviewStyle) => {
          objectAssign(init.style as Record<string, ESObject>, style);
          manager.updateWebviewStyle(ret.webTag, init.style as WebviewStyle);
        };

        ret.controller.setBackgroundColor = (color: number) => {
          applyStyle({ backgroundColor: color });
        };

        ret.controller.setVisible = (visible: boolean) => {
          applyStyle({ visible });
        };

        ret.controller.setBounds = (x: number, y: number, width: number, height: number) => {
          applyStyle({ x, y, width, height });
        };

        ret.controller.dispose = () => {
          manager.removeWebview(ret.webTag);
        };

        return ret;
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'createEmbeddedWebview failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    createOSWindow: async (config: WindowConfig): Promise<number> => {
      try {
        hilog.info(DOMAIN, 'ArkHelper', 'Received config from Rust: %{public}s', JSON.stringify(config));
        hilog.info(DOMAIN, 'ArkHelper', 'Parsed -> name: %{public}s, windowId: %{public}d',
          config.name, config.windowId);

        const wm = WindowManager.getInstance();
        hilog.info(DOMAIN, 'ArkHelper', 'WindowManager instance acquired');

        return await wm.createSubWindow({
          name: config.name,
          windowId: config.windowId,
          width: config.width,
          height: config.height,
          x: config.x,
          y: config.y,
          decorations: config.decorations,
          transparent: config.transparent,
          backgroundColor: config.backgroundColor,
        });
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'Failed to create OS window: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    setWindowDecorations: (windowId: number, decorations: boolean): void => {
      try {
        const wm = WindowManager.getInstance();
        wm.setDecorations(windowId, decorations);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'setWindowDecorations failed: %{public}s', JSON.stringify(err));
      }
    },

    setWindowBackgroundColor: (windowId: number, color: number): void => {
      try {
        const wm = WindowManager.getInstance();
        wm.setWindowBackgroundColor(windowId, color);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'setWindowBackgroundColor failed: %{public}s', JSON.stringify(err));
      }
    },

    loadUrl: (id: number, url: string): void => {
      try {
        hilog.info(DOMAIN, 'ArkHelper', 'loadUrl called for window %{public}d: %{public}s', id, url);
        const wm = WindowManager.getInstance();
        wm.loadUrl(id, url);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'loadUrl failed for window %{public}d: %{public}s', id, JSON.stringify(err));
      }
    },

    addToStatusBarWithRgba: (iconsRgba: StatusBarIconRgba, iconSize: number, quickOperation: ESObject, statusBarGroupMenu?: ESObject[][], hoverTips?: string) => {
      hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] addToStatusBarWithRgba called: iconSize=${iconSize}, hasWhite=${!!(iconsRgba.white)}, whiteLen=${iconsRgba.white?.length ?? 0}, hasBlack=${!!(iconsRgba.black)}, blackLen=${iconsRgba.black?.length ?? 0}`);
      const context = getAbilityContext();
      if (!context) { hilog.error(DOMAIN, 'ArkHelper','[StatusBar] no context'); return; }
      // NOTE: Do NOT auto-fill abilityName when it's empty string.
      // Per OHOS docs: abilityName="" means "no QuickOperation panel, fire statusBarIconClick event instead".
      // Only fill when abilityName is explicitly undefined/null (not empty string).
      if (quickOperation.abilityName == null) {
        quickOperation.abilityName = context.abilityInfo.name;
      }
      const icons: ESObject = {};
      if (iconsRgba.white && iconsRgba.white.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.white, iconSize);
        if (pm) icons.white = pm;
        hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] white PixelMap: ${pm ? 'OK' : 'NULL'}`);
      }
      if (iconsRgba.black && iconsRgba.black.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.black, iconSize);
        if (pm) icons.black = pm;
        hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] black PixelMap: ${pm ? 'OK' : 'NULL'}`);
      }
      if (Object.keys(icons).length === 0) { hilog.error(DOMAIN, 'ArkHelper','[StatusBar] no valid icons, aborting'); return; }
      const opts: ESObject = {
        icons: icons,
        quickOperation: quickOperation,
        statusBarGroupMenu: statusBarGroupMenu ?? []
      };
      if (statusBarGroupMenu) {
        fillMenuItemAbilityName(statusBarGroupMenu, context.abilityInfo.name);
        processMenuItemIcons(statusBarGroupMenu);
      }
      if (hoverTips && hoverTips.length > 0 && hoverTips.length <= 128) {
        opts.hoverTips = hoverTips;
      }
      // Register click handlers AFTER addToStatusBar returns, because addToStatusBar
      // internally calls initScbServerMessageReceiver which creates a new receiver
      // and wipes any handlers registered before it.
      try {
        statusBarManager.addToStatusBar(context, opts);
        reRegisterStatusBarClickHandlers();
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] addToStatusBar failed: ${err.code} ${err.message}`);
      }
    },

    updateStatusBarIconWithRgba: (iconsRgba: StatusBarIconRgba, iconSize: number) => {
      const context = getAbilityContext();
      if (!context) return;
      const icons: ESObject = {};
      if (iconsRgba.white && iconsRgba.white.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.white, iconSize);
        if (pm) icons.white = pm;
      }
      if (iconsRgba.black && iconsRgba.black.length > 0) {
        const pm = createPixelMapFromRgba(iconsRgba.black, iconSize);
        if (pm) icons.black = pm;
      }
      if (Object.keys(icons).length === 0) return;
      try {
        statusBarManager.updateStatusBarIcon(context, icons);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] updateStatusBarIcon failed: ${err.code} ${err.message}`);
      }
    },

    registerIconClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => {
      hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] registerIconClickHandler: legacy call (using _onIconClick instead)`);
    },

    registerMenuClickHandler: (eventName: string, callback: Callback<emitter.EventData>) => {
      hilog.info(DOMAIN, 'ArkHelper',`[StatusBar] registerMenuClickHandler: legacy call (using _onMenuClick instead)`);
    },

    unregisterIconClickHandler: (eventName: string) => {
      statusBarManager.off(eventName as 'statusBarIconClick');
    },

    unregisterMenuClickHandler: (eventName: string) => {
      statusBarManager.off(eventName as 'rightMenuClick');
    },

    updateStatusBarMenu: (statusBarGroupMenu: ESObject[][]) => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        fillMenuItemAbilityName(statusBarGroupMenu, context.abilityInfo.name);
        processMenuItemIcons(statusBarGroupMenu);
        statusBarManager.updateStatusBarMenu(context, statusBarGroupMenu);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] updateStatusBarMenu failed: ${err.code} ${err.message}`);
      }
    },

    updateStatusBarHoverTips: (hoverTips: string) => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        statusBarManager.updateStatusBarHoverTips(context, hoverTips);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] updateStatusBarHoverTips failed: ${err.code} ${err.message}`);
      }
    },

    removeFromStatusBar: () => {
      const context = getAbilityContext();
      if (!context) return;
      try {
        statusBarManager.removeFromStatusBar(context);
      } catch (e) {
        const err = e as BusinessError;
        hilog.error(DOMAIN, 'ArkHelper',`[StatusBar] removeFromStatusBar failed: ${err.code} ${err.message}`);
      }
    },

    executePredefinedAction: (actionType: string) => {
      const executor = getPredefinedActionExecutor();
      if (!executor) {
        hilog.warn(DOMAIN, 'ArkHelper',
          'PredefinedActionExecutor not initialized, action: %{public}s', actionType);
        return;
      }

      // Window operations from tray menu must be deferred to avoid race condition
      // with system's onNewWant → GoForeground transition.
      // These operations are deferred until RESUMED/WINDOW_ACTIVE event fires.
      const WINDOW_OPERATIONS: PredefinedType[] = ['minimize', 'hide', 'close'];
      if (WINDOW_OPERATIONS.includes(actionType as PredefinedType)) {
        hilog.info(DOMAIN, 'ArkHelper',
          'Deferring window operation "%{public}s" to avoid race with system foreground transition',
          actionType);
        const wm = WindowManager.getInstance();
        wm.setPendingAction(() => {
          executor.execute(actionType as PredefinedType);
        });
      } else {
        // Non-window operations (quit, showAll, bringAllToFront, etc.) execute immediately
        executor.execute(actionType as PredefinedType);
      }
    },

    setColorMode: (mode: number) => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'setColorMode: UIAbilityContext not available');
          return;
        }
        let colorMode: ConfigurationConstant.ColorMode;
        switch (mode) {
          case 0:
            colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
            break;
          case 1:
            colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
            break;
          default:
            colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
            break;
        }
        // Defer setColorMode to next event loop to avoid deadlock:
        // setColorMode synchronously triggers onConfigurationUpdate callback,
        // which calls back into Rust. If we're already in a NAPI call from Rust,
        // this creates a deadlock on the main thread.
        setTimeout(() => {
          try {
            context!.getApplicationContext().setColorMode(colorMode);
            hilog.info(DOMAIN, 'ArkHelper', 'setColorMode: applied mode %{public}d', mode);
          } catch (err) {
            hilog.error(DOMAIN, 'ArkHelper', 'setColorMode deferred callback failed (ability may be destroyed): %{public}s', String(err));
          }
        }, 0);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'setColorMode failed: %{public}s', JSON.stringify(err));
      }
    },

    checkCanIUse: (syscap: string): boolean => {
      return canIUse(syscap);
    },

    writeImageToClipboard: async (rgbaData: Uint8Array, width: number, height: number): Promise<void> => {
      return await writeImageToClipboard(rgbaData, width, height);
    },

    autostartEnable: async (): Promise<void> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'autostartEnable: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        await openAutostartSettings(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'autostartEnable failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    autostartDisable: async (): Promise<void> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'autostartDisable: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        await openAutostartSettings(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'autostartDisable failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

    autostartIsEnabled: async (): Promise<boolean> => {
      try {
        const context = getUIAbilityContext();
        if (!context) {
          hilog.error(DOMAIN, 'ArkHelper', 'autostartIsEnabled: UIAbilityContext not available');
          throw new Error('UIAbilityContext not available');
        }
        return await getAutostartStatus(context);
      } catch (err) {
        hilog.error(DOMAIN, 'ArkHelper', 'autostartIsEnabled failed: %{public}s', JSON.stringify(err));
        throw err;
      }
    },

  };
}
