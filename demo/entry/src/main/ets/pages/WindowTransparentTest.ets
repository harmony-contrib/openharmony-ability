import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Phase 2: 窗口级透明穿透验证测试页
 *
 * 验证目标：
 * 1. setWindowContainerColor inactive alpha 是否允许透明（验证诉求 4）
 * 2. 主窗口全透明是否能穿透到桌面
 * 3. setWindowContainerColor 与 setWindowBackgroundColor 的分区显示效果
 *
 * 前置条件：
 * - module.json5 中已声明 ohos.permission.SET_WINDOW_TRANSPARENT
 * - 在 OHOS 2in1/PC 设备（API 20+）上运行
 */

interface TestResult {
  status: string;     // 'pending' | 'running' | 'success' | 'fail' | 'restore'
  code?: number;
  message?: string;
  detail?: string;
}

@Entry
@Component
struct WindowTransparentTest {
  @State test1Result: TestResult = { status: 'pending' };
  @State test2Result: TestResult = { status: 'pending' };
  @State test3Result: TestResult = { status: 'pending' };
  private uiContext: UIContext = this.getUIContext();

  private async getMainWindow(): Promise<window.Window | null> {
    return new Promise<window.Window | null>((resolve) => {
      window.getLastWindow(this.uiContext.getHostContext(), (err: BusinessError, data: window.Window) => {
        if (err) {
          console.error(`[WindowTransparentTest] getLastWindow failed: code=${err.code}, msg=${err.message}`);
          resolve(null);
        } else {
          resolve(data);
        }
      });
    });
  }

  // ─── Test 1: inactive alpha 验证 ────────────────────────────────────
  // 验证 setWindowContainerColor('#00000000', '#00000000') 是否报 401
  private async runTest1() {
    this.test1Result = { status: 'running', detail: '正在获取主窗口...' };
    const win = await this.getMainWindow();
    if (!win) {
      this.test1Result = { status: 'fail', message: 'getLastWindow 返回 null' };
      return;
    }

    // Step A: 尝试 focused=transparent, unfocused=transparent
    this.test1Result = { status: 'running', detail: 'Step A: 调用 setWindowContainerColor(transparent, transparent)...' };
    try {
      await win.setWindowContainerColor('#00000000', '#00000000');
      this.test1Result = {
        status: 'success',
        detail: 'Step A 成功: setWindowContainerColor("#00000000", "#00000000") 未报错。' +
          'inactive alpha 允许透明值！诉求 4 的 401 结论需要修正。' +
          '\n\n请切换到其他窗口再切回来，观察窗口是否保持透明（还是失焦后变黑）。'
      };
    } catch (err: any) {
      const e = err as BusinessError;
      this.test1Result = {
        status: 'fail',
        code: e.code,
        message: e.message,
        detail: `Step A 失败: code=${e.code}, message=${e.message}` +
          (e.code === 401 ? '\n\n确认: inactive alpha 被限制为 0xFF，诉求 4 结论成立。' : '') +
          (e.code === 201 ? '\n\n权限不足: 检查 module.json5 中是否声明了 ohos.permission.SET_WINDOW_TRANSPARENT。' : '') +
          (e.code === 801 ? '\n\n当前设备不支持此 API。' : '')
      };
      return;
    }

    // Step B: 对照测试 focused=transparent, unfocused=opaque
    try {
      await win.setWindowContainerColor('#00000000', '#FF000000');
      this.test1Result = {
        status: 'success',
        detail: this.test1Result.detail +
          '\n\nStep B 也成功: setWindowContainerColor("#00000000", "#FF000000") 未报错。' +
          '\n请切换窗口焦点观察: 失焦后窗口容器是否变为黑色不透明。'
      };
    } catch (err: any) {
      const e = err as BusinessError;
      this.test1Result = {
        status: 'success',
        detail: this.test1Result.detail +
          `\n\nStep B 失败 (预期内): code=${e.code}, message=${e.message}`
      };
    }
  }

  // ─── Test 2: 主窗口全透明穿透 ────────────────────────────────────
  private async runTest2() {
    this.test2Result = { status: 'running', detail: '正在获取主窗口...' };
    const win = await this.getMainWindow();
    if (!win) {
      this.test2Result = { status: 'fail', message: 'getLastWindow 返回 null' };
      return;
    }

    this.test2Result = { status: 'running', detail: '正在设置窗口全透明...' };
    try {
      // Step 1: 内容区透明
      await win.setWindowBackgroundColor('#00000000');
      // Step 2: 容器（含标题栏）透明
      await win.setWindowContainerColor('#00000000', '#00000000');

      this.test2Result = {
        status: 'success',
        detail: '设置成功。请观察：\n' +
          '1. 窗口标题栏区域是否透明（能看到后面的桌面/窗口）\n' +
          '2. 窗口内容区域是否透明（能看到后面的桌面/窗口）\n' +
          '3. 页面中绘制的彩色条纹背景是否可见（验证 ArkUI 层透明穿透）\n\n' +
          '点击「恢复白色」按钮可还原。'
      };
    } catch (err: any) {
      const e = err as BusinessError;
      this.test2Result = {
        status: 'fail',
        code: e.code,
        message: e.message,
        detail: `设置失败: code=${e.code}, message=${e.message}`
      };
    }
  }

