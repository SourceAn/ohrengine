/**
 * FlipPageController — 仿真翻页控制器
 *
 * 翻页动画与逻辑忠实采用 STPageFlip（Nodlik/StPageFlip，MIT）：
 *   - 状态机：READ（静态页）/ USER_FOLD（拖拽折叠，页面实时跟随手指）/
 *     FLIPPING（自动翻页动画：松手补全/回弹，或点击/滑动触发完整翻页）；
 *   - 几何：FlipGeometry（1:1 移植 FlipCalculation）——页面绕触摸点旋转，
 *     旋转后页面与书本区域求交得裁剪多边形，progress = |(pos.x - W)/(2W)|；
 *   - 判定：松手 progress ≥ 50% 补全翻页，否则回弹（STPageFlip stopMove 语义，
 *     附加位移感知：快速滑动位移足够大也判翻页）；
 *   - 方向由手势起点半区决定（快速滑动时当前点已偏移，不能用作方向源）。
 *
 * 渲染（直绘，真机验证 2026-08-14 起）：
 *   - transferToImageBitmap 每次调用泄漏 ~70MB（连续翻页触发系统
 *     ResourceLeak(GpuRsLeak) 杀进程）→ 弃用离屏位图，页面内容直接绘制到
 *     带 clip + rotate 变换的 ctx（PageRenderer.drawPageContent 屏上渲染管线）；
 *   - 翻转页可见区域 = 旋转后页面 ∩ 内容区（Sutherland-Hodgman 凸裁剪，恒不退化）；
 *   - clip 路径一律内容区直坐标（与 clip 时变换一致，无 ArkUI 变换语义歧义）；
 *   - 翻转页不做行裁剪（旋转坐标系下行 Y 与内容区 Y 不可比）；底页行裁剪正确，保留；
 *   - 纸背阴影 clip 到翻转页可见多边形（避免半透明"方框"）。
 */

import { OhEngine } from 'ohrengine-ui-render';
import { TurnDirection } from 'ohrengine-common';
import type { PageSlot } from 'ohrengine-common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PageRenderer, ReaderViewport } from './PageRenderer.ets';
import { FlipGeometry, FlipVisualDirection, FlipCorner, FlipPoint, FlipRectPoints } from './FlipGeometry.ets';

const FLIP_TAG: string = 'OhEngine-Flip';

/** 翻页状态 */
export enum FlipPhase {
  READ = 0,
  USER_FOLD = 1,
  FLIPPING = 2,
}

/**
 * 仿真翻页手势适配接口（ReaderGestureController 依赖此接口触发翻页）。
 * 手势控制器只负责"何时触发"，翻页几何/渲染由本控制器负责。
 */
export interface FlipGestureAdapter {
  /** 是否处于翻页过程（折叠或自动动画中） */
  isActive(): boolean;
  /** 是否处于用户拖拽折叠（仅此状态接收 updateFold/endFold） */
  isFolding(): boolean;
  /**
   * 开始拖拽折叠（x/y 为全屏 vp 坐标）。
   * @param startX 手势起点全屏 vp 坐标：翻页方向由"按下位置"决定。
   *               快速滑动时当前触摸点已偏移，若用当前点判定方向会误判
   */
  beginFold(x: number, y: number, startX: number): boolean;
  /** 更新折叠（x/y 为全屏 vp 坐标） */
  updateFold(x: number, y: number): void;
  /** 松手：补全翻页或回弹 */
  endFold(): void;
  /** 播放完整翻页动画（点击/滑动翻页） */
  playFlip(direction: TurnDirection, x: number, y: number): boolean;
}

export interface FlipPageControllerDeps {
  engine: OhEngine;
  pageRenderer: PageRenderer;
  canvasCtx: CanvasRenderingContext2D;
  getViewport: () => ReaderViewport;
  /** 翻页动画完成（页面应真正切换：engine.turnPage + 刷新静态页） */
  onPageTurned: (direction: TurnDirection) => void;
  /** 翻页开始（true，可隐藏控制层/清除选择）/ 结束（false） */
  onFlipStateChange: (active: boolean) => void;
}

/** 快速点击排队项：当前动画完整播完后自动开始的下一个翻页 */
interface PendingFlip {
  direction: TurnDirection;
  x: number;
  y: number;
}

export class FlipPageController implements FlipGestureAdapter {
  private readonly deps: FlipPageControllerDeps;
  private phase: FlipPhase = FlipPhase.READ;
  private geometry: FlipGeometry | null = null;
  private direction: FlipVisualDirection = FlipVisualDirection.FORWARD;
  private corner: FlipCorner = FlipCorner.TOP;
  /** 翻转页内容源（当前页） */
  private flipPageRef: PageSlot | undefined = undefined;
  /** 底页内容源（目标页 toPage） */
  private bottomPageRef: PageSlot | undefined = undefined;
  /** 动画帧句柄（setInterval 驱动，未来可切换 rAF） */
  private animTimer: number = -1;
  private animFrameCount: number = 0;
  private animTotalMs: number = 0;
  private animMaxMs: number = 0;
  /** 当前动画目标是否翻页（连续翻页时按此完成当前动画） */
  private animTurned: boolean = true;
  /** 当前动画起始时间戳 */
  private animStartTime: number = 0;
  /** 当前动画总时长（ms） */
  private animDuration: number = 5000;
  /** 快速点击排队：当前动画完整播完后自动开始的下一个翻页 */
  private pendingFlip: PendingFlip | null = null;
  /** 折叠起点局部 x（位移感知翻页判定用） */
  private foldStartX: number = 0;
  private disposed: boolean = false;
  /** Phase 10: 动画起始时的 pageGeneration（finish 时检测动画期间是否有重排/rebuild） */
  private animStartGeneration: number = 0;
  /** Phase 10: 动画窗口 pin 的章节（动画毕/取消/销毁时 unpin） */
  private animPinChunks: number[] = [];
  /**
   * 持久翻页进度（FlipSession 状态，0 或 1）：
   * 0 = 显示 flip 页（fromPage），1 = 显示 bottom 页（toPage）。
   * FORWARD：0→1；BACK：复用同一 FlipSession 仅 progress 1→0 反向播放——
   * fromPage/toPage、纹理、几何、阴影完全一致，无页面角色重建。
   */
  private flipProgress: number = 0;
  /** 当前动画的 progress 终点（完成时 flipProgress 对齐） */
  private animToProgress: number = 1;
  /** 点击翻页动画统一时长（ms）：单击与快速连点播放速度一致 */
  private readonly FLIP_ANIM_MS: number = 400;
  // 纸背透印 alpha 已移至 PageRenderer（BACK_BLEED_TEXT_ALPHA / BACK_BLEED_IMAGE_ALPHA），
  // 由 drawPageContent(renderMode='backbleed') 内部按内容类型应用，正面渲染恒为 alpha=1.0

