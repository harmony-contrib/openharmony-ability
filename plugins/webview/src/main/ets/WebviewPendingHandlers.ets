import webview from "@ohos.web.webview";
import { BridgeTypedValue, expectBridgeRequestType } from "@ohos-rs/ability";

export const RESOLVE_DOWNLOAD_REQUEST_TYPE = "ohos.webview.ResolveDownloadRequest";
export const RESOLVE_PERMISSION_REQUEST_TYPE = "ohos.webview.ResolvePermissionRequest";
export const RESOLVE_HTTP_AUTH_REQUEST_TYPE = "ohos.webview.ResolveHttpAuthRequest";
export const RESOLVE_SSL_ERROR_REQUEST_TYPE = "ohos.webview.ResolveSslErrorRequest";

export interface WebviewResolveDownloadPayload {
  id: string;
  downloadId: string;
  allow: boolean;
  path?: string | null;
}

export interface WebviewResolvePermissionPayload {
  id: string;
  requestId: string;
  allow: boolean;
  resources: string[];
}

export interface WebviewResolveHttpAuthPayload {
  id: string;
  requestId: string;
  action: string;
  username?: string | null;
  password?: string | null;
}

export interface WebviewResolveSslErrorPayload {
  id: string;
  requestId: string;
  allow: boolean;
}

export function parseResolveDownloadPayload(
  payload: BridgeTypedValue,
): WebviewResolveDownloadPayload {
  const request = expectBridgeRequestType(
    payload,
    "ohos.webview",
    "resolve-download",
    RESOLVE_DOWNLOAD_REQUEST_TYPE,
  ) as WebviewResolveDownloadPayload;
  if (!request?.id?.trim() || !request?.downloadId?.trim() || typeof request.allow !== "boolean") {
    throw new Error("WebView resolve-download requires id, downloadId, and allow");
  }
  return request;
}

export function parseResolvePermissionPayload(
  payload: BridgeTypedValue,
): WebviewResolvePermissionPayload {
  const request = expectBridgeRequestType(
    payload,
    "ohos.webview",
    "resolve-permission-request",
    RESOLVE_PERMISSION_REQUEST_TYPE,
  ) as WebviewResolvePermissionPayload;
  if (
    !request?.id?.trim() ||
    !request?.requestId?.trim() ||
    typeof request.allow !== "boolean" ||
    !Array.isArray(request.resources)
  ) {
    throw new Error(
      "WebView resolve-permission-request requires id, requestId, allow, and resources",
    );
  }
  return request;
}

export function parseResolveHttpAuthPayload(
  payload: BridgeTypedValue,
): WebviewResolveHttpAuthPayload {
  const request = expectBridgeRequestType(
    payload,
    "ohos.webview",
    "resolve-http-auth",
    RESOLVE_HTTP_AUTH_REQUEST_TYPE,
  ) as WebviewResolveHttpAuthPayload;
  if (!request?.id?.trim() || !request?.requestId?.trim() || typeof request.action !== "string") {
    throw new Error("WebView resolve-http-auth requires id, requestId, and action");
  }
  return request;
}

export function parseResolveSslErrorPayload(
  payload: BridgeTypedValue,
): WebviewResolveSslErrorPayload {
  const request = expectBridgeRequestType(
    payload,
    "ohos.webview",
    "resolve-ssl-error",
    RESOLVE_SSL_ERROR_REQUEST_TYPE,
  ) as WebviewResolveSslErrorPayload;
  if (!request?.id?.trim() || !request?.requestId?.trim() || typeof request.allow !== "boolean") {
    throw new Error("WebView resolve-ssl-error requires id, requestId, and allow");
  }
  return request;
}

export class WebviewPendingHandlers {
  private readonly downloads: Map<string, webview.WebDownloadItem> = new Map();
  private readonly downloadKeysByItem: WeakMap<webview.WebDownloadItem, string> = new WeakMap();
  private readonly permissions: Map<string, PermissionRequest> = new Map();
  private readonly httpAuth: Map<string, HttpAuthHandler> = new Map();
  private readonly sslErrors: Map<string, SslErrorHandler> = new Map();

