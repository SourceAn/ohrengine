/*
 * OhGlass.ets — 液态玻璃接口层
 *
 * 上层唯一入口。下层是 LiquidGlassRegistry（矩形解算 + 形变物理）+ 原生着色器。
 *
 * ============================ 用法 ============================
 *
 * 页面里（结构固定三件套）：
 *
 *   Stack() {
 *     Column() { ...页面内容... }.id(OhGlass.CONTENT_ID)   // ① 被玻璃看穿的背景
 *     OhGlassSurface()                                      // ② 唯一的 GL surface
 *     Column() { ...你的组件... }                            // ③ 内容盖在玻璃上
 *   }
 *
 * 页面 aboutToAppear：
 *
 *   OhGlass.register('lg:bar', OhGlassKind.PANEL, 20);    // 大面板，圆角 20vp
 *   OhGlass.registerCapsule('lg:btn');                     // 胶囊（半径=高度一半）
 *   OhGlass.setOptions({ blurSigma: 30, specular: 0.34 });
 *
 * 组件侧（任何已有组件，不新建组件类型）：
 *
 *   Button('字体')
 *     .backgroundColor('#00000000')                        // ①②③ 缺一不可
 *     .id('lg:btn')                                        // ②
 *     .systemMaterial(uiMaterial.Material.empty)           // ③
 *     .stateEffect(false)
 *     .onTouch((ev) => OhGlass.touch(ev, 'lg:btn'))        // 形变（可选）
 *
 * ======================= 三条必守规则 =======================
 *
 * ① 组件背景必须透明。带了底色就把玻璃盖住了。
 *
 * ② 必须显式关掉系统材质：.systemMaterial(uiMaterial.Material.empty)
 *    module.json5 里 "ohos.arkui.UIMaterial.state": "enable" 的语义是
 *    「系统沉浸式材质默认应用到所有组件」。不关的话，按下时 ArkUI 的按压态
 *    会画出自己的轮廓 —— 看起来像"玻璃里还套着一个胶囊"。
 *    这个瑕疵【只在真实手指按压时出现，程序性设置状态复现不出来】。
 *    Button 还要额外 .stateEffect(false) 关掉自带按压态。
 *
 * ③ z 序必须是「背景 → OhGlassSurface → 内容」。
 *    玻璃要透出背景，组件自己的文字/图标要盖在玻璃上面。
 *    另外：任何铺满全屏的容器，若不设 hitTestBehavior(HitTestMode.Transparent)，
 *    会阻断它下面整层的触摸事件。
 *
 * ==================== 为什么是全屏一个 surface ====================
 *
 * 每块玻璃一个 XComponent 的话：N 块 = N 个 EGL surface + N 份 FBO
 * + N 次背景回读 + N 趟全尺寸模糊，而且各自的 vsync 回调互相打架。
 * 全屏一个则是：1 次回读、1 趟模糊（所有玻璃共享结果）、每块玻璃 2 次 draw。
 * 实测 1→20 块，draw call 涨 633%，帧时间只涨 22%。
 */

import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlassEntry, LiquidGlassKind, LiquidGlassRegistry, RADIUS_CAPSULE } from './LiquidGlassRegistry';
import liquidglass from 'libliquidglass.so';

const DOMAIN = 0x3200;
const TAG = 'OhGlass';

/** 档位。参数全部由 Apple 原生输出实测反解，见 glass/README.md */
export enum OhGlassKind {
  /** 大面板 / 底部浮条 / 弹窗 —— 控制中心面板曲线（非线性压缩，浅色端饱和） */
  PANEL = LiquidGlassKind.SYS_PANEL,
  /** 小控件 / 胶囊按钮 —— 控制中心模块曲线（线性）；长宽比大时边光自动转均匀 */
  CAPSULE = LiquidGlassKind.SYS_MODULE,
  /** SDK glassEffect(.regular) —— 透 52%、加大量自身的光 */
  REGULAR = LiquidGlassKind.REGULAR,
  /** SDK glassEffect(.clear) */
  CLEAR = LiquidGlassKind.CLEAR,
}