  // ── 拖拽渲染节流（性能）：触摸 move 事件频率可高达 120Hz+，而屏幕刷新 ~60Hz。
  //    高频 move 只更新"待渲染点"，按 ≥FOLD_RENDER_INTERVAL 间隔合并渲染，
  //    中间帧丢弃（画面跳到最新位置），消除掉帧/卡顿。endFold 时 flush 兜底。──
  private static readonly FOLD_RENDER_INTERVAL: number = 16;
  private lastFoldRenderTime: number = 0;
  private pendingFoldX: number = 0;
  private pendingFoldY: number = 0;
  private pendingFoldValid: boolean = false;
  /** 渲染帧计数（性能日志降频采样用） */
  private renderFrameCount: number = 0;
  /** geom 采样日志节流（同一 progress 区间 100ms 内不重复打） */
  private lastGeomLogTime: number = 0;

  constructor(deps: FlipPageControllerDeps) {
    this.deps = deps;
  }

  // ==================== 对外 API ====================

  /** 是否处于翻页过程（折叠或动画中） */
  isActive(): boolean {
    return this.phase !== FlipPhase.READ;
  }

  /** 是否处于用户拖拽折叠（仅此状态下接收 updateFold/endFold） */
  isFolding(): boolean {
    return this.phase === FlipPhase.USER_FOLD;
  }

  getPhase(): FlipPhase {
    return this.phase;
  }

  /**
   * 开始拖拽折叠（手指按下后横向拖动时调用）。
   * @param x 当前触摸点全屏 vp 坐标
   * @param y 当前触摸点全屏 vp 坐标
   * @param startX 手势起点全屏 vp 坐标（翻页方向由按下位置决定）
   * @returns 是否成功进入折叠（边界页返回 false）
   */
  beginFold(x: number, y: number, startX: number): boolean {
    if (this.disposed) {
      return false;
    }
    const vp: ReaderViewport = this.deps.getViewport();
    // 触摸点全屏坐标（翻页几何为全屏尺寸）；触发区域仍限内容区
    if (x - vp.margins.left < 0 || y - vp.margins.top - vp.avoidAreaTopVp < 0 ||
      x - vp.margins.left > vp.contentWidth ||
      y - vp.margins.top - vp.avoidAreaTopVp > vp.contentHeight) {
      return false;
    }
    // 方向由"按下位置"决定（快速滑动时当前点已偏移，不能用作方向源）：
    // 右半按下 → 下一页（向左翻）；左半按下 → 上一页（向右翻）
    const dir: FlipVisualDirection = startX >= vp.canvasW / 2
      ? FlipVisualDirection.FORWARD
      : FlipVisualDirection.BACK;
    return this.start(dir, x, y);
  }

  /**
   * 更新折叠（拖拽移动中调用，x/y 为全屏 vp 坐标）。
   * 触摸点 clamp 到几何安全区：calc 对"超出内容区的点"（acos 域外/
   * 角点未拉动）会失败，导致画面冻结在上一帧——clamp 保证 calc 恒成功。
   */
  updateFold(x: number, y: number): void {
    if (this.phase !== FlipPhase.USER_FOLD || this.geometry === null) {
      return;
    }
    const vp: ReaderViewport = this.deps.getViewport();
    // 共享动画模型：progress 反向控制。
    // FORWARD：pos.x = x（向左拖 progress 0→1）；BACK（倒放）：pos.x = x - canvasW
    // （向右拖 progress 1→0，上一页从翻走状态倒放翻回）
    let lx: number = this.direction === FlipVisualDirection.BACK
      ? x - vp.canvasW
      : x;
    // clamp：x 允许拖出屏幕（翻过中线/完全翻出），但避开 calc 失败区
    lx = Math.max(-vp.canvasW, Math.min(vp.canvasW - 2, lx));
    const ly: number = Math.max(1, Math.min(vp.canvasH - 1, y));
    // ── 渲染节流：距上次渲染 < 16ms 时只记录最新点，不立即渲染。
    //    move 事件可能 120Hz+，逐帧渲染超出屏幕刷新能力造成掉帧；
    //    合并到 ≥16ms 间隔渲染，画面直接跳到最新位置（endFold flush 兜底）。
    const now: number = Date.now();
    if (now - this.lastFoldRenderTime < FlipPageController.FOLD_RENDER_INTERVAL) {
      this.pendingFoldX = lx;
      this.pendingFoldY = ly;
      this.pendingFoldValid = true;
      return;
    }
    this.lastFoldRenderTime = now;
    this.pendingFoldValid = false;
    this.updateGeometry({ x: lx, y: ly });
  }

