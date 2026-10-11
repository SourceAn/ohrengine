/*
 * GlFlipSurface.ets — GL 翻页渲染挂载点（XComponent SURFACE）
 *
 * 官方 onLoad context 模板（FR-025/FR-027/FR-028）：
 *  - XComponent 绑定 XComponentController（libraryname 加载 ohrengine_gl.so）
 *  - onLoad 回调的 event（或 controller.getXComponentContext()）即 native context
 *    （InitModule exports 上 napi_define_properties 挂载的自定义方法集合），
 *    直接调用 GlFlipEngine.onSurfaceLoaded(context) 完成初始化（无 FrameNode 传递，
 *    回调注册已在 native InitModule 完成：exports → arkui_xcomponent → RegisterCallback）
 *  - onLoad 后 getXComponentSurfaceId() 获取 surfaceId（FR-028）
 *  - onDestroy 插件卸载回调 → GlFlipEngine.destroy()（FR-027，与 native
 *    OnSurfaceDestroyed 职责区分——前者组件卸载、后者 surface 销毁；destroy 幂等）
 *  - 触摸穿透：XComponent 不接收触摸（hitTestBehavior None），
 *    手势仍由下层 Canvas.onTouch 处理
 *  - 透明背景：native 侧 glClear 透明 + EGL 透明 surface
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlFlipEngine } from './GlFlipEngine.ets';

@Component
export struct GlFlipSurface {
  /** 内容宽（vp） */
  @Prop widthVp: number = 376;
  /** 内容高（vp） */
  @Prop heightVp: number = 742;
  /** 加载完成回调（查询 GlFlipEngine.isReady() 判定 GL 可用性） */
  onReady: () => void = () => {};
  /** XComponent 控制器（官方模板：context / surfaceId 获取） */
  private xComponentController: XComponentController = new XComponentController();
  /** 组件 id（XComponent 唯一标识） */
  private xComponentId: string = 'ohrengine_gl_flip_surface';
  /** onLoad 后由 controller.getXComponentSurfaceId() 记录的 surfaceId（FR-028） */
  private surfaceId: string = '';
  /** 是否初始化完成 */
  @State private loaded: boolean = false;

  /** Native surface 清屏后保持透明；该组件只负责挂载，不持有翻页状态。 */
  aboutToDisappear(): void {
    if (this.loaded) {
      GlFlipEngine.destroy();
    }
  }

  build() {
    XComponent({
      id: this.xComponentId,
      type: XComponentType.SURFACE,
      libraryname: 'ohrengine_gl',
      controller: this.xComponentController
    })
      .id(this.xComponentId)
      .width(this.widthVp)
      .height(this.heightVp)
      .position({ x: 0, y: 0 })
      .zIndex(90)
      // 关键：SURFACE 类型 XComponent 背景色默认为不透明纯黑色（文档
      // ts-basic-components-xcomponent.md），会盖住底层 Canvas 的静态页面。
      // 必须显式设透明背景，让静态内容透出；翻页动画由 native GL 绘制，
      // 动画结束 clear 透明后仍透出 Canvas 新页。
      .backgroundColor(Color.Transparent)
      // 触摸穿透：XComponent 仅渲染不交互（手势由 Canvas.onTouch 处理）
      .hitTestBehavior(HitTestMode.None)
      .onLoad(async (event?: object) => {
        // 官方 onLoad context：event 即 native InitModule exports
        //（与 controller.getXComponentContext() 返回一致），其上直接挂载
        // init/setTextures/setTouch/beginAnimation/endAnimation/destroy 自定义方法
        const sid: string = this.xComponentController.getXComponentSurfaceId();
        this.surfaceId = sid;
        hilog.info(0x3900, 'OhEngine', 'GlFlipSurface onLoad: surfaceId=%{public}s', sid);
        const context: Object = event ?? this.xComponentController.getXComponentContext();
        await GlFlipEngine.onSurfaceLoaded(context);
        this.loaded = true;
        this.onReady();
      })
      // 插件卸载回调（组件销毁时触发；与 native OnSurfaceDestroyed 职责区分，destroy 幂等）
      .onDestroy(() => {
        GlFlipEngine.destroy();
      })
  }
}
