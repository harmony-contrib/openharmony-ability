import { webview } from '@kit.ArkWeb';

/**
 * Phase 1 验证测试页
 *
 * 验证目标：
 * 1. 默认异步渲染模式 (ASYNC_RENDER) 下，.backgroundColor(Color.Transparent) 是否让 Web 组件透明
 * 2. 同步渲染模式 (SYNC_RENDER) 下，透明是否生效
 *
 * 验证方法：
 * - 每个 Web 组件下方都有一个彩色背景块（红色/蓝色）
 * - Web 页面内容是一个半屏高度的绿色条 + 其余区域透明
 * - 如果透明生效，你应该能看到 Web 下方的彩色背景
 * - 如果透明不生效，Web 区域会是白色/不透明
 */
@Entry
@Component
struct TransparencyTest {
  @State testMode: number = 0; // 0=async(default), 1=sync
  // Create controllers once in aboutToAppear to avoid recreating on every re-render
  @State controller1: webview.WebviewController = new webview.WebviewController();
  @State controller2: webview.WebviewController = new webview.WebviewController();
  @State controller3: webview.WebviewController = new webview.WebviewController();

  // 内嵌 HTML：上半部分绿色条，下半部分透明
  // 如果透明生效，下半部分应该能看到底部的彩色背景
  private transparentHtml: string = `data:text/html;charset=utf-8,<!DOCTYPE html>
<html>
<head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:transparent;">
  <div style="background:rgba(0,200,0,0.7);height:80px;color:white;font-size:18px;padding:10px;">
    Green bar (semi-transparent green)
  </div>
  <div style="height:200px;display:flex;align-items:center;justify-content:center;color:%23333;font-size:16px;">
    This area should be TRANSPARENT<br>
    (you should see the colored bg below)
  </div>
</body>
</html>`;

  @Builder
  TestCard(title: string, bgColor: ResourceColor, renderMode: RenderMode, ctrl: webview.WebviewController) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .width("100%")

      // Stack: 底层彩色背景 + 上层 Web 组件
      Stack() {
        // 底层：彩色背景块，用于验证透明穿透
        Column() {
          Text("COLORED BG - Should be visible through transparent area")
            .fontSize(12)
            .fontColor(Color.White)
            .textAlign(TextAlign.Center)
        }
        .width("100%")
        .height(280)
        .backgroundColor(bgColor)
        .justifyContent(FlexAlign.Center)

        // 上层：Web 组件，背景设为透明
        Web({ src: this.transparentHtml, controller: ctrl })
          .width("100%")
          .height(280)
          .backgroundColor(Color.Transparent)
          // 根据测试模式选择渲染模式
          .renderMode(renderMode)
          .javaScriptAccess(false)
      }
      .width("100%")
      .height(280)
    }
    .width("100%")
    .padding(8)
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text("Phase 1: WebView 透明度验证")
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .width("100%")
          .textAlign(TextAlign.Center)

        Text("验证说明：如果 Web 组件透明生效，下方彩色背景应该能透过 Web 的白色/透明区域显示出来。")
          .fontSize(13)
          .fontColor(Color.Gray)
          .width("100%")

        // 测试 1：默认异步渲染模式
        this.TestCard(
          "Test 1: ASYNC_RENDER (默认模式)",
          Color.Red,
          RenderMode.ASYNC_RENDER,
          this.controller1
        )

        // 测试 2：同步渲染模式
        this.TestCard(
          "Test 2: SYNC_RENDER (同步模式)",
          Color.Blue,
          RenderMode.SYNC_RENDER,
          this.controller2
        )

        // 测试 3：对照组 - 不透明 Web（验证非透明场景正常）
        Column({ space: 4 }) {
          Text("Test 3: 对照组 - 不透明 Web (应看到白色背景)")
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .width("100%")

          Web({ src: this.transparentHtml, controller: this.controller3 })
            .width("100%")
            .height(280)
            .renderMode(RenderMode.ASYNC_RENDER)
            .javaScriptAccess(false)
            // 注意：不设置 .backgroundColor，使用默认不透明
        }
        .width("100%")
        .padding(8)

        // 验证结果记录
        Column({ space: 8 }) {
          Text("📋 验证结果记录")
            .fontSize(16)
            .fontWeight(FontWeight.Bold)

          Text("Test 1 (ASYNC_RENDER + Transparent):")
            .fontSize(13)
          Text("  绿色条是否可见？___  红色背景是否透过？___")
            .fontSize(12).fontColor(Color.Gray)

          Text("Test 2 (SYNC_RENDER + Transparent):")
            .fontSize(13)
          Text("  绿色条是否可见？___  蓝色背景是否透过？___")
            .fontSize(12).fontColor(Color.Gray)

          Text("Test 3 (对照组 - 不透明):")
            .fontSize(13)
          Text("  绿色条是否可见？___  白色/不透明背景？___")
            .fontSize(12).fontColor(Color.Gray)

          Text("预期结果：")
            .fontSize(14).fontWeight(FontWeight.Bold).margin({ top: 8 })
          Text("• Test 1 & 2: 绿色条可见 + 彩色背景透过 = 透明生效")
            .fontSize(12).fontColor(Color.Green)
          Text("• Test 3: 绿色条可见 + 白色背景 = 不透明（对照组正常）")
            .fontSize(12).fontColor(Color.Green)
          Text("• 如果 Test 1 不透明但 Test 2 透明 → 需要用 SYNC_RENDER")
            .fontSize(12).fontColor(Color.Orange)
        }
        .width("100%")
        .padding(12)
        .backgroundColor("#F5F5F5")
        .borderRadius(8)
      }
      .width("100%")
      .padding(16)
    }
    .width("100%")
    .height("100%")
  }
}