  /**
   * 松手：翻页进度 >= 50% 补全翻页动画，否则回弹（STPageFlip stopMove 语义）。
   * 共享动画模型：BACK 为倒放（progress 1→0），判定与动画目标反向——
   * progress 小（接近 0）= 翻回完成 → 补全到 0；progress 大 = 回弹到 1（回当前页）。
   * 位移感知：快速滑动时位置判定可能不足，手势总位移足够大也判定。
   */
  endFold(): void {
    if (this.phase !== FlipPhase.USER_FOLD || this.geometry === null) {
      return;
    }
    // flush 节流期间积压的最新触摸点：确保判定基于最终位置（且画面已跟上）
    if (this.pendingFoldValid) {
      this.pendingFoldValid = false;
      this.updateGeometry({ x: this.pendingFoldX, y: this.pendingFoldY });
    }
    const pos: FlipPoint = this.geometry.getPosition();
    const vp: ReaderViewport = this.deps.getViewport();
    const progress: number = this.geometry.getFlippingProgress();
    const totalDx: number = pos.x - this.foldStartX;
    const edgeY: number = this.corner === FlipCorner.BOTTOM ? vp.canvasH : 0;
    if (this.direction === FlipVisualDirection.BACK) {
      // 倒放：progress 小 = 翻回完成；向右拖位移大也判翻回
      const shouldTurnBack: boolean = progress <= 50 ||
        (totalDx > vp.contentWidth * 0.35 && progress <= 80);
      if (shouldTurnBack) {
        // 补全翻回：progress → 0（触摸点 → +canvasW，上一页平放）
        this.animateTo(pos, { x: vp.canvasW, y: edgeY }, true);
      } else {
        // 回弹：progress → 1（触摸点 → -canvasW，回到当前页）
        this.animateTo(pos, { x: -vp.canvasW, y: edgeY }, false);
      }
    } else {
      const shouldTurn: boolean = progress >= 50 ||
        (totalDx < -vp.contentWidth * 0.35 && progress >= 20);
      if (shouldTurn) {
        this.animateTo(pos, { x: -vp.canvasW, y: edgeY }, true);
      } else {
        this.animateTo(pos, { x: vp.canvasW, y: edgeY }, false);
      }
    }
  }

  /**
   * 播放完整翻页动画（点击翻页 / 滑动翻页）。
   * @param direction 视觉翻页方向（与阅读器手势语义一致）
   * @param x 触发点全屏 vp 坐标（决定从哪个角翻起）
   * @param y 触发点全屏 vp 坐标
   * @returns 是否成功启动（边界页返回 false）
   */
  playFlip(direction: TurnDirection, x: number, y: number): boolean {
    if (this.disposed) {
      return false;
    }
    if (this.phase === FlipPhase.FLIPPING) {
      // 动画中再次点击：不打断当前动画（统一速度完整播放），
      // 本翻页排队，当前动画播完后自动开始
      const pf: PendingFlip = { direction: direction, x: x, y: y };
      this.pendingFlip = pf;
      return true;
    }
    if (this.phase === FlipPhase.USER_FOLD) {
      this.cancel();
    }
    return this.startFlip(direction, x, y);
  }

  /** 启动一次翻页（READ 态调用；排队项在 finishFlip 后经此启动） */
  private startFlip(direction: TurnDirection, x: number, y: number): boolean {
    const vp: ReaderViewport = this.deps.getViewport();
    const corner: FlipCorner = y < vp.canvasH / 2 ? FlipCorner.TOP : FlipCorner.BOTTOM;
    return this.start(direction === TurnDirection.FORWARD
      ? FlipVisualDirection.FORWARD
      : FlipVisualDirection.BACK, undefined, undefined, corner, direction);
  }

