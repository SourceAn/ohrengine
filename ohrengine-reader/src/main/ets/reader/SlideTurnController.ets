/**
 * SlideTurnController — 横滑/上下滑动补间翻页控制器
 *
 * HORIZONTAL / VERTICAL 翻页模式的轻量 Canvas 补间动画：
 *   - 动画：setInterval(16ms) + Date.now 驱动（与 FlipPageController.animateTo
 *     同一驱动模式，真机验证过的路径），约 300ms，easeOutCubic 缓动；
 *   - 渲染：一帧画两页——当前页(from)随 offset 平移出屏、目标页(to)从
 *     屏幕外(±contentWidth/±contentHeight)平移入位，均复用
 *     PageRenderer.drawPageContent 的屏上渲染管线；
 *   - 方向约定（与 ReaderGestureController.deriveSwipeDirection 一致）：
 *       上滑=下一页(FORWARD)、下滑=上一页(BACKWARD)；
 *       左滑=下一页(FORWARD)、右滑=上一页(BACKWARD)。
 *     视觉：FORWARD 新页从下方/右侧滑入，旧页向上/向左滑出。
 *   - 翻页完成回调 onPageTurned 内做真正页面切换（engine.turnPage + 刷新静态页）。
 *
 * TODO(后续增强候选，参考 docs/ai/reader-ux-research.md §6)：
 *   - 拖拽跟手：beginFold/updateFold/endFold 目前为 no-op（松手后才播放
 *     补全动画）。跟手需要 ReaderGestureController 的 Move 阶段对
 *     HORIZONTAL/VERTICAL 也调用 beginFold/updateFold。
 */
import { OhEngine } from 'ohrengine-ui-render';
import { TurnDirection } from 'ohrengine-common';
import type { PageSlot } from 'ohrengine-common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import type { FlipGestureAdapter } from './FlipPageController.ets';
import { PageRenderer, ReaderViewport } from './PageRenderer.ets';

const SLIDE_TAG: string = 'OhEngine-Slide';

/** 滑动翻页状态 */
enum SlidePhase {
  READ = 0,
  ANIM = 1,
}

export interface SlideTurnControllerDeps {
  engine: OhEngine;
  pageRenderer: PageRenderer;
  canvasCtx: CanvasRenderingContext2D;
  getViewport: () => ReaderViewport;
  /** 翻页动画完成（页面应真正切换：engine.turnPage + 刷新静态页） */
  onPageTurned: (direction: TurnDirection) => void;
  /** 翻页开始（true，可隐藏控制层/清除选择）/ 结束（false） */
  onFlipStateChange: (active: boolean) => void;
}

export class SlideTurnController implements FlipGestureAdapter {
  private readonly deps: SlideTurnControllerDeps;
  private phase: SlidePhase = SlidePhase.READ;
  private animTimer: number = -1;
  private animStartTime: number = 0;
  private readonly ANIM_DURATION_MS: number = 300;
  /** 当前页内容源 */
  private fromRef: PageSlot | undefined = undefined;
  /** 目标页内容源 */
  private toRef: PageSlot | undefined = undefined;
  private horizontal: boolean = true;
  private forward: boolean = true;
  private offset: number = 0;
  private disposed: boolean = false;

  constructor(deps: SlideTurnControllerDeps) {
    this.deps = deps;
  }

  /** 是否处于翻页动画中 */
  isActive(): boolean {
    return this.phase === SlidePhase.ANIM;
  }

  /** 不支持拖拽折叠（补间模式无跟手，松手播放补全动画） */
  isFolding(): boolean {
    return false;
  }

  beginFold(_x: number, _y: number, _startX: number): boolean {
    return false;
  }

  updateFold(_x: number, _y: number): void {
  }

  endFold(): void {
  }

