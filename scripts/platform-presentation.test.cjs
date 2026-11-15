// Executes the actual ArkTS plugin bodies with platform doubles. This checks
// dispatch/lifetime behavior, not notification UI or device status-bar support.
// Run: ABILITY_TYPESCRIPT=/path/to/typescript node --test scripts/platform-presentation.test.cjs
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const ts = require(process.env.ABILITY_TYPESCRIPT || "typescript");

const bridge = {
  AsyncPluginBase: class {},
  BridgeAcknowledgement: class {
    constructor(accepted) {
      this.accepted = accepted;
    }
  },
  expectBridgeRequestType(payload, _plugin, _action, type) {
    assert.equal(payload.typeName, type);
    return payload.value;
  },
};
function load(relative, imports) {
  const filename = path.join(__dirname, "..", relative);
  const output = ts.transpileModule(fs.readFileSync(filename, "utf8"), {
    fileName: filename.replace(/\.ets$/, ".ts"),
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    reportDiagnostics: true,
  });
  assert.equal(output.diagnostics.length, 0);
  const module = { exports: {} };
  const requireDouble = (name) => {
    if (name === "@ohos-rs/ability") return bridge;
    assert.ok(Object.hasOwn(imports, name), `unexpected import ${name}`);
    return imports[name];
  };
  new Function("require", "module", "exports", output.outputText)(
    requireDouble,
    module,
    module.exports,
  );
  return module.exports;
}
function context() {
  return {
    active: true,
    isActive() {
      return this.active;
    },
    abilityContext: { abilityInfo: { bundleName: "example", name: "EntryAbility" } },
  };
}
function notificationHarness() {
  const ctx = context();
  const published = [],
    resources = [];
  const manager = {
    ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 1 },
    SlotType: { SOCIAL_COMMUNICATION: 1 },
    async isNotificationEnabled() {
      return true;
    },
    async publish(value) {
      published.push(value);
    },
  };
  function resource() {
    const value = {
      released: 0,
      release() {
        this.released++;
      },
    };
    resources.push(value);
    return value;
  }
  const device = { sdkApiVersion: 26 };
  const { NotificationPlugin } = load("plugins/notification/src/main/ets/NotificationPlugin.ets", {
    "@ohos.deviceInfo": { default: device },
    "@kit.ArkTS": { url: {} },
    "@kit.ImageKit": {
      image: {
        createImageSource() {
          return Object.assign(resource(), {
            async createPixelMap() {
              return resource();
            },
          });
        },
      },
    },
    "@ohos.app.ability.wantAgent": {
      default: {
        OperationType: { START_ABILITY: 1 },
        WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
        async getWantAgent(value) {
          return value;
        },
      },
    },
    "@kit.NotificationKit": { notificationManager: manager },
  });
  const plugin = new NotificationPlugin({ scheme: "messages" });
  const options = {
    tag: "m/1",
    title: "Title",
    body: "Body",
    actions: [{ id: "reply", label: "Reply" }],
    silent: true,
    group: "chat",
    image: [1],
    senderName: "Sender",
  };
  const request = { options, avatar: [2] };
  const invoke = (
    action = "show-social",
    value = request,
    typeName = "ohos.notification.ShowAvatarRequest",
  ) => plugin.invokeAsync(action, { typeName, value }, ctx);
  return { ctx, manager, device, published, resources, options, request, invoke };
}

