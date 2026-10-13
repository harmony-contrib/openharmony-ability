import commonEventManager from "@ohos.commonEventManager";
import thermal from "@ohos.thermal";
import display from "@ohos.display";
import { ThermalSubscriptions } from "./ThermalSubscriptions";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgePluginHookContext,
  BridgeTypedValue,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

const GET_THERMAL_LEVEL_REQUEST_TYPE = "ohos.system-state.GetThermalLevelRequest";
const GET_THERMAL_LEVEL_RESPONSE_TYPE = "ohos.system-state.GetThermalLevelResponse";
const GET_BUNDLE_CODE_DIR_REQUEST_TYPE = "ohos.system-state.GetBundleCodeDirRequest";
const GET_BUNDLE_CODE_DIR_RESPONSE_TYPE = "ohos.system-state.GetBundleCodeDirResponse";
const GET_AVAILABLE_AREA_REQUEST_TYPE = "ohos.system-state.GetAvailableAreaRequest";
const GET_AVAILABLE_AREA_RESPONSE_TYPE = "ohos.system-state.GetAvailableAreaResponse";
const GET_DISPLAYS_REQUEST_TYPE = "ohos.system-state.GetDisplaysRequest";
const GET_DISPLAYS_RESPONSE_TYPE = "ohos.system-state.GetDisplaysResponse";
const CHANGED_EVENT_TYPE = "ohos.system-state.ChangedEvent";

class GetThermalLevelResponse {
  readonly level: number;

  constructor(level: number) {
    this.level = level;
  }
}

class GetBundleCodeDirResponse {
  readonly path: string;

  constructor(path: string) {
    this.path = path;
  }
}

class GetAvailableAreaResponse {
  readonly area: display.Rect;

  constructor(area: display.Rect) {
    this.area = area;
  }
}

class DisplaySnapshot {
  readonly id: number;
  readonly width: number;
  readonly height: number;
  readonly densityPixels: number;
  readonly availableArea?: display.Rect;
  readonly isDefault: boolean;

  constructor(info: display.Display, isDefault: boolean, availableArea?: display.Rect) {
    this.id = info.id;
    this.width = info.width;
    this.height = info.height;
    this.densityPixels = info.densityPixels;
    this.availableArea = availableArea;
    this.isDefault = isDefault;
  }
}

class GetDisplaysResponse {
  readonly displays: DisplaySnapshot[];

  constructor(displays: DisplaySnapshot[]) {
    this.displays = displays;
  }
}

export class SystemStatePlugin extends AsyncPluginBase {
  readonly id = "ohos.system-state";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private active = false;
  private unsubscribeThermal?: () => void;
  private currentDisplay: display.Display | null = null;
  private availableAreaCallback: (area: display.Rect) => void = () => {};
  private displayChangeCallback: (id: number) => void = () => {};

