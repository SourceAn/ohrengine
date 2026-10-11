/*
 * LiquidGlassRegistry.ets — 让【已有组件】用上液态玻璃，不新建任何组件
 *
 * 设计要点
 * ========
 * 玻璃不是组件的能力，是【页面】的能力。
 *
 *   ZStack
 *    ├─ 背景内容
 *    ├─ XComponent（全屏，唯一的 GL surface）  ← 引擎在这里一次性画完所有玻璃
 *    └─ 已有的 ArkUI 组件（Text / Row / Column / Image …）← 一个字都不用改结构
 *
 * 每个想用玻璃的组件，只需要一行：
 *     .id('lg:xxx')
 * 再在页面里登记一次：
 *     LiquidGlass.register('lg:xxx', Kind.SYS_PANEL)
 *
 * 矩形由 componentUtils.getRectangleById() 统一取，不需要每个组件写 onAreaChange。
 *
 * 为什么不是"每个组件包一层 GlassContainer"
 * ==========================================
 * 那样做的话：
 *   · N 个组件 = N 个 XComponent = N 个 EGL surface、N 份 FBO、N 次背景截图
 *   · 每份都要独立做两趟全尺寸模糊 —— 10 个组件就是 10 倍模糊开销
 *   · 各自的 vsync 回调互相打架，合成时序不可控
 * 而"页面一份"的话：一次截图、一次模糊、每块玻璃一次 draw。
 *
 * 关于 z 序
 * =========
 * XComponent 必须在【内容之下】，玻璃才能透出背景；
 * 而组件自己的文字/图标在【内容之上】，正常绘制。
 * 所以玻璃容器的 backgroundColor 必须是透明的，不能有底色。
 */

import { componentUtils } from '@kit.ArkUI';

/** 档位，与原生 kKinds 顺序一致 */
export enum LiquidGlassKind {
  SYS_PANEL = 0,
  SYS_MODULE = 1,
  REGULAR = 2,
  CLEAR = 3,
}

/** 半径传 -1 表示胶囊（半径 = 高度一半），与 ArkUI 的 Capsule 一致 */
export const RADIUS_CAPSULE: number = -1;

/** 一块玻璃的登记项 */
export class GlassEntry {
  id: string = '';
  kind: number = LiquidGlassKind.SYS_PANEL;
  radius: number = 24;      // 物理像素
  radiusVp: number = 8;     // 登记时传进来的 vp 值；<0 表示胶囊
  /** 已解算出的矩形（物理像素，左上原点） */
  x: number = 0; y: number = 0; w: number = 0; h: number = 0;
  valid: boolean = false;
  /** 形变（由按压驱动，见 GlassPress） */
  e: number = 0; ev: number = 0; p: number = 0; target: number = 0;
  carried: number = 0;
  pressX: number = 0; pressY: number = 0;
}

export class LiquidGlassRegistry {
  private static entries: Map<string, GlassEntry> = new Map();
  private static dpr: number = 3;
  private static windowOffX: number = 0;
  private static windowOffY: number = 0;

  static setDensity(dpr: number): void { LiquidGlassRegistry.dpr = dpr > 0 ? dpr : 3; }
  static setWindowOrigin(x: number, y: number): void {
    LiquidGlassRegistry.windowOffX = x;
    LiquidGlassRegistry.windowOffY = y;
  }

  /** 登记一块玻璃。组件本身只需要一个 .id() */
  static register(id: string, kind: number, radius: number): void {
    let e = LiquidGlassRegistry.entries.get(id);
    if (e === undefined) {
      e = new GlassEntry();
      e.id = id;
      LiquidGlassRegistry.entries.set(id, e);
    }
    e.kind = kind;
    e.radiusVp = radius;
  }

  static unregister(id: string): void { LiquidGlassRegistry.entries.delete(id); }
  static clear(): void { LiquidGlassRegistry.entries.clear(); }