  /**
   * 播放完整滑动补间翻页动画。
   * @returns 是否成功开始（非空闲状态或边界页返回 false）
   */
  playFlip(direction: TurnDirection, _x: number, _y: number): boolean {
    if (this.disposed || this.phase !== SlidePhase.READ) {
      return false;
    }
    const engine: OhEngine = this.deps.engine;
    const from: PageSlot | undefined = engine.getCurrentPage();
    const curNum: number = engine.getGlobalPageNumber();
    const forward: boolean = direction === TurnDirection.FORWARD;
    // getGlobalPageNumber() 为 1-based：下一页=索引 curNum，上一页=索引 curNum-2
    const to: PageSlot | undefined = engine.getPageByGlobalIndex(forward ? curNum : curNum - 2);
    if (from === undefined || to === undefined) {
      return false;
    }
    this.fromRef = from;
    this.toRef = to;
    this.forward = forward;
    this.horizontal = true;
    this.phase = SlidePhase.ANIM;
    this.offset = 0;
    this.deps.onFlipStateChange(true);
    hilog.info(0x0000, SLIDE_TAG, 'playFlip dir=%{public}s from=%{public}d to=%{public}d',
      direction === TurnDirection.FORWARD ? 'F' : 'B', curNum, forward ? curNum + 1 : curNum - 1);
    this.animStartTime = Date.now();
    this.animTimer = setInterval(() => {
      this.animTick();
    }, 16);
    return true;
  }

  private animTick(): void {
    if (this.disposed) {
      this.stopAnimation();
      return;
    }
    const t: number = Math.min(1, (Date.now() - this.animStartTime) / this.ANIM_DURATION_MS);
    // easeOutCubic：起快收慢，贴近阅读器滑动观感
    const e: number = 1 - Math.pow(1 - t, 3);
    const extent: number = this.horizontal ? this.deps.getViewport().contentWidth : this.deps.getViewport().contentHeight;
    // FORWARD：offset 0 → -extent（旧页顺手势方向滑出）; BACKWARD：0 → +extent
    this.offset = (this.forward ? -1 : 1) * extent * e;
    this.renderFrame();
    if (t >= 1) {
      this.finishAnim();
    }
  }

  private renderFrame(): void {
    const vp: ReaderViewport = this.deps.getViewport();
    const ctx: CanvasRenderingContext2D = this.deps.canvasCtx;
    const theme = this.deps.engine.getThemeManager().currentTheme;
    ctx.save();
    ctx.fillStyle = theme.backgroundColor;
    ctx.fillRect(0, 0, vp.canvasW, vp.canvasH);
    const xOff: number = this.horizontal ? this.offset : 0;
    const yOff: number = this.horizontal ? 0 : this.offset;
    // 当前页（跟随 offset 移出）
    if (this.fromRef !== undefined) {
      ctx.save();
      ctx.translate(vp.margins.left + xOff, vp.margins.top + vp.avoidAreaTopVp + yOff);
      this.deps.pageRenderer.drawPageContent(ctx, this.fromRef, 'vp', 1, -1, 1e9);
      ctx.restore();
    }
    // 目标页（从外侧移入；FORWARD 落在 +extent 侧，BACKWARD 落在 -extent 侧）
    const extentX: number = this.horizontal
      ? (this.forward ? vp.contentWidth : -vp.contentWidth) : 0;
    const extentY: number = this.horizontal
      ? 0 : (this.forward ? vp.contentHeight : -vp.contentHeight);
    if (this.toRef !== undefined) {
      ctx.save();
      ctx.translate(vp.margins.left + xOff + extentX, vp.margins.top + vp.avoidAreaTopVp + yOff + extentY);
      this.deps.pageRenderer.drawPageContent(ctx, this.toRef, 'vp', 1, -1, 1e9);
      ctx.restore();
    }
    ctx.restore();
  }

  private finishAnim(): void {
    const direction: TurnDirection = this.forward ? TurnDirection.FORWARD : TurnDirection.BACKWARD;
    this.stopAnimation();
    this.phase = SlidePhase.READ;
    this.fromRef = undefined;
    this.toRef = undefined;
    this.deps.onFlipStateChange(false);
    this.deps.onPageTurned(direction);
    // 回画静态当前页（onPageTurned 内 refreshPage 亦会重绘，此处兜底）
    this.deps.pageRenderer.renderPage();
  }

  private stopAnimation(): void {
    if (this.animTimer > 0) {
      clearInterval(this.animTimer);
      this.animTimer = -1;
    }
  }

  dispose(): void {
    this.disposed = true;
    this.stopAnimation();
    this.phase = SlidePhase.READ;
  }
}