  onInstall(context: BridgePluginHookContext): void {
    if (this.active) {
      return;
    }
    this.active = true;
    try {
      this.unsubscribeThermal = ThermalSubscriptions.subscribe(
        (level: thermal.ThermalLevel): void => {
          this.emit(context, "thermal", level);
        },
      );
    } catch (error) {
      console.warn(`[SystemState] thermal registration failed: ${String(error)}`);
    }
    try {
      this.currentDisplay = display.getDefaultDisplaySync();
      this.availableAreaCallback = (area: display.Rect): void => {
        this.emit(context, "available-area", undefined, area);
      };
      this.currentDisplay.on("availableAreaChange", this.availableAreaCallback);
    } catch (error) {
      console.warn(`[SystemState] available area registration failed: ${String(error)}`);
    }
    this.displayChangeCallback = (_id: number): void => {
      this.refreshDisplays(context);
    };
    try {
      // The add/remove/change overloads exist since API 7. oxk currently
      // resolves the newer API 22 overload when linting these calls.
      display.on("add", this.displayChangeCallback);
      display.on("remove", this.displayChangeCallback);
      display.on("change", this.displayChangeCallback);
    } catch (error) {
      console.warn(`[SystemState] display change registration failed: ${String(error)}`);
    }

    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [
        commonEventManager.Support.COMMON_EVENT_SCREEN_OFF,
        commonEventManager.Support.COMMON_EVENT_SCREEN_ON,
        commonEventManager.Support.COMMON_EVENT_ENTER_FORCE_SLEEP,
        commonEventManager.Support.COMMON_EVENT_EXIT_FORCE_SLEEP,
      ],
    };
    commonEventManager
      .createSubscriber(info)
      .then(async (subscriber): Promise<void> => {
        if (!this.active || !context.isActive()) {
          await this.unsubscribeSubscriber(subscriber);
          return;
        }
        this.subscriber = subscriber;
        commonEventManager.subscribe(subscriber, (error, data) => {
          if (error) {
            console.warn(`[SystemState] common event failed: ${String(error)}`);
            return;
          }
          const event = data.event;
          if (
            event === commonEventManager.Support.COMMON_EVENT_SCREEN_OFF ||
            event === commonEventManager.Support.COMMON_EVENT_ENTER_FORCE_SLEEP
          ) {
            this.emit(context, "sleep");
          } else if (
            event === commonEventManager.Support.COMMON_EVENT_SCREEN_ON ||
            event === commonEventManager.Support.COMMON_EVENT_EXIT_FORCE_SLEEP
          ) {
            this.emit(context, "wake");
          }
        });
      })
      .catch((error: Error) => {
        console.warn(`[SystemState] common event registration failed: ${String(error)}`);
      });
  }

  async onDispose(): Promise<void> {
    this.active = false;
    try {
      this.unsubscribeThermal?.();
    } catch (error) {
      console.warn(`[SystemState] thermal unregister failed: ${String(error)}`);
    } finally {
      this.unsubscribeThermal = undefined;
    }
    if (this.currentDisplay !== null) {
      try {
        this.currentDisplay.off("availableAreaChange", this.availableAreaCallback);
      } catch (error) {
        console.warn(`[SystemState] available area unregister failed: ${String(error)}`);
      }
      this.currentDisplay = null;
    }
    try {
      display.off("add", this.displayChangeCallback);
      display.off("remove", this.displayChangeCallback);
      display.off("change", this.displayChangeCallback);
    } catch (error) {
      console.warn(`[SystemState] display change unregister failed: ${String(error)}`);
    }
    if (this.subscriber !== null) {
      const subscriber = this.subscriber;
      this.subscriber = null;
      await this.unsubscribeSubscriber(subscriber);
    }
  }

  private unsubscribeSubscriber(
    subscriber: commonEventManager.CommonEventSubscriber,
  ): Promise<void> {
    return new Promise<void>((resolve) => {
      try {
        commonEventManager.unsubscribe(subscriber, (error): void => {
          if (error) {
            console.warn(`[SystemState] common event unregister failed: ${String(error)}`);
          }
          resolve();
        });
      } catch (error) {
        console.warn(`[SystemState] common event unregister failed: ${String(error)}`);
        resolve();
      }
    });
  }

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("System state bridge session is no longer active");
    }
    if (action === "get-thermal-level") {
      expectBridgeRequestType(payload, this.id, action, GET_THERMAL_LEVEL_REQUEST_TYPE);
      return {
        typeName: GET_THERMAL_LEVEL_RESPONSE_TYPE,
        value: new GetThermalLevelResponse(thermal.getLevel()),
      };
    }
    if (action === "get-bundle-code-dir") {
      expectBridgeRequestType(payload, this.id, action, GET_BUNDLE_CODE_DIR_REQUEST_TYPE);
      return {
        typeName: GET_BUNDLE_CODE_DIR_RESPONSE_TYPE,
        value: new GetBundleCodeDirResponse(context.abilityContext.bundleCodeDir),
      };
    }
    if (action === "get-available-area") {
      expectBridgeRequestType(payload, this.id, action, GET_AVAILABLE_AREA_REQUEST_TYPE);
      const area = await display.getDefaultDisplaySync().getAvailableArea();
      return {
        typeName: GET_AVAILABLE_AREA_RESPONSE_TYPE,
        value: new GetAvailableAreaResponse(area),
      };
    }
    if (action === "get-displays") {
      expectBridgeRequestType(payload, this.id, action, GET_DISPLAYS_REQUEST_TYPE);
      return {
        typeName: GET_DISPLAYS_RESPONSE_TYPE,
        value: new GetDisplaysResponse(await this.loadDisplays()),
      };
    }
    throw new Error(`Unsupported ${this.id} action '${action}'`);
  }

  private async loadDisplays(): Promise<DisplaySnapshot[]> {
    const defaultId = display.getDefaultDisplaySync().id;
    const all = await display.getAllDisplays();
    return Promise.all(
      all
        .filter((item) => item.alive)
        .map(async (item) => {
          let area: display.Rect | undefined;
          try {
            area = await item.getAvailableArea();
          } catch (error) {
            console.warn(
              `[SystemState] available area for display ${item.id} failed: ${String(error)}`,
            );
          }
          return new DisplaySnapshot(item, item.id === defaultId, area);
        }),
    );
  }

  private refreshDisplays(context: BridgePluginHookContext): void {
    this.loadDisplays()
      .then((displays) => {
        this.emit(context, "displays", undefined, undefined, displays);
      })
      .catch((error: Error) => {
        console.warn(`[SystemState] display enumeration failed: ${String(error)}`);
      });
  }

  private emit(
    context: BridgePluginHookContext,
    kind: string,
    thermalLevel?: number,
    availableArea?: display.Rect,
    displays?: DisplaySnapshot[],
  ): void {
    if (!this.active || !context.isActive()) {
      return;
    }
    try {
      context.invokeNativeSync("state-changed", CHANGED_EVENT_TYPE, "std.bool", {
        kind,
        thermalLevel,
        availableArea,
        displays,
      });
    } catch (error) {
      console.warn(`[SystemState] state dispatch failed: ${String(error)}`);
    }
  }
}
