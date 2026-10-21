import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { stripTypeScriptTypes } from "node:module";
import test from "node:test";

// Load the actual pure ETS algorithms. UIContext is used only as a type; native
// BuilderNode dispatch and SDK event wrapping remain device-level acceptance.
const source = await readFile(
  new URL("../src/main/ets/NativePointer.ets", import.meta.url),
  "utf8",
);
const script = stripTypeScriptTypes(source);
const { TouchCoordinates, PointerPosting, TouchCancel, NativeRetirement } = await import(
  `data:text/javascript,${encodeURIComponent(script)}`
);

const touchType = { Down: 0, Up: 1, Move: 2, Cancel: 3 };
globalThis.TouchType = touchType;
const ui = { vp2px: (value) => value * 2 };

test("reentrant closing detaches before scope expiry and defers only builder disposal", () => {
  const posting = new PointerPosting();
  const retirement = new NativeRetirement();
  const order = [];
  let scopeLive = true;
  posting.busy = true;
  const original = point();
  const event = { type: touchType.Down, touches: [original], changedTouches: [original] };
  const coordinates = new TouchCoordinates(event);
  coordinates.apply(ui, 11, 13);
  retirement.detachThenDispose(
    () => {
      assert.equal(scopeLive, true);
      order.push("detach");
    },
    () => {
      assert.equal(scopeLive, false);
      assert.equal(original.windowX, 100);
      order.push("dispose");
    },
    posting,
  );
  scopeLive = false;
  order.push("rust-destroy");
  assert.deepEqual(order, ["detach", "rust-destroy"]);
  posting.finish(coordinates);
  assert.deepEqual(order, ["detach", "rust-destroy", "dispose"]);
  retirement.detachThenDispose(
    () => assert.fail("duplicate detach"),
    () => assert.fail("duplicate dispose"),
    posting,
  );
});

test("a rejected native detach queues no disposal and cannot appear acknowledged", () => {
  const posting = new PointerPosting();
  const retirement = new NativeRetirement();
  posting.busy = true;
  assert.throws(
    () =>
      retirement.detachThenDispose(
        () => {
          throw new Error("operation guard");
        },
        () => assert.fail("borrowed owner disposed"),
        posting,
      ),
    /operation guard/,
  );
  assert.equal(posting.retirements.length, 0);
  posting.finish();
});

function point(id = 7) {
  return {
    type: touchType.Down,
    id,
    x: 3,
    y: 5,
    windowX: 100,
    windowY: 200,
    displayX: 1000,
    displayY: 2000,
    globalDisplayX: undefined,
    globalDisplayY: 3000,
    screenX: 4000,
    screenY: 5000,
    pressure: 0.5,
    width: 8,
    height: 10,
  };
}

test("shared touch points convert once while retaining the SDK object and its references", () => {
  const shared = point();
  const second = point(9);
  const originalShared = { ...shared };
  const originalSecond = { ...second };
  const nativePayload = {};
  const event = {
    type: touchType.Down,
    touches: [shared, second],
    changedTouches: [shared],
    nativePayload,
  };
  const touches = event.touches;
  const changed = event.changedTouches;
  const coordinates = new TouchCoordinates(event);
  try {
    coordinates.apply(ui, 11, 13);
    assert.strictEqual(event.nativePayload, nativePayload);
    assert.strictEqual(event.touches, touches);
    assert.strictEqual(event.changedTouches, changed);
    assert.strictEqual(event.touches[0], event.changedTouches[0]);
    assert.equal(shared.windowX, 28);
    assert.equal(shared.windowY, 36);
    assert.equal(shared.displayX, 2000);
    assert.equal(shared.displayY, 4000);
    assert.equal(shared.globalDisplayX, undefined);
    assert.equal(shared.globalDisplayY, 6000);
    assert.equal(second.displayX, 2000);
  } finally {
    coordinates.restore();
  }
  assert.deepEqual(shared, originalShared);
  assert.deepEqual(second, originalSecond);
});