export interface OhGlassOptions {
  /** 模糊 σ（以 2x 屏为基准，内部按实际 dpr 换算）。0 = 不模糊 */
  blurSigma?: number;
  /** 镜面倒角强度。实测控制中心 +80/255 ≈ 0.314 */
  specular?: number;
  /** 侧边正向高光占比。0 = 纯压暗（大面板）；小控件建议 0.25~0.55 */
  sideGain?: number;
  /** 侧边压暗。实测 −12/255 ≈ 0.047 */
  sideDarken?: number;
  /** 暗轮廓。1.0 = 关闭（改用阴影表达边界） */
  rim?: number;
  /** 边缘折射位移 px */
  refract?: number;
  /** 形变引起的额外折射（果冻感里"透过去的内容跟着扭"的那部分） */
  deformRefract?: number;
  /** 按压光晕强度 */
  glow?: number;
  /** 外阴影 强度 / 外扩 px / 模糊 px */
  shadow?: number;
  shadowOffset?: number;
  shadowBlur?: number;
  /** 形变强度 px（按压时最大凹陷深度） */
  deformAmp?: number;
  /** 形变范围 = 控件短边 × 该系数 */
  deformRange?: number;
}

/** 引擎单例 —— 全屏一个，所有玻璃共享 */
class OhGlassEngine {
  ready: boolean = false;
  surfaceId: string = 'ohglassSurface';
  contentId: string = 'ohglassContent';
  dpr: number = 3.5;

  /** 默认值 = 使用者手工调出来的那组预设 */
  opts: Required<OhGlassOptions> = {
    blurSigma: 0,        // 不模糊：内容原样透出，靠倒角与折射表达"玻璃"
    specular: 0.34,      // 镜面倒角
    sideGain: 0.25,      // 侧边正向高光占比
    sideDarken: 0.15,    // 侧边压暗
    rim: 1.0,            // 暗轮廓关闭（边界改由阴影表达）
    refract: 15,         // 边缘折射位移 px
    deformRefract: 0.7,  // 形变引起的额外折射
    glow: 0.35,          // 按压光晕
    shadow: 1.0,         // 阴影强度
    shadowOffset: 0,     // 阴影外扩
    shadowBlur: 0,       // 阴影模糊（0 = 硬边）
    deformAmp: 7.5,      // 形变强度 px
    deformRange: 1.2,    // 形变范围 = 短边 × 该系数
  };

  private timer: number = -1;
  private idle: number = 0;
  private pressed: GlassEntry | null = null;
  private layerBuf: ArrayBuffer = new ArrayBuffer(64 * 12 * 4);
  private globalBuf: ArrayBuffer = new ArrayBuffer(14 * 4);
  private capBusy: boolean = false;
  private uiCtx: UIContext | null = null;

  init(): void {
    const d = display.getDefaultDisplaySync();
    this.dpr = d.densityDPI / 160;
    if (this.dpr <= 0) { this.dpr = 3.5; }
    LiquidGlassRegistry.setDensity(this.dpr);
    this.applyOptions();
  }

  applyOptions(): void {
    LiquidGlassRegistry.MAXDEF = this.opts.deformAmp;
    LiquidGlassRegistry.RADIUS_SCALE = this.opts.deformRange;
  }

  pushGlobal(): void {
    const o = this.opts;
    const f = new Float32Array(this.globalBuf);
    // 顺序必须与 lg_napi.cpp 的 kGlobalStride 一致
    f[0] = o.blurSigma * this.dpr / 2;   // σ 以 2x 屏为基准
    f[1] = o.specular; f[2] = 2.0; f[3] = o.sideDarken;
    f[4] = o.rim; f[5] = 1.1;
    f[6] = o.refract; f[7] = 16.0; f[8] = o.deformRefract;
    f[9] = o.sideGain;
    f[10] = o.shadow; f[11] = o.shadowOffset; f[12] = o.shadowBlur;
    f[13] = o.glow;
    liquidglass.setGlobal(this.surfaceId, this.globalBuf);
  }

  /**
   * 解算所有已登记组件的矩形并重画。
   * 矩形由 componentUtils.getRectangleById 统一取，组件侧零代码。
   *
   * 注意：getRectangleById 返回的【已经是物理像素】，不要再乘 dpr。
   * 曾经乘过一次，卡片宽 3961px（屏幕才 1316），玻璃全跑到屏幕外，
   * 症状是"渲染在跑、draws 正常、但什么都看不见"。
   */
  sync(): void {
    if (!this.ready) { return; }
    LiquidGlassRegistry.resolve(0, 0, 0, 0);
    this.draw();
  }