  /**
   * 绘制当前翻页帧（折叠/动画期间由控制器驱动，动画帧回调也调用）。
   * STPageFlip 渲染模型：
   *   1. 底页（目标页）整页直绘（翻转页覆盖处自然遮挡）+ 行裁剪（内容区坐标，正确）；
   *   2. 翻转页（当前页）：clip 到"旋转后页面 ∩ 内容区"凸多边形（S-H，恒不退化），
   *      translate(cornerPt) + rotate(angle) 后直绘页面内容（旋转坐标系，不行裁剪）；
   *   3. 阴影：外阴影（翻转页投在底页上的投影）+ 内阴影（纸背，clip 到翻转页可见
   *      多边形而非整个旋转矩形，避免半透明"方框"）。
   * 全部 clip 路径用内容区直坐标（路径建立与 clip 时变换一致）。
   */
  render(): void {
    if (this.disposed) {
      return;
    }
    const vp: ReaderViewport = this.deps.getViewport();
    const ctx: CanvasRenderingContext2D = this.deps.canvasCtx;
    const theme = this.deps.engine.getThemeManager().currentTheme;
    // 性能计时（D）：统计 render 总耗时、翻起区/阴影各段耗时
    const frameT0: number = Date.now();
    let foldMs: number = 0;
    let shadowMs: number = 0;
    ctx.save();
    if (this.geometry === null || this.phase === FlipPhase.READ) {
      // 无翻页：清屏兜底（静态页由 renderPage 负责，此处仅防画布残留）
      ctx.fillStyle = theme.backgroundColor;
      ctx.fillRect(0, 0, vp.canvasW, vp.canvasH);
      ctx.restore();
      return;
    }
    const cw: number = vp.canvasW;      // 全屏尺寸（翻页几何坐标）
    const ch: number = vp.canvasH;
    const ox: number = vp.margins.left; // 内容区偏移（正文绘制位置）
    const oy: number = vp.margins.top + vp.avoidAreaTopVp;
    const cph: number = vp.contentHeight;

    // 1. 静止层（FlipSession 方向无关）：恒为 flip 页（fromPage）。
    //    progress=0 时 fromPage 平放显示；progress 增大时 fromPage 翻起；
    //    progress=1 时 fromPage 翻走、底部页（toPage）全屏显示。
    if (this.flipPageRef !== undefined) {
      ctx.save();
      ctx.fillStyle = theme.backgroundColor;
      ctx.fillRect(0, 0, cw, ch);
      ctx.translate(ox, oy);
      this.deps.pageRenderer.drawPageContent(ctx, this.flipPageRef, 'vp', 1, 0, cph);
      ctx.restore();
    }

    // 2. 底部页（目标页）：STPageFlip drawBottomPage——clip 到翻转页覆盖区
    //    （getBottomClipArea），翻起后露出的目标页内容。
    //    翻页进度 progress 为唯一驱动：FORWARD 目标=下一页（0→1），
    //    BACK 目标=当前页（1→0 倒放时上一页翻回、当前页在底部露出）。
    if (this.bottomPageRef !== undefined && this.geometry !== null) {
      const bottomClip: (FlipPoint | null)[] = this.geometry.getBottomClipArea();
      const poly: FlipPoint[] = [];
      for (const p of bottomClip) {
        if (p !== null) {
          poly.push(p);
        }
      }
      if (poly.length >= 3) {
        // 性能：底部页可见区 = bottomClip 包围盒 Y 范围，仅绘制该行段。
        // 翻页早期 bottomClip 只露出底部页一小条，全页绘制 90% 行是纯浪费。
        let bMinY: number = 1e9;
        let bMaxY: number = -1e9;
        for (const p of poly) {
          bMinY = Math.min(bMinY, p.y);
          bMaxY = Math.max(bMaxY, p.y);
        }
        // poly 为全屏坐标；drawPageContent 在 translate(ox,oy) 后以内容区坐标
        // 绘制，visibleY 需换算回内容区，并 clamp 到 [0, cph]
        const vy0: number = Math.max(0, Math.min(cph, bMinY - oy));
        const vy1: number = Math.max(0, Math.min(cph, bMaxY - oy));
        ctx.save();
        this.clipPolygon(ctx, poly);
        ctx.fillStyle = theme.backgroundColor;
        ctx.fillRect(0, 0, cw, ch);
        ctx.translate(ox, oy);
        this.deps.pageRenderer.drawPageContent(ctx, this.bottomPageRef, 'vp', 1, vy0, vy1);
        ctx.restore();
      }
    }

    // 2.5 外投影阴影
    if (this.geometry !== null) {
      const s1: number = Date.now();
      this.drawOuterShadow(ctx, cw, ch);
      shadowMs = Date.now() - s1;
    }

    // 3. 翻起区（STPageFlip 翻转页几何）：A 页内容绕 activeCorner 旋转
    //    （源码 setPosition(getActiveCorner()) + setAngle(getAngle())），
    //    clip 到 getFlippingClipArea（旋转后页面 ∩ 书区，源码语义；退化时
    //    用 S-H 凸裁剪兜底）。
    if (this.flipPageRef !== undefined) {
      const flipClip: (FlipPoint | null)[] = this.geometry.getFlippingClipArea();
      let visPoly: FlipPoint[] = [];
      for (const p of flipClip) {
        if (p !== null) {
          visPoly.push(p);
        }
      }
      if (visPoly.length < 3) {
        visPoly = this.clipQuadToContentRect(this.geometry.getRect(), cw, ch);
      }
      ctx.save();
      if (visPoly.length >= 3 && this.clipPolygon(ctx, visPoly)) {
        // 不透明纸张底色：基于 clip 路径直接 fill()（全屏坐标，确保翻起区
        // 完全覆盖底层页面，不依赖变换后的大矩形 fillRect）
        ctx.fillStyle = theme.backgroundColor;
        ctx.fill();
        const s0: number = Date.now();
        this.drawFoldedPage(ctx, cw, ch);
        foldMs = Date.now() - s0;
      }
      ctx.restore();
    }

    // 4. 折痕内阴影
    if (this.geometry !== null) {
      const s2: number = Date.now();
      this.drawCreaseShadow(ctx, cw, ch);
      shadowMs = Date.now() - s2;
    }

    ctx.restore();
    // 性能日志降频：拖拽 move 高频（120Hz+），每帧 hilog 本身是开销。
    // renderMs 每 15 帧采样一次；geom 采样同一 progress 区间 100ms 节流。
    this.renderFrameCount++;
    const prog: number = this.geometry !== null ? this.geometry.getFlippingProgress() : 0;
    if (this.renderFrameCount % 15 === 0) {
      hilog.info(0x0000, FLIP_TAG, 'renderMs total=%{public}d fold=%{public}d shadow=%{public}d progress=%{public}d',
        Date.now() - frameT0, foldMs, shadowMs, Math.round(prog));
    }
    // 几何参数采样（progress 50%/90% 附近）
    const nowMs: number = Date.now();
    if (this.geometry !== null && nowMs - this.lastGeomLogTime > 100 &&
      (prog > 45 && prog < 55 || prog > 85 && prog < 95)) {
      this.lastGeomLogTime = nowMs;
      const center: FlipPoint = this.geometry.getActiveCorner();
      const angleDeg: number = Math.round(this.geometry.getAngle() * 180 / Math.PI);
      const rect = this.geometry.getRect();
      const ss = this.geometry.getShadowStartPoint();
      const ssX: number = ss !== null ? Math.round(ss.x) : 0;
      const ssY: number = ss !== null ? Math.round(ss.y) : 0;
      const saDeg: number = Math.round(this.geometry.getShadowAngle() * 180 / Math.PI);
      hilog.info(0x0000, FLIP_TAG, 'geom progress=%{public}d angle=%{public}ddeg center=(%{public}d,%{public}d) ' +
        'rectTL=(%{public}d,%{public}d) rectBR=(%{public}d,%{public}d) ' +
        'shadowStart=(%{public}d,%{public}d) shadowAngle=%{public}ddeg',
        Math.round(prog), angleDeg, Math.round(center.x), Math.round(center.y),
        Math.round(rect.topLeft.x), Math.round(rect.topLeft.y),
        Math.round(rect.bottomRight.x), Math.round(rect.bottomRight.y),
        ssX, ssY, saDeg);
    }
  }

  /** 取消当前翻页（窗口尺寸变化/页面销毁前调用），回到静态页 */
  cancel(): void {
    this.stopAnimation();
    this.unpinSession();
    this.deps.engine.setUserAnimating(false);
    this.pendingFlip = null;
    this.phase = FlipPhase.READ;
    this.geometry = null;
    this.deps.onFlipStateChange(false);
    this.deps.pageRenderer.renderPage();
  }

  /** 释放：停止动画定时器 */
  dispose(): void {
    this.disposed = true;
    this.stopAnimation();
    this.unpinSession();
    this.deps.engine.setUserAnimating(false);
    this.pendingFlip = null;
    this.flipPageRef = undefined;
    this.bottomPageRef = undefined;
  }

  // ==================== 内部实现 ====================