test("failed dispatch restores temporary CANCEL types and coordinates", () => {
  const shared = point();
  const original = { ...shared };
  const event = { type: touchType.Down, touches: [shared], changedTouches: [shared] };
  const coordinates = new TouchCoordinates(event);
  const failure = new Error("dispatch failed");
  assert.throws(
    () => {
      try {
        coordinates.apply(ui, 11, 13);
        coordinates.cancel();
        assert.equal(event.type, touchType.Cancel);
        assert.equal(shared.type, touchType.Cancel);
        throw failure;
      } finally {
        coordinates.restore();
      }
    },
    (error) => error === failure,
  );
  assert.equal(event.type, touchType.Down);
  assert.deepEqual(shared, original);
});

test("partial coordinate conversion restores every point and releases posting", () => {
  const first = point();
  const second = point(9);
  const originalFirst = { ...first };
  const originalSecond = { ...second };
  const event = { type: touchType.Down, touches: [first, second], changedTouches: [first] };
  const coordinates = new TouchCoordinates(event);
  const posting = new PointerPosting();
  posting.busy = true;
  let calls = 0;
  const failure = new Error("conversion failed");
  assert.throws(
    () => {
      try {
        coordinates.apply(
          {
            vp2px: (value) => {
              if (++calls === 3) {
                throw failure;
              }
              return value * 2;
            },
          },
          11,
          13,
        );
      } finally {
        posting.finish(coordinates);
      }
    },
    (error) => error === failure,
  );
  assert.deepEqual(first, originalFirst);
  assert.deepEqual(second, originalSecond);
  assert.equal(posting.busy, false);
});

test("retirement CANCEL owns primitive point data without retaining callback objects", () => {
  const shared = point();
  const event = {
    type: touchType.Move,
    timestamp: 42,
    source: 1,
    sourceTool: 2,
    deviceId: 3,
    targetDisplayId: 4,
    touches: [shared],
    changedTouches: [shared],
    target: {},
    getModifierKeyState: () => true,
  };
  const snapshot = new TouchCancel(event);
  assert.equal(snapshot.type, touchType.Cancel);
  assert.notStrictEqual(snapshot.touches, event.touches);
  assert.notStrictEqual(snapshot.changedTouches, event.changedTouches);
  assert.notStrictEqual(snapshot.touches[0], shared);
  assert.notStrictEqual(snapshot.changedTouches[0], shared);
  assert.equal("target" in snapshot, false);
  assert.equal("getModifierKeyState" in snapshot, false);
  for (const copied of [...snapshot.touches, ...snapshot.changedTouches]) {
    assert.equal(copied.type, touchType.Cancel);
    assert.ok(
      Object.values(copied).every((value) => value === undefined || typeof value === "number"),
    );
  }
  shared.windowX = 999;
  event.touches.length = 0;
  assert.equal(snapshot.touches.length, 1);
  assert.equal(snapshot.touches[0].windowX, 100);
});

test("posting restores coordinates before releasing busy and drains newly queued retirements", () => {
  const shared = point();
  const original = { ...shared };
  const event = { type: touchType.Down, touches: [shared], changedTouches: [shared] };
  const coordinates = new TouchCoordinates(event);
  const posting = new PointerPosting();
  posting.busy = true;
  coordinates.apply(ui, 11, 13);
  coordinates.cancel();
  const retired = [];
  posting.retirements.push(() => {
    assert.equal(posting.busy, false);
    assert.equal(event.type, touchType.Down);
    assert.deepEqual(shared, original);
    retired.push("first");
    posting.retirements.push(() => retired.push("second"));
  });
  posting.finish(coordinates);
  assert.deepEqual(retired, ["first", "second"]);
  assert.equal(posting.retirements.length, 0);
});

test("posting releases busy and drains retirement even when restoration throws", () => {
  const failure = new Error("restoration failed");
  class FailingCoordinates extends TouchCoordinates {
    restore() {
      super.restore();
      throw failure;
    }
  }
  const shared = point();
  const event = { type: touchType.Down, touches: [shared], changedTouches: [shared] };
  const coordinates = new FailingCoordinates(event);
  const posting = new PointerPosting();
  posting.busy = true;
  coordinates.apply(ui, 11, 13);
  let retired = false;
  posting.retirements.push(() => {
    assert.equal(posting.busy, false);
    retired = true;
  });
  assert.throws(
    () => posting.finish(coordinates),
    (error) => error === failure,
  );
  assert.equal(posting.busy, false);
  assert.equal(retired, true);
  assert.equal(posting.retirements.length, 0);
});