  draw(): void {
    if (!this.ready) { return; }
    const f = new Float32Array(this.layerBuf);
    const n = LiquidGlassRegistry.pack(f, this.pressed);
    if (n > 0) { liquidglass.setLayers(this.surfaceId, this.layerBuf.slice(0, n * 12 * 4)); }
    else { liquidglass.setLayers(this.surfaceId, new ArrayBuffer(0)); }
    liquidglass.render(this.surfaceId);
  }

  /**
   * 重新截取背景。这是整条链路里最贵的一步（实测 44~147ms，= 2~9 帧）。
   * 只在内容真的变了时调用：布局变化 / 换页 / 主题切换 / 滚动结束。
   * 滚动中不要调，用位移补偿。
   */
  async capture(): Promise<void> {
    if (this.capBusy || !this.ready || this.uiCtx === null) { return; }
    this.capBusy = true;
    const t0: number = Date.now();
    try {
      const pm: image.PixelMap = await (this.uiCtx as UIContext)
        .getComponentSnapshot().get(this.contentId);
      const info = pm.getImageInfoSync();
      const stride = Math.ceil(pm.getBytesNumberPerRow() / 4);
      const buf = new ArrayBuffer(pm.getPixelBytesNumber());
      pm.readPixelsToBufferSync(buf);
      liquidglass.updateBackground(this.surfaceId, buf, info.size.width, info.size.height, stride);
      hilog.info(DOMAIN, TAG, 'capture %{public}s', `${info.size.width}x${info.size.height} ${Date.now() - t0}ms`);
      this.sync();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'capture failed: %{public}s', (e as Error).message);
    } finally {
      this.capBusy = false;
    }
  }

  setUIContext(ctx: UIContext): void { this.uiCtx = ctx; }

  /**
   * 形变触摸处理 —— 由玻璃组件自己调用。
   *
   * 【坐标空间】ArkUI 的 TouchObject：
   *     x / y            相对【组件自身】（vp）
   *     windowX/windowY  相对窗口
   * 而注册表里的矩形是【窗口】坐标（物理像素）。混用会导致
   * "不管按哪里形变都出现在左边"，而且永远满强度。
   */
  onTouch(ev: TouchEvent, id: string): void {
    if (!this.ready) { return; }
    const e = LiquidGlassRegistry.get(id);
    if (e === undefined) { return; }
    const t = ev.touches[0];
    if (t === undefined) { return; }
    const x = e.x + t.x * this.dpr;
    const y = e.y + t.y * this.dpr;
    if (ev.type === TouchType.Down) {
      this.pressed = e;
      LiquidGlassRegistry.press(e, x, y);
      this.startLoop();
    } else if (ev.type === TouchType.Move && this.pressed !== null) {
      LiquidGlassRegistry.press(this.pressed, x, y);
    } else if (ev.type === TouchType.Up || ev.type === TouchType.Cancel) {
      if (this.pressed !== null) { LiquidGlassRegistry.release(this.pressed); }
      this.pressed = null;
      this.startLoop();
    }
  }

  /** 形变物理循环。静下来 12 帧后自动停表 —— 静止时不出帧，不白耗电。 */
  startLoop(): void {
    if (this.timer !== -1) { return; }
    this.idle = 0;
    this.timer = setInterval(() => {
      const moving = LiquidGlassRegistry.step(this.pressed);
      if (this.pressed !== null || moving) {
        this.idle = 0;
        this.draw();
      } else {
        this.idle++;
        if (this.idle > 12) { this.stopLoop(); }
      }
    }, 16);
  }

  stopLoop(): void {
    if (this.timer !== -1) { clearInterval(this.timer); this.timer = -1; }
  }

  /** [frameMs, draws, layerCount, blurCacheHit, blurCacheMiss, programErrors] */
  stats(): Float32Array {
    try { return liquidglass.getStats(this.surfaceId); } catch (e) { return new Float32Array(6); }
  }

  dispose(): void {
    this.stopLoop();
    LiquidGlassRegistry.clear();
    try { liquidglass.dispose(this.surfaceId); } catch (e) { /* 忽略 */ }
  }
}

/** 全局单例 */
export const OhGlassEngineInstance: OhGlassEngine = new OhGlassEngine();