  /**
   * 启动翻页过程。
   * @param visDir 视觉方向
   * @param lx 折叠起点（内容区坐标；playFlip 时传 undefined）
   * @param ly 折叠起点（内容区坐标；playFlip 时传 undefined）
   * @param cornerOverride 指定翻页角（playFlip 用）
   * @param turnDir 页码导航方向（playFlip 用；折叠时由 visDir 推导）
   */
  private start(visDir: FlipVisualDirection, lx: number | undefined, ly: number | undefined,
    cornerOverride?: FlipCorner, turnDirOverride?: TurnDirection): boolean {
    if (this.disposed) {
      return false;
    }
    // 新翻页开始：清掉可能残留的排队项（折叠打断动画等场景）
    this.pendingFlip = null;
    const vp: ReaderViewport = this.deps.getViewport();
    const turnDir: TurnDirection = turnDirOverride ?? (visDir === FlipVisualDirection.FORWARD
      ? TurnDirection.FORWARD
      : TurnDirection.BACKWARD);
    this.stopAnimation();
    this.direction = visDir;
    // Phase 10: 记录动画起始代次（检测动画期间 rebuild/reflow → 页面代际变更）
    this.animStartGeneration = this.deps.engine.getPageGeneration();
    if (cornerOverride !== undefined) {
      this.corner = cornerOverride;
    } else {
      this.corner = (ly ?? 0) < vp.contentHeight / 2 ? FlipCorner.TOP : FlipCorner.BOTTOM;
    }
    // ── FlipSession 规则：复用 or 滑窗，页面角色与方向解耦 ──
    // 持久状态：flipProgress=0 显示 flipPageRef(from)，=1 显示 bottomPageRef(to)。
    // FORWARD：progress 0→1；BACK：复用同一 session 仅 1→0 反向播放。
    // 仅当当前显示页不在 session 端点时（连续翻页/翻回），才滑窗更新 from/to。
    if (turnDir === TurnDirection.FORWARD) {
      if (this.flipProgress >= 0.99 && this.bottomPageRef !== undefined) {
        // 当前显示 toPage（连续翻下一页）：滑窗 {to, next(to)}
        const next: PageSlot | undefined = this.deps.engine.peekPage(turnDir);
        if (next === undefined) {
          return false;
        }
        this.flipPageRef = this.bottomPageRef;
        this.bottomPageRef = next;
      } else {
        if (!this.preparePages(turnDir)) {
          return false;
        }
      }
      this.flipProgress = 0;
      this.animToProgress = 1;
    } else {
      if (this.flipProgress <= 0.01 && this.flipPageRef !== undefined) {
        // 当前显示 fromPage（翻回上一页）：新 session {prev(from), from}
        const prev: PageSlot | undefined = this.deps.engine.peekPage(turnDir);
        if (prev === undefined) {
          return false;
        }
        this.logReadyCheck(turnDir, this.flipPageRef, prev);
        this.bottomPageRef = this.flipPageRef;
        this.flipPageRef = prev;
      } else if (this.flipPageRef === undefined) {
        // Phase 10 S2 修复：首次反向翻页（无 FlipSession）必须建立 {prev(from), cur(to)} 会话，
        // 否则 render() 因 flipPageRef/bottomPageRef 均 undefined 只画背景（空白动画帧）。
        const curShown: PageSlot | undefined = this.deps.engine.getCurrentPage();
        const prevTo: PageSlot | undefined = this.deps.engine.peekPage(turnDir);
        if (curShown === undefined || prevTo === undefined) {
          return false;
        }
        this.logReadyCheck(turnDir, curShown, prevTo);
        this.flipPageRef = prevTo;
        this.bottomPageRef = curShown;
      } else {
        // 当前显示 toPage（reuse 上一会话反向播放）：from/to 无需变更
        const prevTo: PageSlot | undefined = this.deps.engine.peekPage(turnDir);
        if (prevTo === undefined) {
          return false;
        }
        this.logReadyCheck(turnDir, this.deps.engine.getCurrentPage(), prevTo);
      }
      this.flipProgress = 1;
      this.animToProgress = 0;
    }
    // Phase 10: 动画窗口 pin（L3 不逐出动画中章节）——在任何整页动画/折叠前生效
    this.pinSession();
    // Phase 12: 置位「用户动画进行中」→ 后台 reflow 推迟（不污染动画帧）
    this.deps.engine.setUserAnimating(true);
    // 共享动画模型：几何路径单一（FORWARD 路径），同一套形变/背面/阴影。
    this.geometry = new FlipGeometry(FlipVisualDirection.FORWARD, this.corner, vp.canvasW, vp.canvasH);
    this.deps.onFlipStateChange(true);
    if (lx !== undefined && ly !== undefined) {
      this.phase = FlipPhase.USER_FOLD;
      // 共享动画模型：progress 反向控制。BACK（倒放）pos.x = lx - canvasW
      //（向右拖 progress 1→0）；FORWARD pos.x = lx（向左拖 progress 0→1）
      const localX: number = this.direction === FlipVisualDirection.BACK
        ? lx - vp.canvasW
        : lx;
      // clamp 到几何安全区（同 updateFold），保证首次 calc 成功
      const safeX: number = Math.max(-vp.canvasW, Math.min(vp.canvasW - 2, localX));
      const safeY: number = Math.max(1, Math.min(vp.canvasH - 1, ly));
      this.foldStartX = safeX;
      this.updateGeometry({ x: safeX, y: safeY });
    } else {
      // 点击/滑动翻页：STPageFlip flip() 路径（同一几何路径）
      this.phase = FlipPhase.FLIPPING;
      const topMargin: number = vp.canvasH / 10;
      const yStart: number = this.corner === FlipCorner.BOTTOM
        ? vp.canvasH - topMargin
        : topMargin;
      const startPt: FlipPoint = { x: vp.canvasW - topMargin, y: yStart };
      const destPt: FlipPoint = {
        x: -vp.canvasW,
        y: this.corner === FlipCorner.BOTTOM ? vp.canvasH : 0
      };
      if (this.direction === FlipVisualDirection.BACK) {
        // 倒放：progress 1→0（触摸点从翻走态 -canvasW 回到平放态 +canvasW）
        this.animateTo(destPt, startPt, true);
      } else {
        this.animateTo(startPt, destPt, true);
      }
    }
    return true;
  }

