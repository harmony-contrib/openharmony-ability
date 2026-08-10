import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from "@ohos/hypium";
import { SerialTaskQueue } from "../main/ets/runtime/SerialTaskQueue";

export default function localUnitTest() {
  describe("localUnitTest", () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it("assertContain", 0, () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.
      let a = "abc";
      let b = "b";
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertContain(b);
      expect(a).assertEqual(a);
    });
    it("serialTaskQueuePreservesLifecycleOrder", 0, async () => {
      const events: string[] = [];
      let release: () => void = (): void => {};
      const gate = new Promise<void>((resolve) => {
        release = resolve;
      });
      const queue = new SerialTaskQueue((): void => {});

      void queue.enqueue("create", async (): Promise<void> => {
        events.push("create-start");
        await gate;
        events.push("create-end");
      });
      void queue.enqueue("window", async (): Promise<void> => {
        events.push("window");
      });

      await Promise.resolve();
      expect(events.join(",")).assertEqual("create-start");
      release();
      await queue.settled();
      expect(events.join(",")).assertEqual("create-start,create-end,window");
    });
    it("serialTaskQueueContinuesAfterFailure", 0, async () => {
      const errors: string[] = [];
      const events: string[] = [];
      const queue = new SerialTaskQueue((label: string): void => {
        errors.push(label);
      });

      void queue.enqueue("broken", async (): Promise<void> => {
        throw new Error("expected failure");
      });
      void queue.enqueue("destroy", async (): Promise<void> => {
        events.push("destroy");
      });
      await queue.settled();

      expect(errors.join(",")).assertEqual("broken");
      expect(events.join(",")).assertEqual("destroy");
    });
  });
}