  static get(id: string): GlassEntry | undefined { return LiquidGlassRegistry.entries.get(id); }
  static all(): GlassEntry[] {
    const out: GlassEntry[] = [];
    LiquidGlassRegistry.entries.forEach((v: GlassEntry) => { out.push(v); });
    return out;
  }

  /**
   * 统一解算所有已登记 id 的矩形。
   *
   * 用 componentUtils.getRectangleById 而不是让每个组件写 onAreaChange：
   *   · 一次拿到 size + windowOffset，不用两处拼
   *   · 组件侧零代码
   *   · 布局怎么变都行，重新解算一次就同步了
   *
   * @param surfaceW/surfaceH XComponent 的尺寸（物理像素）
   * @param surfaceX/surfaceY XComponent 在窗口中的位置（物理像素）
   * @returns 是否有任何一块的矩形发生了变化（变了才需要重画）
   */
  static resolve(surfaceX: number, surfaceY: number, surfaceW: number, surfaceH: number): boolean {
    let changed = false;
    LiquidGlassRegistry.entries.forEach((e: GlassEntry) => {
      let info: componentUtils.ComponentInfo | null = null;
      try {
        info = componentUtils.getRectangleById(e.id);
      } catch (err) {
        info = null;
      }
      if (info === null) {
        if (e.valid) { e.valid = false; changed = true; }
        return;
      }
      // 注意：componentUtils.getRectangleById 返回的【已经是物理像素】，不要再乘 dpr。
      // 曾经乘过一次，结果卡片宽 3961px（屏幕才 1316），玻璃全跑到屏幕外，
      // 表现就是"渲染在跑、draws 正常、但什么都看不见"。
      const cx = Number(info.windowOffset.x) + LiquidGlassRegistry.windowOffX - surfaceX;
      const cy = Number(info.windowOffset.y) + LiquidGlassRegistry.windowOffY - surfaceY;
      const cw = Number(info.size.width);
      const ch = Number(info.size.height);
      if (cw < 2 || ch < 2) {
        if (e.valid) { e.valid = false; changed = true; }
        return;
      }
      if (Math.abs(cx - e.x) > 0.5 || Math.abs(cy - e.y) > 0.5 ||
          Math.abs(cw - e.w) > 0.5 || Math.abs(ch - e.h) > 0.5) {
        changed = true;
      }
      e.x = cx; e.y = cy; e.w = cw; e.h = ch;
      // 半径按 vp 传入、乘 dpr 转物理像素；-1 = 胶囊（高度一半）
      const half = Math.min(cw, ch) * 0.5;
      e.radius = e.radiusVp < 0 ? half : Math.min(e.radiusVp * LiquidGlassRegistry.dpr, half);
      e.valid = true;
      void surfaceW; void surfaceH;
    });
    return changed;
  }

  /* ==================== 形变（弹 + 塑性 + 力传导） ==================== */
  /* 常数与 liquid-glass.html 一致 */
  /**
   * 形变强度上限（px）。
   * 18 太强 —— 范围小强度高看起来像"被针扎"，不是凝胶。
   * 现在默认 7，并且可以实时调。
   */
  static MAXDEF: number = 24;
  /**
   * 形变半径 = 控件【短边】× 这个系数。
   *
   * 试过两个极端，都不对：
   *   · 短边 × 0.26（原值）+ 强度 18  → 又小又深，像被针扎，不是凝胶
   *   · 长边 × 0.85 + 强度 7          → 整个控件 fall≈1，成了【均匀偏移】= 整体缩放，
   *                                     完全没有凹陷，果冻感也没了
   * 正确区间：短边 × 0.50 —— 比原来大一点点，配合低强度就是软凹陷。
   */
  static RADIUS_SCALE: number = 0.50;
  private static readonly KE: number = 0.42;
  private static readonly DE: number = 0.30;
  private static readonly PLASTIC_IN: number = 0.16;
  private static readonly PLASTIC_OUT: number = 0.006;