  /**
   * 卷起的当前页（A）纸背：不透明纸面 + A 页内容绕翻转锚点旋转
   * （STPageFlip 翻转页几何，内容随动画卷曲）。
   * 纸背 = 正面镜像：内容水平翻转（从背面看左右颠倒，镜像轴 = 内容区中心）。
   * 不透明度 1：纸背为"当前页卷曲景象"，无半透明浅白遮罩。
   */
  private drawFoldedPage(ctx: CanvasRenderingContext2D, cw: number, ch: number): void {
    const page: PageSlot | undefined = this.flipPageRef;
    if (page === undefined || this.geometry === null) {
      return;
    }
    const vp: ReaderViewport = this.deps.getViewport();
    const ox: number = vp.margins.left;
    const oy: number = vp.margins.top + vp.avoidAreaTopVp;
    const center: FlipPoint = this.geometry.getActiveCorner();
    const angle: number = this.geometry.getAngle();
    // ⚠ 隔离 foldedPage 的 canvas 状态：整体 save/restore + 显式复位 globalAlpha，
    //    防止外部/行级半透明残留导致透明合成（薄膜/双重合成）
    ctx.save();
    ctx.globalAlpha = 1.0;
    ctx.globalCompositeOperation = 'source-over';
    // 全屏坐标系：绕 position 旋转（STPageFlip soft 页：translate(pos) rotate(angle)）
    ctx.translate(center.x, center.y);
    ctx.rotate(angle);
    // 纸背 = 正面镜像：内容水平翻转（镜像轴 = 内容区中心线）
    const mirrorX: number = ox + vp.contentWidth / 2;
    ctx.translate(2 * mirrorX, 0);
    ctx.scale(-1, 1);
    // 纸张底色已由 render() 层3 基于 clip 路径 fill() 绘制（不透明，覆盖翻起区）。
    // 此处仅绘制"弱透印油墨"（BackBleed Pass）：drawPageContent 内部按内容类型
    // 应用透印 alpha（文字 0.15、图片 0.10），正面渲染仍为 alpha=1.0
    ctx.translate(ox, oy);
    this.deps.pageRenderer.drawPageContent(ctx, page, 'vp', 1, 0, vp.contentHeight, false, false, 'backbleed');
    ctx.restore();
  }

  /**
   * Phase 10 诊断：翻页意图前的 N-1/N+1 就绪快照。
   * 输出（空间分隔、数值化，便于 grep/脚本解析）：
   *   P10 intent dir=±1 gen=<pageGeneration> cur=<描述> target=<描述> <imgDec=decoded/total>
   */
  private logReadyCheck(turnDir: TurnDirection, cur: PageSlot | undefined,
    target: PageSlot | undefined): void {
    const curS: string = cur !== undefined ? this.deps.engine.describePage(cur) : 'cur=none';
    const tarS: string = target !== undefined ? this.deps.engine.describePage(target) : 'target=none';
    const imgS: string = target !== undefined ? this.deps.pageRenderer.describePageImages(target) : 'imgDec=0/0';
    hilog.info(0x0000, FLIP_TAG, 'P10 intent dir=%{public}d gen=%{public}d %{public}s %{public}s %{public}s',
      turnDir === TurnDirection.FORWARD ? 1 : -1, this.deps.engine.getPageGeneration(),
      curS, tarS, imgS);
  }

  /** Phase 10: pin 动画窗口涉及的章节（去重；先 unpin 旧窗口防泄漏） */
  private pinSession(): void {
    this.unpinSession();
    const chunks: number[] = [];
    if (this.flipPageRef !== undefined && this.flipPageRef.chunkIndex >= 0 &&
      chunks.indexOf(this.flipPageRef.chunkIndex) < 0) {
      chunks.push(this.flipPageRef.chunkIndex);
    }
    if (this.bottomPageRef !== undefined && this.bottomPageRef.chunkIndex >= 0 &&
      chunks.indexOf(this.bottomPageRef.chunkIndex) < 0) {
      chunks.push(this.bottomPageRef.chunkIndex);
    }
    this.animPinChunks = chunks;
    if (chunks.length > 0) {
      this.deps.engine.pinChapters(chunks);
    }
  }

  /** Phase 10: 解除动画窗口 pin（finishFlip/cancel/dispose 均调用） */
  private unpinSession(): void {
    if (this.animPinChunks.length === 0) {
      return;
    }
    this.deps.engine.unpinChapters(this.animPinChunks);
    this.animPinChunks = [];
  }

  /** 保存翻页页内容源（PageSlot 引用，动画帧直绘用） */
  private preparePages(turnDir: TurnDirection): boolean {
    const cur: PageSlot | undefined = this.deps.engine.getCurrentPage();
    if (cur === undefined) {
      return false;
    }
    const target: PageSlot | undefined = this.deps.engine.peekPage(turnDir);
    if (target === undefined) {
      return false;
    }
    this.logReadyCheck(turnDir, cur, target);
    // FlipSession：fromPage=当前显示页(cur)，toPage=目标页(target)。
    // FORWARD 使用（progress 0→1）；BACK 复用已有 session 仅 progress 反向。
    this.flipPageRef = cur;
    this.bottomPageRef = target;
    hilog.info(0x0000, FLIP_TAG, 'preparePages ok dir=%{public}d', this.direction);
    return true;
  }

  /** 用触摸点更新几何并重绘一帧（calc 失败保持上一帧，不冻结画面） */
  private updateGeometry(p: FlipPoint): void {
    if (this.geometry === null) {
      return;
    }
    if (this.geometry.calc(p)) {
      this.render();
    }
  }

  /** 触摸点线性插值的翻页动画（STPageFlip animateFlippingTo：GetCordsFromTwoPoint 均匀采样，时长按 getAnimationDuration） */
  private animateTo(start: FlipPoint, dest: FlipPoint, isTurned: boolean): void {
    if (this.disposed) {
      return;
    }
    this.phase = FlipPhase.FLIPPING;
    this.stopAnimation();
    this.animTurned = isTurned;
    this.animFrameCount = 0;
    this.animTotalMs = 0;
    this.animMaxMs = 0;
    // 点击翻页动画统一时长（ms）：单击与快速连点播放速度一致
    const duration: number = this.FLIP_ANIM_MS;
    this.animDuration = duration;
    this.animStartTime = Date.now();
    const startTime: number = this.animStartTime;
    hilog.info(0x0000, FLIP_TAG, 'animateTo start=(%{public}d,%{public}d) dest=(%{public}d,%{public}d) turned=%{public}d',
      Math.round(start.x), Math.round(start.y), Math.round(dest.x), Math.round(dest.y), isTurned ? 1 : 0);
    const tick = (now: number): void => {
      if (this.disposed) {
        this.stopAnimation();
        return;
      }
      // 读取实例字段：加速播放会前移 animStartTime，此处动态生效
      const t: number = Math.min(1, (Date.now() - this.animStartTime) / this.animDuration);
      // STPageFlip 动画 = 触摸点线性插值（GetCordsFromTwoPoint 均匀采样），
      // 与源码一致，保证同一时刻几何/画面与 demo 相同
      const e: number = t;
      this.animFrameCount++;
      // 帧耗时统计（渲染性能量化）
      const frameStart: number = Date.now();
      this.updateGeometry({
        x: start.x + (dest.x - start.x) * e,
        y: start.y + (dest.y - start.y) * e
      });
      const frameMs: number = Date.now() - frameStart;
      this.animTotalMs += frameMs;
      if (frameMs > this.animMaxMs) {
        this.animMaxMs = frameMs;
      }
      if (t >= 1) {
        this.stopAnimation();
        this.finishFlip(isTurned);
      }
    };
    this.animTimer = setInterval(tick, 16);
  }