export class OhGlass {
  /** 背景容器的 id —— 被截图给玻璃做底 */
  static readonly CONTENT_ID: string = 'ohglassContent';

  /**
   * 登记一块玻璃。组件本身只需要一个 .id()
   * @param radiusVp 圆角，单位 vp（内部按实际 dpr 转物理像素）
   */
  static register(id: string, kind: OhGlassKind = OhGlassKind.PANEL, radiusVp: number = 20): void {
    LiquidGlassRegistry.register(id, kind, radiusVp);
  }

  /** 登记胶囊（半径 = 高度一半），和 ArkUI 的 Capsule 对齐 */
  static registerCapsule(id: string, kind: OhGlassKind = OhGlassKind.CAPSULE): void {
    LiquidGlassRegistry.register(id, kind, RADIUS_CAPSULE);
  }

  static unregister(id: string): void { LiquidGlassRegistry.unregister(id); }
  static clear(): void { LiquidGlassRegistry.clear(); }

  /** 改参数并立即重画 */
  static setOptions(o: OhGlassOptions): void {
    const e = OhGlassEngineInstance;
    const cur = e.opts;
    if (o.blurSigma !== undefined) { cur.blurSigma = o.blurSigma; }
    if (o.specular !== undefined) { cur.specular = o.specular; }
    if (o.sideGain !== undefined) { cur.sideGain = o.sideGain; }
    if (o.sideDarken !== undefined) { cur.sideDarken = o.sideDarken; }
    if (o.rim !== undefined) { cur.rim = o.rim; }
    if (o.refract !== undefined) { cur.refract = o.refract; }
    if (o.deformRefract !== undefined) { cur.deformRefract = o.deformRefract; }
    if (o.glow !== undefined) { cur.glow = o.glow; }
    if (o.shadow !== undefined) { cur.shadow = o.shadow; }
    if (o.shadowOffset !== undefined) { cur.shadowOffset = o.shadowOffset; }
    if (o.shadowBlur !== undefined) { cur.shadowBlur = o.shadowBlur; }
    if (o.deformAmp !== undefined) { cur.deformAmp = o.deformAmp; }
    if (o.deformRange !== undefined) { cur.deformRange = o.deformRange; }
    e.applyOptions();
    e.pushGlobal();
    e.draw();
  }

  static options(): OhGlassOptions { return OhGlassEngineInstance.opts; }

  /** 布局变化后重算矩形。一般在根容器 .onAreaChange() 里调 */
  static refresh(): void { OhGlassEngineInstance.sync(); }

  /** 内容变了才调（很贵，见 capture 注释） */
  static recapture(): void { OhGlassEngineInstance.capture(); }

  /** 玻璃组件的 onTouch 转发到这里，即可获得凝胶形变 */
  static touch(ev: TouchEvent, id: string): void { OhGlassEngineInstance.onTouch(ev, id); }

  /** 调试读数 */
  static stats(): Float32Array { return OhGlassEngineInstance.stats(); }
  static dispose(): void { OhGlassEngineInstance.dispose(); }
}

/**
 * 全屏玻璃层。每个页面放一个，放在背景之上、内容之下。
 * 尺寸必须铺满整屏 —— 玻璃矩形是用窗口坐标解算的。
 */
@Component
export struct OhGlassSurface {
  /** 首帧就绪回调（此时已完成解算与首次截图） */
  onReady?: () => void;

  build() {
    XComponent({
      id: OhGlassEngineInstance.surfaceId,
      type: XComponentType.SURFACE,
      libraryname: 'liquidglass'
    })
      .width('100%')
      .height('100%')
      // 全屏 surface 位于背景之上：不吞触摸，让下方阅读画布仍能收到手势
      .hitTestBehavior(HitTestMode.None)
      .onLoad(() => {
        const e = OhGlassEngineInstance;
        e.init();
        e.setUIContext(this.getUIContext());
        e.ready = true;
        e.pushGlobal();
        // 首帧布局尚未稳定，等一帧再解算矩形与截图
        setTimeout(() => {
          e.sync();
          e.capture();
          if (this.onReady !== undefined) { this.onReady(); }
        }, 120);
      })
      .onDestroy(() => { OhGlassEngineInstance.ready = false; })
  }
}