  /** 命中测试：返回最上面那块被点到的玻璃（列表尾 = 最上层） */
  static hit(px: number, py: number): GlassEntry | null {
    const list = LiquidGlassRegistry.all();
    for (let i = list.length - 1; i >= 0; i--) {
      const e = list[i];
      if (e.valid && px >= e.x && px <= e.x + e.w && py >= e.y && py <= e.y + e.h) { return e; }
    }
    return null;
  }

  /** 按下 */
  static press(e: GlassEntry, px: number, py: number): void {
    e.target = LiquidGlassRegistry.MAXDEF;
    LiquidGlassRegistry.setPress(e, px, py);
  }

  /** 松开 */
  static release(e: GlassEntry): void { e.target = 0; }

  /**
   * 按压点夹紧到玻璃内部。
   * 不夹的话，凹陷会把 SDF 推过零、切穿边界，在玻璃里留下缺口。
   */
  private static setPress(e: GlassEntry, px: number, py: number): void {
    const m = 0.15;
    e.pressX = Math.min(Math.max(px, e.x + e.w * m), e.x + e.w * (1 - m));
    e.pressY = Math.min(Math.max(py, e.y + e.h * m), e.y + e.h * (1 - m));
  }

  /** 一帧物理。返回是否仍在动（false = 可以停表了） */
  static step(pressed: GlassEntry | null): boolean {
    const list = LiquidGlassRegistry.all();
    let moving = false;
    // 力往下传：索引小的在下面
    const prop: number[] = [];
    for (let i = 0; i < list.length; i++) { prop.push(0); }
    if (pressed !== null) {
      const idx = list.indexOf(pressed);
      for (let j = idx - 1; j >= 0; j--) {
        prop[j] = (pressed.e + pressed.p) * Math.pow(0.55, idx - j);
      }
    }
    for (let i = 0; i < list.length; i++) {
      const e = list[i];
      e.ev += (e.target - e.e) * LiquidGlassRegistry.KE;
      e.ev *= (1 - LiquidGlassRegistry.DE);
      e.e += e.ev;
      if (e.target > 0.01) { e.p += (e.e * LiquidGlassRegistry.PLASTIC_IN - e.p) * 0.25; }
      else { e.p *= (1 - LiquidGlassRegistry.PLASTIC_OUT); }
      e.carried += (prop[i] - e.carried) * 0.35;
      if (Math.abs(e.ev) > 0.02 || Math.abs(e.e - e.target) > 0.02 ||
          e.p > 0.05 || e.carried > 0.05) { moving = true; }
    }
    return moving;
  }

  /**
   * 打包成原生要的 12 float/层。
   * 关键：形变量往下传时【按压点也必须一起传】——
   * 只传 amp 不传 press，下层拿到的还是 (0,0)=屏幕原点，
   * 形变中心会跑到画面角落，凹陷从那儿辐射出来，在玻璃上切出直边。
   */
  static pack(into: Float32Array, pressed: GlassEntry | null): number {
    const list = LiquidGlassRegistry.all();
    let n = 0;
    for (let i = 0; i < list.length; i++) {
      const e = list[i];
      if (!e.valid) { continue; }
      const o = n * 12;
      const inherit: boolean = (pressed !== null && list.indexOf(e) < list.indexOf(pressed) &&
                                e.carried > 0.01);
      into[o] = e.x; into[o + 1] = e.y; into[o + 2] = e.w; into[o + 3] = e.h;
      into[o + 4] = e.radius;
      into[o + 5] = e.kind; into[o + 6] = 1;
      into[o + 7] = e.e + e.p;
      into[o + 8] = inherit ? (pressed as GlassEntry).pressX : e.pressX;
      into[o + 9] = inherit ? (pressed as GlassEntry).pressY : e.pressY;
      into[o + 10] = e.carried;
      // 半径按【短边】走（见 RADIUS_SCALE 的注释），夹下限防止极小控件除零
      into[o + 11] = Math.max(Math.min(e.w, e.h) * LiquidGlassRegistry.RADIUS_SCALE, 20);
      n++;
    }
    return n;
  }
}