  /** 动画结束：完成翻页（通知上层真正切换页面）或回弹（重绘静态页） */
  private finishFlip(isTurned: boolean): void {
    this.phase = FlipPhase.READ;
    const wasTurned: boolean = isTurned;
    // Phase 10: 动画窗口保护结束 → 解除 pin
    this.unpinSession();
    // Phase 12: 复位「用户动画进行中」→ 后台 reflow 恢复
    this.deps.engine.setUserAnimating(false);
    // Phase 10: 动画期间代际变更检测（R1 竞态证据：动画播放中 rebuild/reflow 计数）
    const endGen: number = this.deps.engine.getPageGeneration();
    const mutated: number = endGen !== this.animStartGeneration ? 1 : 0;
    // FlipSession 持久状态对齐动画终点（progress 0 或 1）
    this.flipProgress = this.animToProgress;
    this.geometry = null;
    const avgMs: number = this.animFrameCount > 0 ? this.animTotalMs / this.animFrameCount : 0;
    hilog.info(0x0000, FLIP_TAG,
      'finishFlip turned=%{public}d progress=%{public}d frames=%{public}d avgMs=%{public}d maxMs=%{public}d gen=%{public}d->%{public}d mut=%{public}d',
      wasTurned ? 1 : 0, this.flipProgress, this.animFrameCount, Math.round(avgMs), this.animMaxMs,
      this.animStartGeneration, endGen, mutated);
    this.animFrameCount = 0;
    this.animTotalMs = 0;
    this.animMaxMs = 0;
    if (wasTurned) {
      // engine 当前页对齐显示页：progress=1 → 显示 toPage（FORWARD）；
      // progress=0 → 显示 fromPage（BACKWARD）
      this.deps.onPageTurned(this.flipProgress >= 0.99
        ? TurnDirection.FORWARD
        : TurnDirection.BACKWARD);
    } else {
      this.deps.onFlipStateChange(false);
      this.deps.pageRenderer.renderPage();
    }
    // 快速点击排队项：当前动画完整播完后自动开始下一个翻页
    if (this.pendingFlip !== null) {
      const pf = this.pendingFlip;
      this.pendingFlip = null;
      this.startFlip(pf.direction, pf.x, pf.y);
    }
  }

  private stopAnimation(): void {
    if (this.animTimer > 0) {
      clearInterval(this.animTimer);
      this.animTimer = -1;
    }
  }

  /**
   * 用多边形裁剪（内容区直坐标：路径在 translate(内容区原点) 下建立，
   * clip() 与路径建立使用同一变换，无 ArkUI clip 变换语义歧义）。
   * @returns false = 多边形退化（<3 顶点，不可见），调用方应跳过绘制
   */
  private clipPolygon(ctx: CanvasRenderingContext2D, poly: FlipPoint[]): boolean {
    if (poly.length < 3) {
      return false;
    }
    ctx.beginPath();
    ctx.moveTo(poly[0].x, poly[0].y);
    for (let i = 1; i < poly.length; i++) {
      ctx.lineTo(poly[i].x, poly[i].y);
    }
    ctx.closePath();
    ctx.clip();
    return true;
  }