  // ─── Test 3: Container vs Background 分区显示 ────────────────────────
  private async runTest3() {
    this.test3Result = { status: 'running', detail: '正在获取主窗口...' };
    const win = await this.getMainWindow();
    if (!win) {
      this.test3Result = { status: 'fail', message: 'getLastWindow 返回 null' };
      return;
    }

    this.test3Result = { status: 'running', detail: 'Step A: container=红, background=蓝...' };
    try {
      // Step A: container 红色, background 蓝色
      // 预期：标题栏区域显示红色，内容区域显示蓝色
      await win.setWindowContainerColor('#FFFF0000', '#FFFF0000');
      await win.setWindowBackgroundColor('#FF0000FF');

      this.test3Result = {
        status: 'success',
        detail: 'Step A 完成: container=红色(#FFFF0000), background=蓝色(#FF0000FF)\n' +
          '预期：标题栏区域应为红色，内容区域应为蓝色。\n' +
          '请观察实际效果是否一致。\n\n' +
          '点击「Step B: 全透明」继续验证。'
      };
    } catch (err: any) {
      const e = err as BusinessError;
      this.test3Result = {
        status: 'fail',
        code: e.code,
        message: e.message,
        detail: `Step A 失败: code=${e.code}, message=${e.message}`
      };
    }
  }

  private async runTest3StepB() {
    this.test3Result = { status: 'running', detail: 'Step B: container=透明, background=透明...' };
    const win = await this.getMainWindow();
    if (!win) {
      this.test3Result = { status: 'fail', message: 'getLastWindow 返回 null' };
      return;
    }

    try {
      await win.setWindowContainerColor('#00000000', '#00000000');
      await win.setWindowBackgroundColor('#00000000');

      this.test3Result = {
        status: 'success',
        detail: 'Step B 完成: container=透明, background=透明\n' +
          '预期：标题栏 + 内容区域均透明，应能看到桌面。\n' +
          '页面内的彩色条纹应叠加在透明窗口之上。\n\n' +
          '点击「恢复白色」还原。'
      };
    } catch (err: any) {
      const e = err as BusinessError;
      this.test3Result = {
        status: 'fail',
        code: e.code,
        message: e.message,
        detail: `Step B 失败: code=${e.code}, message=${e.message}`
      };
    }
  }

  // ─── 恢复默认 ────────────────────────────────────────────────────────
  private async restoreDefault() {
    const win = await this.getMainWindow();
    if (!win) return;
    try {
      await win.setWindowBackgroundColor('#FFFFFFFF');
      await win.setWindowContainerColor('#FFFFFFFF', '#FFFFFFFF');
      this.test1Result = { status: 'pending' };
      this.test2Result = { status: 'pending' };
      this.test3Result = { status: 'pending' };
    } catch (err: any) {
      console.error(`[WindowTransparentTest] restore failed: ${JSON.stringify(err)}`);
    }
  }

