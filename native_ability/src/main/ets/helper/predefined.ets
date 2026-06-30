import web_webview from '@ohos.web.webview';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { WindowManager } from '../window/WindowManager';

export class ClipboardExecutor {
  private controller: web_webview.WebviewController | null = null;

  setController(controller: web_webview.WebviewController): void {
    this.controller = controller;
  }

  async copy(): Promise<void> {
    await this.controller?.runJavaScript('document.execCommand("copy")');
  }

  async cut(): Promise<void> {
    await this.controller?.runJavaScript('document.execCommand("cut")');
  }

  async paste(): Promise<void> {
    await this.controller?.runJavaScript('document.execCommand("paste")');
  }

  async selectAll(): Promise<void> {
    await this.controller?.runJavaScript('document.execCommand("selectAll")');
  }

  async undo(): Promise<void> {
    await this.controller?.runJavaScript('document.execCommand("undo")');
  }

  async redo(): Promise<void> {
    await this.controller?.runJavaScript('document.execCommand("redo")');
  }
}

export interface WindowOps {
  minimize(): Promise<void>;
  maximize(): Promise<void>;
  recover(): Promise<void>;
  destroyWindow(): Promise<void>;
  setFullScreen(fullScreen: boolean): Promise<void>;
  hide(): Promise<void>;
}

export class WindowOpsExecutor implements WindowOps {
  private win: window.Window | null = null;
  private windowId: number = 0;

  setWindow(win: window.Window, windowId: number = 0): void {
    this.win = win;
    this.windowId = windowId;
  }

  async minimize(): Promise<void> {
    if (!this.win) throw new Error('Window not set');
    await WindowManager.getInstance().minimizeWindow(this.windowId);
  }

  async maximize(): Promise<void> {
    if (!this.win) throw new Error('Window not set');
    await this.win.maximize();
  }

  async recover(): Promise<void> {
    if (!this.win) throw new Error('Window not set');
    await this.win.recover();
  }

  async destroyWindow(): Promise<void> {
    if (!this.win) throw new Error('Window not set');
    await WindowManager.getInstance().destroyWindow(this.windowId);
  }

  async setFullScreen(fullScreen: boolean): Promise<void> {
    if (!this.win) throw new Error('Window not set');
    if (fullScreen) {
      await this.win.maximize(window.MaximizePresentation.ENTER_IMMERSIVE);
    } else {
      await this.win.recover();
    }
  }

  async hide(): Promise<void> {
    await this.minimize();
  }
}

export class AppExecutor {
  private context: common.UIAbilityContext | null = null;

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  async quit(code: number = 0): Promise<void> {
    if (!this.context) throw new Error('Context not set');
    await this.context.terminateSelf();
  }
}