  /**
   * 凸四边形与内容区矩形的交集（Sutherland-Hodgman 半平面裁剪）。
   * 旋转后页面与内容区均为凸集，交集恒为凸多边形（顶点顺序正确、无退化）。
   */
  private clipQuadToContentRect(quad: FlipRectPoints, pw: number, ph: number): FlipPoint[] {
    let poly: FlipPoint[] = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft];
    // 内容区四条边（半平面：内侧为合法侧）
    poly = this.clipPolyByHalfPlane(poly, 0, 0, 1, 0);    // x >= 0
    poly = this.clipPolyByHalfPlane(poly, 0, 0, 0, 1);    // y >= 0
    poly = this.clipPolyByHalfPlane(poly, pw, 0, -1, 0);  // x <= pw
    poly = this.clipPolyByHalfPlane(poly, 0, ph, 0, -1);  // y <= ph
    return poly;
  }

  /** 半平面裁剪：保留 (p - origin)·normal >= 0 的顶点，边穿越处求交点 */
  private clipPolyByHalfPlane(poly: FlipPoint[], ox: number, oy: number,
    nx: number, ny: number): FlipPoint[] {
    if (poly.length === 0) {
      return poly;
    }
    const out: FlipPoint[] = [];
    for (let i = 0; i < poly.length; i++) {
      const cur: FlipPoint = poly[i];
      const prev: FlipPoint = poly[(i + poly.length - 1) % poly.length];
      const curIn: boolean = (cur.x - ox) * nx + (cur.y - oy) * ny >= 0;
      const prevIn: boolean = (prev.x - ox) * nx + (prev.y - oy) * ny >= 0;
      if (curIn !== prevIn) {
        // 边与裁剪线相交：参数化求交点
        const denom: number = (cur.x - prev.x) * nx + (cur.y - prev.y) * ny;
        if (denom !== 0) {
          const t: number = ((ox - prev.x) * nx + (oy - prev.y) * ny) / denom;
          out.push({ x: prev.x + (cur.x - prev.x) * t, y: prev.y + (cur.y - prev.y) * t });
        }
      }
      if (curIn) {
        out.push(cur);
      }
    }
    return out;
  }

  /**
   * 外投影阴影：纸张投射到底层页面上的阴影（在翻起页之前绘制，不覆盖纸背）。
   * 使用 radialGradient 二维距离衰减场（径向同时衰减长度和宽度，无矩形硬边/三角灰块），
   * clip = visPoly 沿折痕法线平移 projLen 的投影剪影（拉伸体）。
   */
  private drawOuterShadow(ctx: CanvasRenderingContext2D, pw: number, ph: number): void {
    if (this.geometry === null) { return; }
    const progress: number = this.geometry.getFlippingProgress();
    if (progress <= 0) { return; }
    const shadowStart: FlipPoint | null = this.geometry.getShadowStartPoint();
    if (shadowStart === null) { return; }
    const shadowAngle: number = this.geometry.getShadowAngle();
    const t: number = progress / 100;
    const opacity: number = 0.5 * (1 - t) * (1 - t);
    // 卷曲几何
    const visPoly: FlipPoint[] = this.clipQuadToContentRect(this.geometry.getRect(), pw, ph);
    if (visPoly.length < 3) { return; }
    let minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
    for (const p of visPoly) {
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    }
    const curlH: number = maxY - minY;
    const angle: number = this.geometry.getAngle();
    const cosA: number = Math.abs(Math.cos(angle));
    const curvatureFactor: number = 0.35 + 0.65 * cosA;
    const normalAngle: number = Math.PI + shadowAngle + Math.PI / 2;
    const nx: number = Math.cos(normalAngle);
    const ny: number = Math.sin(normalAngle);
    const lightDot: number = nx * (-0.7071) + ny * (-0.7071);
    const lightFactor: number = 0.7 + 0.3 * (1 - lightDot) / 2;
    const projLen: number = Math.max(20, curlH * curvatureFactor * lightFactor);
    // ── 外阴影：二维径向距离衰减场（非 linear 宽度均匀），
    //     clip = visPoly 拉伸体（投影剪影）
    ctx.save();
    const shiftX: number = Math.cos(normalAngle) * projLen;
    const shiftY: number = Math.sin(normalAngle) * projLen;
    const shadowPoly: FlipPoint[] = [];
    for (const p of visPoly) { shadowPoly.push({ x: p.x, y: p.y }); }
    for (const p of visPoly) { shadowPoly.push({ x: p.x + shiftX, y: p.y + shiftY }); }
    if (this.clipPolygon(ctx, shadowPoly)) {
      ctx.translate(shadowStart.x, shadowStart.y);
      ctx.rotate(normalAngle);
      // radial 二维距离衰减：折痕(0,0) 最深 → 径向衰减到 projLen（长度&宽度同时柔化）
      const outer: CanvasGradient = ctx.createRadialGradient(0, 0, 0, 0, 0, projLen);
      outer.addColorStop(0, 'rgba(0, 0, 0, ' + opacity + ')');
      outer.addColorStop(0.55, 'rgba(0, 0, 0, ' + (opacity * 0.30) + ')');
      outer.addColorStop(1, 'rgba(0, 0, 0, 0)');
      ctx.fillStyle = outer;
      ctx.fillRect(-pw, -ph, pw * 3, ph * 3);
    }
    ctx.restore();
  }

  /**
   * 折痕内阴影：纸张自身卷曲区域的自遮挡阴影（在翻起页之后绘制，纸背局部）。
   * clip 到翻起页可见多边形，折痕附近窄带，强度随背面光照（背光折痕更深）。
   */
  private drawCreaseShadow(ctx: CanvasRenderingContext2D, pw: number, ph: number): void {
    if (this.geometry === null) { return; }
    const progress: number = this.geometry.getFlippingProgress();
    if (progress <= 0) { return; }
    const shadowStart: FlipPoint | null = this.geometry.getShadowStartPoint();
    if (shadowStart === null) { return; }
    const shadowAngle: number = this.geometry.getShadowAngle();
    const t: number = progress / 100;
    const opacity: number = 0.5 * (1 - t) * (1 - t);
    // 卷曲几何
    const visPoly: FlipPoint[] = this.clipQuadToContentRect(this.geometry.getRect(), pw, ph);
    if (visPoly.length < 3) { return; }
    let minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
    for (const p of visPoly) {
      minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x);
      minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y);
    }
    const curlW: number = maxX - minX;
    const curlH: number = maxY - minY;
    const angle: number = this.geometry.getAngle();
    const cosA: number = Math.abs(Math.cos(angle));
    const curvatureFactor: number = 0.35 + 0.65 * cosA;
    const normalAngle: number = Math.PI + shadowAngle + Math.PI / 2;
    const nx: number = Math.cos(normalAngle);
    const ny: number = Math.sin(normalAngle);
    const lightDot: number = nx * (-0.7071) + ny * (-0.7071);
    const lightFactor: number = 0.7 + 0.3 * (1 - lightDot) / 2;
    const projLen: number = Math.max(20, curlH * curvatureFactor * lightFactor);
    // 背面光照（同 drawFoldedPage）
    const sinA2: number = Math.sin(angle);
    const cosA2: number = Math.cos(angle);
    const dotNL: number = -0.7071 * sinA2 + 0.5 * cosA2;
    const lightK: number = Math.max(0, Math.min(1, (dotNL + 0.5) * 0.9 + 0.1));
    // ── 折痕附近窄带自遮挡
    ctx.save();
    if (this.clipPolygon(ctx, visPoly)) {
      ctx.translate(shadowStart.x, shadowStart.y);
      ctx.rotate(normalAngle);
      const backW: number = Math.max(24, Math.min(curlH * 0.2, curlW * 0.12, projLen * 0.5));
      const inner: CanvasGradient = ctx.createLinearGradient(-backW, 0, backW, 0);
      const creaseDark: number = Math.min(0.5, (opacity * 1.6 + 0.12) * (1.3 - 0.3 * lightK));
      inner.addColorStop(0, 'rgba(0, 0, 0, 0)');
      inner.addColorStop(0.5, 'rgba(0, 0, 0, ' + creaseDark + ')');
      inner.addColorStop(1, 'rgba(0, 0, 0, 0)');
      ctx.fillStyle = inner;
      ctx.fillRect(-backW, -curlH * 2, backW * 2, curlH * 4);
    }
    ctx.restore();
  }
}