  trackDownload(downloadId: string, item: webview.WebDownloadItem): void {
    this.downloads.set(downloadId, item);
    this.downloadKeysByItem.set(item, downloadId);
  }

  untrackDownload(item: webview.WebDownloadItem): void {
    const trackedKey = this.downloadKeysByItem.get(item);
    if (trackedKey !== undefined) {
      this.downloads.delete(trackedKey);
      this.downloadKeysByItem.delete(item);
    }
    try {
      const guid = item.getGuid();
      if (guid) {
        this.downloads.delete(guid);
      }
    } catch {}
  }

  resolveDownload(request: WebviewResolveDownloadPayload): boolean {
    const item = this.downloads.get(request.downloadId);
    if (!item) {
      return false;
    }
    this.downloads.delete(request.downloadId);
    this.downloadKeysByItem.delete(item);
    try {
      if (request.allow && request.path && request.path.trim().length > 0) {
        item.start(request.path);
      } else {
        item.cancel();
      }
      return true;
    } catch (error) {
      console.error("WebView resolve-download failed: " + String(error));
      return false;
    }
  }

  trackPermission(requestId: string, request: PermissionRequest): void {
    this.permissions.set(requestId, request);
  }

  deletePermission(requestId: string): void {
    this.permissions.delete(requestId);
  }

  resolvePermission(request: WebviewResolvePermissionPayload): boolean {
    const perm = this.permissions.get(request.requestId);
    if (!perm) {
      return false;
    }
    this.permissions.delete(request.requestId);
    try {
      if (request.allow) {
        const resources =
          request.resources.length > 0 ? request.resources : perm.getAccessibleResource();
        perm.grant(resources);
      } else {
        perm.deny();
      }
      return true;
    } catch (error) {
      console.error("WebView resolve-permission-request failed: " + String(error));
      return false;
    }
  }

  trackHttpAuth(requestId: string, handler: HttpAuthHandler): void {
    this.httpAuth.set(requestId, handler);
  }

  deleteHttpAuth(requestId: string): void {
    this.httpAuth.delete(requestId);
  }

  resolveHttpAuth(request: WebviewResolveHttpAuthPayload): boolean {
    const handler = this.httpAuth.get(request.requestId);
    if (!handler) {
      return false;
    }
    this.httpAuth.delete(request.requestId);
    try {
      if (request.action === "confirm") {
        handler.confirm(request.username ?? "", request.password ?? "");
      } else {
        handler.cancel();
      }
      return true;
    } catch (error) {
      console.error("WebView resolve-http-auth failed: " + String(error));
      return false;
    }
  }

  trackSslError(requestId: string, handler: SslErrorHandler): void {
    this.sslErrors.set(requestId, handler);
  }

  deleteSslError(requestId: string): void {
    this.sslErrors.delete(requestId);
  }

  resolveSslError(request: WebviewResolveSslErrorPayload): boolean {
    const handler = this.sslErrors.get(request.requestId);
    if (!handler) {
      return false;
    }
    this.sslErrors.delete(request.requestId);
    try {
      if (request.allow) {
        handler.handleConfirm();
      } else {
        handler.handleCancel();
      }
      return true;
    } catch (error) {
      console.error("WebView resolve-ssl-error failed: " + String(error));
      return false;
    }
  }

  /** Cancels navigation-scoped handlers left unresolved when a new page starts loading. */
  clearNavigationPending(): void {
    for (const req of this.permissions.values()) {
      try {
        req.deny();
      } catch {}
    }
    this.permissions.clear();
    for (const handler of this.httpAuth.values()) {
      try {
        handler.cancel();
      } catch {}
    }
    this.httpAuth.clear();
    for (const handler of this.sslErrors.values()) {
      try {
        handler.handleCancel();
      } catch {}
    }
    this.sslErrors.clear();
  }

  /** Cancels every pending handler, including deferred downloads, on WebView teardown. */
  clearAll(): void {
    for (const item of this.downloads.values()) {
      try {
        item.cancel();
      } catch {}
    }
    this.downloads.clear();
    this.clearNavigationPending();
  }
}
