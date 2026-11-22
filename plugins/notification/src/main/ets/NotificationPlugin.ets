import deviceInfo from "@ohos.deviceInfo";
import { image } from "@kit.ImageKit";
import { url } from "@kit.ArkTS";
import wantAgent, { WantAgent } from "@ohos.app.ability.wantAgent";
import { notificationManager } from "@kit.NotificationKit";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeTypedValue,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

const SHOW_REQUEST_TYPE = "ohos.notification.ShowRequest";
const DISMISS_REQUEST_TYPE = "ohos.notification.DismissRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.notification.Acknowledgement";
const MAX_IMAGE_BYTES = 16 * 1024 * 1024;

export interface NotificationPluginOptions {
  /** URI scheme consumed by the application's onNewWant handler, without ':'. */
  scheme: string;
}

interface SetBadgeRequest {
  count: number;
}

interface NotificationAction {
  id: string;
  label: string;
}

interface ShowRequest {
  tag: string;
  title: string;
  body: string;
  actions: NotificationAction[];
  silent?: boolean | null;
  group?: string | null;
  senderName?: string | null;
  image?: number[] | null;
  avatar?: number[] | null;
  slot?: string | null;
}

interface NotificationResponseRequest {
  uri: string;
}

class NotificationResponse {
  matched: boolean = false;
  tag: string = "";
  action: string = "";
}

interface DismissRequest {
  tag: string;
}

class NotificationAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

// The URI is delivered to NativeAbility.onNewWant when the notification is tapped.
function responseUri(scheme: string, tag: string, actionId?: string): string {
  const query = `tag=${encodeURIComponent(tag)}`;
  return (
    `${scheme}://response?${query}` +
    (actionId === undefined ? "" : `&action=${encodeURIComponent(actionId)}`)
  );
}

function requestCode(uri: string): number {
  let hash = 2166136261;
  for (let index = 0; index < uri.length; index++) {
    hash = Math.imul(hash ^ uri.charCodeAt(index), 16777619);
  }
  return hash & 0x7fffffff;
}

function notificationLabel(tag: string): string {
  return `${requestCode(tag)}:${requestCode(tag + "#")}`;
}

export class NotificationPlugin extends AsyncPluginBase {
  readonly id = "ohos.notification";
  readonly requires: BridgeContextRequirement[] = ["ability"];
  private readonly responseScheme: string;