  @Builder
  ResultDisplay(result: TestResult) {
    if (result.status === 'pending') {
      Text('⏳ 等待执行')
        .fontSize(13)
        .fontColor(Color.Gray)
    }
    if (result.status === 'running') {
      Text('⏳ ' + (result.detail ?? '执行中...'))
        .fontSize(13)
        .fontColor('#FF8800')
    }
    if (result.status === 'success') {
      Column() {
        Text('✅ 成功')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.Green)
        if (result.code !== undefined) {
          Text(`code: ${result.code}`)
            .fontSize(12)
            .fontColor(Color.Gray)
        }
        if (result.detail) {
          Text(result.detail)
            .fontSize(12)
            .fontColor('#333333')
            .margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
    }
    if (result.status === 'fail') {
      Column() {
        Text('❌ 失败')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.Red)
        if (result.code !== undefined) {
          Text(`code: ${result.code}`)
            .fontSize(12)
            .fontColor(Color.Red)
        }
        if (result.detail) {
          Text(result.detail)
            .fontSize(12)
            .fontColor('#333333')
            .margin({ top: 4 })
        }
        if (result.message) {
          Text(`message: ${result.message}`)
            .fontSize(12)
            .fontColor(Color.Gray)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
    }
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // ─── 标题区 ──────────────────────────────────────────────
        Text('Phase 2: 窗口级透明穿透验证')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .textAlign(TextAlign.Center)

        Text('验证 setWindowContainerColor inactive alpha 限制 & 主窗口透明穿透能力')
          .fontSize(13)
          .fontColor(Color.Gray)
          .width('100%')

        // ─── 彩色条纹背景（验证透明穿透时可见） ────────────────────
        Column() {
          Text('🎨 彩色条纹区域 — 如果窗口透明，此区域应可见')
            .fontSize(12)
            .fontColor(Color.White)
            .fontWeight(FontWeight.Bold)
        }
        .width('100%')
        .height(40)
        .backgroundColor('#FF00FF')
        .justifyContent(FlexAlign.Center)

        Row() {
          Column().width('25%').height(20).backgroundColor(Color.Red)
          Column().width('25%').height(20).backgroundColor(Color.Green)
          Column().width('25%').height(20).backgroundColor(Color.Blue)
          Column().width('25%').height(20).backgroundColor(Color.Yellow)
        }.width('100%')

        // ─── Test 1 ──────────────────────────────────────────────
        Column({ space: 8 }) {
          Text('Test 1: setWindowContainerColor inactive alpha 验证')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text('验证目标: setWindowContainerColor("#00000000", "#00000000") 是否报 401 错误')
            .fontSize(12)
            .fontColor(Color.Gray)
            .width('100%')

          Row({ space: 8 }) {
            Button('执行 Test 1')
              .fontSize(12)
              .onClick(() => { this.runTest1(); })
          }

          Column() {
            this.ResultDisplay(this.test1Result)
          }
          .width('100%')
          .padding(8)
          .backgroundColor('#F8F8F8')
          .borderRadius(6)
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)

        // ─── Test 2 ──────────────────────────────────────────────
        Column({ space: 8 }) {
          Text('Test 2: 主窗口全透明穿透验证')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text('验证目标: 主窗口背景 + 容器均设为透明后，能否穿透到桌面')
            .fontSize(12)
            .fontColor(Color.Gray)
            .width('100%')

          Row({ space: 8 }) {
            Button('执行 Test 2')
              .fontSize(12)
              .backgroundColor('#FF4444')
              .onClick(() => { this.runTest2(); })
          }

          Column() {
            this.ResultDisplay(this.test2Result)
          }
          .width('100%')
          .padding(8)
          .backgroundColor('#F8F8F8')
          .borderRadius(6)
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)

        // ─── Test 3 ──────────────────────────────────────────────
        Column({ space: 8 }) {
          Text('Test 3: Container vs Background 分区显示验证')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text('验证目标: 同时使用两个接口时，标题栏显示 container 色，内容区显示 background 色')
            .fontSize(12)
            .fontColor(Color.Gray)
            .width('100%')

          Row({ space: 8 }) {
            Button('Step A: 红/蓝')
              .fontSize(12)
              .onClick(() => { this.runTest3(); })
            Button('Step B: 全透明')
              .fontSize(12)
              .backgroundColor('#FF4444')
              .onClick(() => { this.runTest3StepB(); })
          }

          Column() {
            this.ResultDisplay(this.test3Result)
          }
          .width('100%')
          .padding(8)
          .backgroundColor('#F8F8F8')
          .borderRadius(6)
        }
        .width('100%')
        .padding(10)
        .backgroundColor('#FFFFFF')
        .borderRadius(8)

        // ─── 恢复按钮 ────────────────────────────────────────────
        Button('🔄 恢复白色（还原所有设置）')
          .width('100%')
          .fontSize(14)
          .backgroundColor('#4CAF50')
          .fontColor(Color.White)
          .onClick(() => { this.restoreDefault(); })

        // ─── 说明 ────────────────────────────────────────────────
        Column({ space: 6 }) {
          Text('📋 测试说明')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)

          Text('• Test 1 重点验证诉求文档中 "inactive alpha 强制 FF, 报 401" 的结论')
            .fontSize(12)
          Text('• Test 2 验证主窗口整体透明穿透到桌面的效果')
            .fontSize(12)
          Text('• Test 3 验证 container/background 分区显示逻辑是否与官方文档一致')
            .fontSize(12)
          Text('• 需要 API 20+ 2in1/PC 设备')
            .fontSize(12)
          Text('• 需要 module.json5 声明 ohos.permission.SET_WINDOW_TRANSPARENT')
            .fontSize(12)
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
      }
      .width('100%')
      .padding(16)
    }
    .width('100%')
    .height('100%')
  }
}