test("social slot preserves silent flags, group, actions and images and releases pixel maps", async () => {
  const h = notificationHarness();
  const result = await h.invoke();
  assert.equal(result.typeName, "ohos.notification.Acknowledgement");
  assert.equal(result.value.accepted, true);
  assert.equal(h.published.length, 1);
  const n = h.published[0];
  assert.equal(n.notificationSlotType, 1);
  assert.equal(n.notificationFlags.soundEnabled, 2);
  assert.equal(n.notificationFlags.vibrationEnabled, 2);
  assert.equal(n.groupName, "chat");
  assert.equal(n.content.normal.additionalText, "Sender");
  assert.equal(
    n.actionButtons[0].wantAgent.wants[0].uri,
    "messages://response?tag=m%2F1&action=reply",
  );
  assert.equal(n.wantAgent.wants[0].uri, "messages://response?tag=m%2F1");
  assert.ok(n.smallIcon && n.largeIcon);
  assert.equal(h.resources.length, 4);
  assert.ok(h.resources.every((r) => r.released === 1));
});
test("social notification does not require a display name or avatar", async () => {
  const h = notificationHarness();
  h.options.senderName = "";
  h.options.image = [];
  h.request.avatar = [];
  await h.invoke();
  assert.equal(h.published[0].notificationSlotType, 1);
  assert.equal(h.published[0].smallIcon, undefined);
  assert.equal(h.resources.length, 0);
});
for (const action of ["show", "show-with-options", "show-with-avatar"]) {
  test(`${action} keeps its existing category behavior`, async () => {
    const h = notificationHarness();
    await h.invoke(
      action,
      action === "show-with-avatar" ? h.request : h.options,
      `ohos.notification.${action === "show" ? "ShowRequest" : action === "show-with-options" ? "ShowOptionsRequest" : "ShowAvatarRequest"}`,
    );
    assert.equal(h.published[0].notificationSlotType, undefined);
  });
}
test("invalid nested options, avatar and type names never publish", async () => {
  const h = notificationHarness();
  h.request.avatar = "invalid";
  await assert.rejects(h.invoke(), /Invalid notification avatar/);
  h.options.tag = " ";
  await assert.rejects(h.invoke(), /requires a tag/);
  await assert.rejects(h.invoke("show-social", h.options, "ohos.notification.ShowOptionsRequest"));
  assert.equal(h.published.length, 0);
  assert.ok(h.resources.every((r) => r.released === 1));
});
test("publish failure releases avatar and large image", async () => {
  const h = notificationHarness();
  h.manager.publish = async () => {
    throw new Error("publish denied");
  };
  await assert.rejects(h.invoke(), /publish denied/);
  assert.equal(h.resources.length, 4);
  assert.ok(h.resources.every((r) => r.released === 1));
});
test("session destruction during authorization prevents publication", async () => {
  const h = notificationHarness();
  h.manager.isNotificationEnabled = async () => {
    h.ctx.active = false;
    return true;
  };
  await assert.rejects(h.invoke(), /session ended during authorization/);
  assert.equal(h.published.length, 0);
  assert.equal(h.resources.length, 0);
});
test("older API rejects silent social requests but supports ordinary social delivery", async () => {
  const h = notificationHarness();
  h.device.sdkApiVersion = 22;
  await assert.rejects(h.invoke(), /require API 23/);
  h.options.silent = false;
  await h.invoke();
  assert.equal(h.published[0].notificationSlotType, 1);
  assert.equal(h.published[0].notificationFlags, undefined);
});

function statusbarHarness(query) {
  const ctx = context(),
    calls = [];
  const manager = {
    addToStatusBar(ability, _options, done) {
      assert.equal(ability, ctx.abilityContext);
      calls.push("add");
      done();
    },
  };
  if (query)
    manager.isStatusBarCapabilitySupported = (ability) => {
      assert.equal(ability, ctx.abilityContext);
      calls.push("query");
      return query();
    };
  const utils = {};
  for (const name of [
    "setAbilityContext",
    "setCurrentAbilityName",
    "reRegisterStatusBarClickHandlers",
    "fillMenuItemAbilityName",
    "processMenuItemIcons",
    "createPixelMapFromRgba",
  ]) {
    utils[name] = () => {
      calls.push(name);
      return {};
    };
  }
  const { StatusbarPlugin } = load("plugins/statusbar/src/main/ets/StatusbarPlugin.ets", {
    "@kit.DeskTopExtensionKit": { statusBarManager: manager },
    "@kit.BasicServicesKit": {},
    "@kit.PerformanceAnalysisKit": { hilog: { info() {}, error() {} } },
    "@ohos-rs/ability-plugin-menu": {},
    "./StatusBarUtils": utils,
  });
  const plugin = new StatusbarPlugin();
  const invoke = (action) =>
    plugin.invokeAsync(
      action,
      {
        typeName: `ohos.statusbar.${action === "add" ? "AddRequest" : "AddItemsRequest"}`,
        value: {
          whiteIcon: new Uint8Array(4),
          iconSize: 1,
          abilityName: "",
          title: "Tray",
          height: 0,
        },
      },
      ctx,
    );
  return { ctx, calls, invoke };
}
for (const action of ["add", "add-items"]) {
  test(`${action}: unsupported state causes no allocations or registration`, async () => {
    const h = statusbarHarness(async () => false);
    await assert.rejects(h.invoke(action), /not supported/);
    assert.deepEqual(h.calls, ["query"]);
  });
  test(`${action}: supported state reaches native callback before acknowledgement`, async () => {
    const h = statusbarHarness(async () => true);
    const result = await h.invoke(action);
    assert.equal(result.value.accepted, true);
    assert.deepEqual(h.calls, [
      "query",
      "setAbilityContext",
      "setCurrentAbilityName",
      "createPixelMapFromRgba",
      "add",
      "reRegisterStatusBarClickHandlers",
    ]);
  });
  test(`${action}: destruction during query never adds an icon`, async () => {
    let finish;
    const h = statusbarHarness(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    const call = h.invoke(action);
    h.ctx.active = false;
    finish(true);
    await assert.rejects(call, /session ended during capability query/);
    assert.deepEqual(h.calls, ["query"]);
  });
}
test("failed capability query is propagated without adding a tray item", async () => {
  const h = statusbarHarness(async () => {
    throw new Error("query failed");
  });
  await assert.rejects(h.invoke("add-items"), /query failed/);
  assert.deepEqual(h.calls, ["query"]);
});
test("systems without the API retain the existing add path", async () => {
  const h = statusbarHarness();
  assert.equal((await h.invoke("add-items")).value.accepted, true);
  assert.ok(h.calls.includes("add"));
});