  constructor(options: NotificationPluginOptions) {
    super();
    const scheme = options?.scheme;
    if (typeof scheme !== "string" || !/^[A-Za-z][A-Za-z0-9+.-]*$/.test(scheme)) {
      throw new Error("NotificationPlugin options.scheme must be a URI scheme without ':'");
    }
    this.responseScheme = scheme.toLowerCase();
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Notification bridge session is no longer active");
    }
    if (action === "set-badge") {
      const request = expectBridgeRequestType(
        payload,
        this.id,
        action,
        "ohos.notification.SetBadgeRequest",
      ) as SetBadgeRequest;
      if (!Number.isInteger(request.count) || request.count < 0 || request.count > 2147483647) {
        throw new Error("Invalid badge count");
      }
      await notificationManager.setBadgeNumber(request.count);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new NotificationAcknowledgement(true) };
    }
    if (action === "parse-response") {
      const request = expectBridgeRequestType(
        payload,
        this.id,
        action,
        "ohos.notification.ResponseRequest",
      ) as NotificationResponseRequest;
      const result = new NotificationResponse();
      try {
        const parsed = new url.URL(request.uri);
        if (
          parsed.protocol === this.responseScheme + ":" &&
          parsed.hostname === "response" &&
          (parsed.pathname === "" || parsed.pathname === "/")
        ) {
          const tag = parsed.searchParams.get("tag");
          if (tag !== null && tag.length > 0) {
            result.matched = true;
            result.tag = tag;
            result.action = parsed.searchParams.get("action") ?? "";
          }
        }
      } catch (_) {
        /* Ordinary non-URL wants do not match. */
      }
      return { typeName: "ohos.notification.Response", value: result };
    }
    if (action === "dismiss-all") {
      expectBridgeRequestType(payload, this.id, action, "ohos.notification.EmptyRequest");
      await notificationManager.cancelAll();
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new NotificationAcknowledgement(true) };
    }
    if (action === "show") {
      const request = expectBridgeRequestType(
        payload,
        this.id,
        action,
        SHOW_REQUEST_TYPE,
      ) as ShowRequest;
      if (
        !request ||
        typeof request.tag !== "string" ||
        !request.tag.trim() ||
        typeof request.title !== "string" ||
        !request.title.trim() ||
        typeof request.body !== "string" ||
        !request.body.trim() ||
        !Array.isArray(request.actions)
      ) {
        throw new Error("Notification requires a tag, title, body and actions array");
      }
      if (request.actions.length > 3) {
        throw new Error("Notification supports at most 3 actions");
      }
      if (
        request.actions.some(
          (item: NotificationAction) =>
            !item ||
            typeof item.id !== "string" ||
            !item.id.trim() ||
            typeof item.label !== "string" ||
            !item.label.trim(),
        )
      ) {
        throw new Error("Notification actions require an id and label");
      }
      const silent = request.silent ?? false;
      const group = request.group ?? "";
      const senderName = request.senderName ?? "";
      const imageBytes = request.image ?? [];
      const avatarBytes = request.avatar ?? [];
      const slot = request.slot ?? "default";
      if (
        typeof silent !== "boolean" ||
        typeof group !== "string" ||
        typeof senderName !== "string" ||
        !Array.isArray(imageBytes) ||
        imageBytes.length > MAX_IMAGE_BYTES ||
        !Array.isArray(avatarBytes) ||
        avatarBytes.length > MAX_IMAGE_BYTES ||
        (slot !== "default" && slot !== "social")
      ) {
        throw new Error("Invalid notification presentation options");
      }
      if (silent && deviceInfo.sdkApiVersion < 23) {
        throw new Error("Silent notification flags require API 23 or later");
      }
      if (!(await notificationManager.isNotificationEnabled())) {
        await notificationManager.requestEnableNotification(context.abilityContext);
      }
      if (!context.isActive()) {
        throw new Error("Notification bridge session ended during authorization");
      }
      const abilityInfo = context.abilityContext.abilityInfo;
      const agentFor = async (uri: string): Promise<WantAgent> => {
        return wantAgent.getWantAgent({
          wants: [
            {
              bundleName: abilityInfo.bundleName,
              abilityName: abilityInfo.name,
              uri,
            },
          ],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: requestCode(uri),
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
        });
      };
      const buttons: notificationManager.NotificationActionButton[] = [];
      for (const item of request.actions) {
        buttons.push({
          title: item.label,
          wantAgent: await agentFor(responseUri(this.responseScheme, request.tag, item.id)),
        });
      }
      // additionalText is not rendered by the notification center. Keep
      // the sender visible without repeating a name already in the title.
      const bodyText =
        senderName && senderName !== request.title
          ? `${senderName}\n${request.body}`
          : request.body;
      const normal: notificationManager.NotificationBasicContent = {
        title: request.title,
        text: bodyText,
        additionalText: senderName || undefined,
      };
      const notification: notificationManager.NotificationRequest = {
        id: requestCode(request.tag),
        label: notificationLabel(request.tag),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal,
        },
        wantAgent: await agentFor(responseUri(this.responseScheme, request.tag)),
        actionButtons: buttons,
      };
      if (group.length > 0) {
        notification.groupName = group;
      }
      if (slot === "social") {
        notification.notificationSlotType = notificationManager.SlotType.SOCIAL_COMMUNICATION;
      }
      if (silent) {
        // API 23+ explicitly disables both audible and vibrating alerts.
        notification.notificationFlags = { soundEnabled: 2, vibrationEnabled: 2 };
      }

      let avatar: image.PixelMap | undefined;
      let avatarSource: image.ImageSource | undefined;
      let icon: image.PixelMap | undefined;
      let source: image.ImageSource | undefined;
      try {
        if (imageBytes.length > 0) {
          source = image.createImageSource(new Uint8Array(imageBytes).buffer as ArrayBuffer);
          const info = await source.getImageInfo();
          if (info.size.width <= 0 || info.size.height <= 0) {
            throw new Error("Invalid notification image dimensions");
          }
          const scale = Math.min(1, 512 / info.size.width, 512 / info.size.height);
          icon = await source.createPixelMap({
            desiredSize: {
              width: Math.max(1, Math.floor(info.size.width * scale)),
              height: Math.max(1, Math.floor(info.size.height * scale)),
            },
            desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
          });
          // Picture content is the public attachment presentation. It avoids
          // relying on the optional large application icon's device policy.
          notification.content = {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_PICTURE,
            picture: {
              title: normal.title,
              text: normal.text,
              additionalText: normal.additionalText,
              briefText: request.body,
              expandedTitle: request.title,
              picture: icon,
            },
          };
        }
        if (avatarBytes.length > 0) {
          avatarSource = image.createImageSource(new Uint8Array(avatarBytes).buffer as ArrayBuffer);
          avatar = await avatarSource.createPixelMap({
            desiredSize: { width: 128, height: 128 },
          });
          notification.smallIcon = avatar;
        }
        if (!context.isActive()) {
          throw new Error("Notification session ended before publish");
        }
        await notificationManager.publish(notification);
      } finally {
        if (avatar !== undefined) {
          await avatar.release();
        }
        if (avatarSource !== undefined) {
          avatarSource.release();
        }
        if (icon !== undefined) {
          await icon.release();
        }
        if (source !== undefined) {
          source.release();
        }
      }
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new NotificationAcknowledgement(true) };
    }
    if (action === "dismiss") {
      const request = expectBridgeRequestType(
        payload,
        this.id,
        action,
        DISMISS_REQUEST_TYPE,
      ) as DismissRequest;
      if (!request.tag) {
        throw new Error("Notification tag must be non-empty");
      }
      await notificationManager.cancel(requestCode(request.tag), notificationLabel(request.tag));
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new NotificationAcknowledgement(true) };
    }
    throw new Error(`Unsupported ${this.id} action '${action}'`);
  }
}
