/*
 * PageFlipController.ets — 翻页控制器（Phase A + Phase B 收敛，T028/T034/T035）
 *
 * 职责（0.6/0.9/0.11/0.13/0.14）：
 *  - 只描述原始手势（内容 vp 坐标）+ 方向决策（deriveFlipDirection）+ token 校验；
 *  - 调用意图级 API（beginGesture/updateGesture/endGesture/cancelGesture/
 *    beginReboundRecovery/releaseTextureTransaction，坐标经 glPx/glPy 换算为 Surface px）；
 *  - 提交屏障（0.11/0.13）：完成回调 → token 校验 → pageGeneration 重新校验 →
 *    B2 turnPage → B3 refreshPage → releaseTextureTransaction；任一校验失败 → 补救
 *  - 补救闭环（0.12）：beginReboundRecovery 最多一次；失败 → 最终兜底（强制清屏 +
 *    refreshPage 用 getCurrentPage 实际内容），不递归。
 *  - 移除：touchVelX/touchVelY、selectAnimationDuration、releaseCurl 阈值判定
 *    （速度/时长/阈值判定唯一归属 native 状态机，0.6）。
 */
import { OhEngine } from 'ohrengine-ui-render';
import { TurnDirection, PageSlot, Margins, CurlModel } from 'ohrengine-common';
import { image } from '@kit.ImageKit';
import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PageRenderer } from './PageRenderer.ets';
import { GlFlipEngine, BeginGestureResult, GestureFailureReason } from 'ohrengine-gl';
import { deriveFlipDirection } from './FlipDirection.ets';

export interface PageFlipControllerDeps {
  engine: OhEngine;
  renderer: PageRenderer;
  getCanvasW: () => number;
  getCanvasH: () => number;
  getDensity: () => number;
  getMargins: () => Margins;
  getAvoidAreaTopVp: () => number;
  getUIContext: () => UIContext | undefined;
  getCurrentPage: () => PageSlot | undefined;
  getPageGeneration: () => number;
  refreshPage: () => void;
  onHideControls: () => void;
  shouldStartCurlDrag: () => boolean;
}

export class PageFlipController {
  flipAnimating: boolean = false;
  curlDragging: boolean = false;
  /** 翻页方向（1=FORWARD / -1=BACKWARD），beginGesture 时锁定，生命周期内不可变 */
  private flipDirection: number = 1;
  private flipFromPage: PageSlot | undefined = undefined;
  private flipToPage: PageSlot | undefined = undefined;
  private curlDownX: number = 0;
  private curlDownY: number = 0;
  private flipSpine: string = 'left';
  private flipFromPixelMap: image.PixelMap | null = null;
  private flipBottomPixelMap: image.PixelMap | null = null;
  private retainedPagePixelMap: image.PixelMap | null = null;
  private retainedPageKey: string = '';
  /**
   * gestureSerial 收编为 operationToken 的本地别名（0.13）：用于异步纹理准备
   * 期间的手势代次守卫；beginGesture 成功后以 native 返回的 operationToken 为准。
   */
  private gestureSerial: number = 0;
  /** 当前 native 操作 token（beginGesture 成功后的有效 token；0=无） */
  private operationToken: number = 0;
  /** beginGesture 前快照的 pageGeneration（B2 提交前重新校验，0.13/T034） */
  private pageGenSnapshot: number = 0;
  /** 补救是否已尝试（0.12：beginReboundRecovery 最多一次，不递归） */
  private reboundAttempted: boolean = false;
  /** 卷曲几何模型（默认 HYBRID：角落→Cone，边缘→Cylinder，0.3 §6.2） */
  private curlModel: CurlModel = CurlModel.HYBRID;

  // 一次翻页的显式角色：front=被翻起的页面，bottom=书脊下方的目标页面。
  private flipFrontKey: string = '';
  private flipBottomKey: string = '';

  // 最近一次 move 位置（P0-1：纹理准备期间 Move 已推进，首帧用最新位置避免跳变）
  private lastMoveX: number = 0;
  private lastMoveY: number = 0;
  /**
   * 快速滑动竞态（P0-2）：Up 在异步纹理准备（renderPageToPixelMap）完成前到达时，
   * onTouchUp 暂存释放位置（>=0 表示待处理），待 startCurlDrag 完成 beginGesture
   * 后立即用该位置 updateGesture+endGesture 收尾，避免手势被静默吞掉（endGesture(0)）。
   */
  private pendingEndX: number = -1;
  private pendingEndY: number = -1;
  private disposed: boolean = false;

  private deps: PageFlipControllerDeps;

  constructor(deps: PageFlipControllerDeps) {
    this.deps = deps;
  }

  // ── GL 引擎（ohrengine-gl）状态：GL 是唯一翻页渲染路径 ──
  private glEnabled: boolean = false;
  private glFallbackTimer: number = -1;
  /** 完成回调是否已注册到 GlFlipEngine */
  private completionRegistered: boolean = false;

  setGlEnabled(enabled: boolean): void {
    this.glEnabled = enabled;
    if (enabled && !this.completionRegistered) {
      // 注册常驻完成回调（native 常驻 TSFN → setCompletionHandler）
      GlFlipEngine.setCompletionHandler((token: number, result: string): void => {
        this.onNativeCompletion(token, result);
      });
      this.completionRegistered = true;
    }
    hilog.info(0x3900, 'OhEngine', 'setGlEnabled: %{public}s', enabled ? 'true' : 'false');
  }

  isGlEnabled(): boolean {
    return this.glEnabled && GlFlipEngine.isReady();
  }

  /** GL 坐标换算：内容坐标(vp) + margins/avoidArea → surface 全屏 px（x 轴） */
  private glPx(xVp: number): number {
    return (xVp + this.deps.getMargins().left) * this.deps.getDensity();
  }

  /** GL 坐标换算：内容坐标(vp) + margins/avoidArea → surface 全屏 px（y 轴） */
  private glPy(yVp: number): number {
    return (yVp + this.deps.getMargins().top + this.deps.getAvoidAreaTopVp()) * this.deps.getDensity();
  }

  /**
   * native 完成回调（常驻 TSFN，主线程执行）→ B2/B3 提交屏障（0.11/0.13，T034）。
   *
   * 流程：
   *  ① token 双向校验（0.13）：不匹配当前活跃 token 的迟到回调一律丢弃。
   *  ② result=completed → B2 校验：重新读取 pageGeneration 与快照比对；
   *     B2 校验失败或 turnPage() 返回 false → 不进入 B3，走补救路径（0.12）。
   *  ③ B3：refreshPage() → releaseTextureTransaction(token)。
   *  ④ result=rebound → 保持原页（模型未变），仅清状态。
   *  ⑤ 补救路径（T035）：beginReboundRecovery 最多一次；失败 → 最终兜底
   *     （强制清屏 + refreshPage 用 getCurrentPage 实际内容），不递归。
   */
  private onNativeCompletion(token: number, result: string): void {
    if (this.disposed) {
      return;
    }
    if (token !== this.operationToken || this.operationToken === 0) {
      hilog.warn(0x3900, 'OhEngine', 'stale completion dropped token=%{public}d active=%{public}d',
        token, this.operationToken);
      return;
    }
    const direction: TurnDirection = this.flipDirection > 0
      ? TurnDirection.FORWARD
      : TurnDirection.BACKWARD;
    if (result === 'completed') {
      // B2：pageGeneration 重新校验（0.13）——不一致 → 提交失效，走补救
      const currentGen: number = this.deps.getPageGeneration();
      if (currentGen !== this.pageGenSnapshot) {
        hilog.warn(0x3900, 'OhEngine',
          'B2 check failed: pageGeneration changed %{public}d → %{public}d; recovery path',
          this.pageGenSnapshot, currentGen);
        this.beginRecovery(token, direction);
        return;
      }
      // B2：turnPage（失败 → 补救）
      const ok: boolean = this.deps.engine.turnPage(direction);
      hilog.info(0x3900, 'OhEngine', 'B2 turnPage ok=%{public}s', ok ? 'true' : 'false');
      if (!ok) {
        hilog.warn(0x3900, 'OhEngine', 'B2 turnPage failed; recovery path');
        this.beginRecovery(token, direction);
        return;
      }
      // B3：Canvas 刷新 + 显式释放纹理事务（0.11/0.12）
      this.finishGlFlip();
      // 零闪烁优化：先瞬时 blit 已渲染的下一页底图（占位，杜绝旧页亚帧窗口），
      // 再全清晰度重绘替换（密集页重绘耗时不影响"下一页直接显示"）
      if (this.retainedPagePixelMap !== null) {
        this.deps.renderer.blitPixelMapToCanvas(this.retainedPagePixelMap);
      }
      this.deps.refreshPage();
      GlFlipEngine.releaseTextureTransaction(token);
      this.operationToken = 0;
    } else {
      // rebound → 保持原页（模型未变，仅清状态 + 刷新 Canvas 一致性）
      hilog.info(0x3900, 'OhEngine', 'onNativeCompletion: rebound keep page');
      this.finishGlFlip();
      this.deps.refreshPage();
      GlFlipEngine.releaseTextureTransaction(token);
      this.operationToken = 0;
    }
  }

  /**
   * 补救路径（0.12/T035）：B2 校验失败或 turnPage 失败后合成回弹。
   * beginReboundRecovery(prevToken, direction) 复用保留期纹理事务，最多一次；
   * 失败（事务已清理/状态机非 Idle）→ 最终兜底：强制清屏 + refreshPage 用
   * getCurrentPage 实际内容刷新，不递归重试。
   */
  private beginRecovery(prevToken: number, direction: TurnDirection): void {
    if (this.disposed) {
      return;
    }
    if (this.reboundAttempted) {
      // 已尝试过补救 → 直接最终兜底（不递归）
      hilog.error(0x3900, 'OhEngine', 'recovery already attempted; final fallback');
      this.finalFallback(prevToken);
      return;
    }
    this.reboundAttempted = true;
    const dir: number = direction === TurnDirection.FORWARD ? 1 : -1;
    const rec: BeginGestureResult = GlFlipEngine.beginReboundRecovery(prevToken, dir);
    if (rec.success && rec.operationToken > 0) {
      // 补救成功：等待 ReboundRecovery 完成回调（result=rebound）
      this.operationToken = rec.operationToken;
      this.flipAnimating = true;
      hilog.info(0x3900, 'OhEngine', 'beginReboundRecovery ok newToken=%{public}d', rec.operationToken);
      this.scheduleGlFlipFallback();
      return;
    }
    // 补救失败 → 最终兜底
    hilog.error(0x3900, 'OhEngine', 'beginReboundRecovery failed reason=%{public}d; final fallback',
      rec.failureReason);
    this.finalFallback(prevToken);
  }

  /**
   * 最终兜底（0.12）：强制清屏 + 用 getCurrentPage 实际内容刷新 Canvas。
   * 无过渡动画（已无可用于动画的纹理来源），保证模型与画面最终一致。
   */
  private finalFallback(prevToken: number): void {
    if (this.disposed) {
      return;
    }
    // 取消仍持有的手势（幂等；native 会清屏）
    if (this.operationToken > 0) {
      GlFlipEngine.cancelGesture(this.operationToken);
    }
    if (prevToken > 0) {
      GlFlipEngine.releaseTextureTransaction(prevToken);
    }
    this.operationToken = 0;
    this.finishGlFlip();
    this.deps.refreshPage();
    hilog.info(0x3900, 'OhEngine', 'final fallback: force-clear GL + refreshPage(current)');
  }

  /** GL 动画结束收尾（native 已完成 B1 清屏；清状态与纹理保留） */
  private finishGlFlip(): void {
    if (this.disposed) {
      return;
    }
    this.flipAnimating = false;
    this.curlDragging = false;
    const completedPage: PageSlot | undefined = this.flipToPage;
    const completedTexture: image.PixelMap | null = this.flipBottomPixelMap;
    if (completedPage !== undefined && completedTexture !== null) {
      if (this.retainedPagePixelMap !== null) {
        this.retainedPagePixelMap.release();
      }
      this.retainedPagePixelMap = completedTexture;
      this.retainedPageKey = this.pageTextureKey(completedPage);
      this.flipBottomPixelMap = null;
    }
    this.flipFromPage = undefined;
    this.flipToPage = undefined;
    this.clearFlipSources();
    this.flipFrontKey = '';
    this.flipBottomKey = '';
    // 预取底图（renderPageToPixelMap 为全同步离屏渲染，实测约 80ms）从完成关键路径移除：
    // 直接调用会阻塞 B2→B3（Commit Barrier ≤1 帧预算，0.11/性能要求 5）。延迟一拍执行，
    // 让 B3 Canvas 刷新立即完成，预取随后在独立任务中运行（缓存命中时近零开销；
    // miss 时下次翻页走异步纹理准备兜底）。
    setTimeout(() => {
      this.prefetchBottomCache();
    }, 0);
  }

  /**
   * 组件销毁时释放资源：取消进行中的手势、清定时器、release 全部 PixelMap。
   */
  dispose(): void {
    this.disposed = true;
    if (this.operationToken > 0) {
      GlFlipEngine.cancelGesture(this.operationToken);
      this.operationToken = 0;
    }
    this.gestureSerial += 1;
    this.pendingEndX = -1;
    this.pendingEndY = -1;
    if (this.glFallbackTimer > 0) {
      clearTimeout(this.glFallbackTimer);
      this.glFallbackTimer = -1;
    }
    this.curlDragging = false;
    this.flipAnimating = false;
    this.flipFromPage = undefined;
    this.flipToPage = undefined;
    this.clearFlipSources();
    if (this.retainedPagePixelMap !== null) {
      this.retainedPagePixelMap.release();
      this.retainedPagePixelMap = null;
      this.retainedPageKey = '';
    }
    this.clearBottomCache();
  }

  setSpine(spine: string): void {
    this.flipSpine = spine;
  }

  getSpine(): string {
    return this.flipSpine;
  }

  /** 设置卷曲几何模型（CYLINDER / CONE / HYBRID，0.3） */
  setCurlModel(model: CurlModel): void {
    this.curlModel = model;
  }

  getCurlModel(): CurlModel {
    return this.curlModel;
  }

  isDragging(): boolean {
    return this.curlDragging;
  }

  isAnimating(): boolean {
    return this.flipAnimating;
  }

  // ── 原始手势（内容 vp 坐标，0.14） ─────────────────────────────────

  onTouchDown(xVp: number, yVp: number): void {
    if (this.disposed) {
      return;
    }
    this.gestureSerial += 1;
    this.operationToken = 0;
    this.reboundAttempted = false;
    this.pendingEndX = -1;
    this.pendingEndY = -1;
    this.curlDownX = xVp;
    this.curlDownY = yVp;
    this.curlDragging = false;
    this.lastMoveX = xVp;
    this.lastMoveY = yVp;
  }

  onTouchMove(xVp: number, yVp: number): boolean {
    if (this.disposed) {
      return false;
    }
    this.lastMoveX = xVp;
    this.lastMoveY = yVp;
    if (this.deps.shouldStartCurlDrag()) {
      this.startCurlDrag(xVp, yVp);
    }
    if (this.curlDragging && this.operationToken > 0) {
      GlFlipEngine.updateGesture(this.operationToken, this.glPx(xVp), this.glPy(yVp), Date.now());
      return true;
    }
    return false;
  }

  onTouchUp(xVp: number, yVp: number): void {
    if (this.disposed) {
      return;
    }
    if (this.curlDragging) {
      if (this.operationToken > 0) {
        this.curlDragging = false;
        // endGesture：完成/回弹判定由 native 状态机负责（0.6），ArkTS 只传释放位置
        GlFlipEngine.endGesture(this.operationToken, this.glPx(xVp), this.glPy(yVp));
      } else {
        // 纹理预备尚未完成（快速滑动竞态）：暂存释放位置，
        // startCurlDrag 完成 beginGesture 后立即用该位置收尾（P0-2）
        this.pendingEndX = xVp;
        this.pendingEndY = yVp;
        hilog.info(0x3900, 'OhEngine', 'onTouchUp: prep pending, defer endGesture to beginGesture completion');
      }
    }
  }

  onTouchCancel(): void {
    this.gestureSerial += 1;
    this.pendingEndX = -1;
    this.pendingEndY = -1;
    if (this.curlDragging && this.operationToken > 0) {
      GlFlipEngine.cancelGesture(this.operationToken);
    }
    this.curlDragging = false;
    this.operationToken = 0;
    this.flipAnimating = false;
  }

  // ── 点击式翻页（synthetic gesture，0.9） ───────────────────────────

  async animateTurnPage(direction: TurnDirection): Promise<void> {
    hilog.info(0x3900, 'OhEngine', '[TRACE] animateTurnPage dir=%{public}d', direction === TurnDirection.FORWARD ? 1 : -1);
    if (this.disposed || this.flipAnimating || !this.isGlEnabled()) {
      if (!this.isGlEnabled()) {
        hilog.error(0x3900, 'OhEngine', 'GL flip unavailable; refusing non-GL page turn');
      }
      return;
    }
    const operation: number = this.gestureSerial + 1;
    this.gestureSerial = operation;
    this.flipAnimating = true;
    this.operationToken = 0;
    const fromPage: PageSlot | undefined = this.deps.engine.getCurrentPage();
    const targetPage: PageSlot | undefined = this.deps.engine.peekPage(direction);
    if (fromPage === undefined || targetPage === undefined) {
      this.flipAnimating = false;
      return;
    }
    await this.captureFromPageSnapshot(fromPage);
    if (operation !== this.gestureSerial) {
      this.clearFlipSources();
      this.flipAnimating = false;
      return;
    }
    await this.captureBottomLayer(targetPage);
    if (operation !== this.gestureSerial) {
      this.clearFlipSources();
      this.flipAnimating = false;
      return;
    }
    const frontKey: string = this.pageTextureKey(fromPage);
    const bottomKey: string = this.pageTextureKey(targetPage);
    this.flipFrontKey = frontKey;
    this.flipBottomKey = bottomKey;
    // 纹理准备必须在 beginGesture 之前完成（native 以 token 登记事务，0.12）
    if (this.flipFromPixelMap === null || this.flipBottomPixelMap === null ||
      !await this.uploadFlipTextures(frontKey, bottomKey)) {
      this.clearFlipSources();
      this.flipAnimating = false;
      return;
    }
    this.flipFromPage = fromPage;
    this.flipToPage = targetPage;
    this.flipDirection = direction === TurnDirection.FORWARD ? 1 : -1;
    const dir: number = this.flipDirection;
    const contentW: number = this.deps.getCanvasW() - this.deps.getMargins().left - this.deps.getMargins().right;
    const startX: number = this.flipSpine === 'right'
      ? (dir > 0 ? 0 : contentW)
      : (dir > 0 ? contentW : 0);
    const midY: number = this.deps.getCanvasH() * 0.5;
    const targetX: number = dir > 0 ? (this.flipSpine === 'right' ? contentW : 0)
      : (this.flipSpine === 'right' ? 0 : contentW);
    this.pageGenSnapshot = this.deps.getPageGeneration();
    this.reboundAttempted = false;
    // 合成手势：down = touch = 起始边缘点；endGesture 释放到对侧 → native 判定完成
    const result: BeginGestureResult = GlFlipEngine.beginGesture(
      dir, this.flipSpine, this.glPx(startX), this.glPy(midY),
      this.curlModel, true, this.pageGenSnapshot);
    if (!result.success) {
      hilog.error(0x3900, 'OhEngine', 'animateTurnPage: beginGesture failed reason=%{public}d',
        result.failureReason);
      this.flipAnimating = false;
      this.clearFlipSources();
      return;
    }
    this.operationToken = result.operationToken;
    GlFlipEngine.updateGesture(this.operationToken, this.glPx(startX), this.glPy(midY), Date.now());
    GlFlipEngine.endGesture(this.operationToken, this.glPx(targetX), this.glPy(midY));
    hilog.info(0x3900, 'OhEngine', 'GL synthetic flip started token=%{public}d', this.operationToken);
    this.scheduleGlFlipFallback();
  }

  // ── 拖拽翻页 ────────────────────────────────────────────────────────

  private async startCurlDrag(xVp: number, yVp: number): Promise<void> {
    hilog.info(0x3900, 'OhEngine', '[TRACE] startCurlDrag entry x=%{public}d y=%{public}d', Math.round(xVp), Math.round(yVp));
    if (this.disposed || this.curlDragging || this.flipAnimating) {
      return;
    }
    const gesture: number = this.gestureSerial;
    const contentW: number = this.deps.getCanvasW() - this.deps.getMargins().left - this.deps.getMargins().right;
    // 0.9：方向推导唯一纯函数（内容 vp 坐标）
    const direction: TurnDirection = deriveFlipDirection(
      this.curlDownX, this.curlDownY, xVp, yVp, this.flipSpine, contentW);
    const toPage: PageSlot | undefined = this.deps.engine.peekPage(direction);
    if (toPage === undefined) {
      return;
    }
    this.deps.onHideControls();
    if (!this.isGlEnabled()) {
      hilog.error(0x3900, 'OhEngine', 'startCurlDrag: GL is not ready');
      return;
    }
    this.flipDirection = direction === TurnDirection.FORWARD ? 1 : -1;
    this.flipToPage = toPage;
    this.curlDragging = true;
    const currentPage: PageSlot | undefined = this.deps.engine.getCurrentPage();
    if (currentPage === undefined) {
      this.curlDragging = false;
      this.pendingEndX = -1;
      this.pendingEndY = -1;
      this.clearFlipSources();
      return;
    }
    await this.captureFromPageSnapshot(currentPage);
    if (!this.curlDragging || gesture !== this.gestureSerial) {
      this.pendingEndX = -1;
      this.pendingEndY = -1;
      this.clearFlipSources();
      this.curlDragging = false;
      return;
    }
    await this.captureBottomLayer(toPage);
    if (!this.curlDragging || gesture !== this.gestureSerial) {
      this.pendingEndX = -1;
      this.pendingEndY = -1;
      this.clearFlipSources();
      this.curlDragging = false;
      return;
    }
    this.flipFromPage = currentPage;
    const frontKey: string = this.pageTextureKey(currentPage);
    const bottomKey: string = this.pageTextureKey(toPage);
    this.flipFrontKey = frontKey;
    this.flipBottomKey = bottomKey;
    // 纹理上传必须在 beginGesture 之前完成（native 以 token 登记事务，0.12/T028）
    if (this.flipFromPixelMap === null || this.flipBottomPixelMap === null ||
      !await this.uploadFlipTextures(frontKey, bottomKey)) {
      hilog.error(0x3900, 'OhEngine', 'startCurlDrag: GL texture upload failed');
      this.curlDragging = false;
      this.pendingEndX = -1;
      this.pendingEndY = -1;
      this.clearFlipSources();
      return;
    }
    this.pageGenSnapshot = this.deps.getPageGeneration();
    this.reboundAttempted = false;
    const gDownX: number = this.glPx(this.curlDownX);
    const gDownY: number = this.glPy(this.curlDownY);
    const result: BeginGestureResult = GlFlipEngine.beginGesture(
      this.flipDirection, this.flipSpine, gDownX, gDownY,
      this.curlModel, false, this.pageGenSnapshot);
    if (!result.success) {
      hilog.error(0x3900, 'OhEngine', 'startCurlDrag: beginGesture failed reason=%{public}d',
        result.failureReason);
      this.curlDragging = false;
      this.pendingEndX = -1;
      this.pendingEndY = -1;
      this.clearFlipSources();
      return;
    }
    this.operationToken = result.operationToken;
    if (this.pendingEndX >= 0) {
      // Up 已在纹理预备期间到达（快速滑动，P0-2）：用释放位置直接收尾，
      // native 状态机据此判定完成/回弹，手势不再被吞掉
      const ex: number = this.glPx(this.pendingEndX);
      const ey: number = this.glPy(this.pendingEndY);
      this.pendingEndX = -1;
      this.pendingEndY = -1;
      this.curlDragging = false;
      GlFlipEngine.updateGesture(this.operationToken, ex, ey, Date.now());
      GlFlipEngine.endGesture(this.operationToken, ex, ey);
      hilog.info(0x3900, 'OhEngine', 'GL curl drag started (fast swipe, deferred end) token=%{public}d',
        this.operationToken);
      this.scheduleGlFlipFallback();
      return;
    }
    // P0-1：异步纹理准备期间 Move 已推进，用最新位置更新，避免首帧从旧位置起跳
    const gx: number = this.glPx(this.lastMoveX);
    const gy: number = this.glPy(this.lastMoveY);
    GlFlipEngine.updateGesture(this.operationToken, gx, gy, Date.now());
    hilog.info(0x3900, 'OhEngine', 'GL curl drag started token=%{public}d', this.operationToken);
    this.scheduleGlFlipFallback();
  }

  /** GL 动画兜底：native 完成回调丢失时强制收尾（防状态残留卡死，0.12 安全网） */
  private scheduleGlFlipFallback(): void {
    if (this.glFallbackTimer > 0) {
      clearTimeout(this.glFallbackTimer);
    }
    this.glFallbackTimer = setTimeout(() => {
      this.glFallbackTimer = -1;
      if (this.flipAnimating || this.operationToken > 0) {
        hilog.error(0x3900, 'OhEngine', 'GL flip completion callback timed out');
        // 兜底超时：取消当前操作并清状态（native 自身 900ms 超时语义同向）
        if (this.operationToken > 0) {
          GlFlipEngine.cancelGesture(this.operationToken);
          this.operationToken = 0;
        }
        this.finishGlFlip();
        this.deps.refreshPage();
      }
    }, 900);
  }

  // ── 纹理准备（beginGesture 之前，0.12） ────────────────────────────

  private async uploadFlipTextures(frontKey: string, backKey: string): Promise<boolean> {
    if (this.flipFromPixelMap === null || this.flipBottomPixelMap === null) {
      return false;
    }
    const uploaded: boolean = await GlFlipEngine.setTextures(this.flipFromPixelMap, this.flipBottomPixelMap,
      frontKey, backKey);
    hilog.info(0x3900, 'OhEngine',
      'flip texture roles: frontKey=%{public}s bottomKey=%{public}s uploaded=%{public}s',
      frontKey, backKey, uploaded ? 'true' : 'false');
    return uploaded;
  }

  private pageTextureKey(page: PageSlot): string {
    const profile = this.deps.engine.getLayoutProfile();
    const theme = profile.theme;
    // 纹理键唯一性（Phase B 修复，Phase A 遗留观察项）：pageNumber 是章节内
    // 局部页号，跨章第 0 页键会碰撞；加入 chunkIndex 与 href 消除碰撞，
    // 避免纹理事务/补救复用场景取错缓存纹理。
    return page.chunkIndex + ':' + page.pageNumber + ':' + page.href + ':' + page.epoch + ':' +
      Math.round(this.deps.getCanvasW() * this.deps.getDensity()) + 'x' +
      Math.round(this.deps.getCanvasH() * this.deps.getDensity()) + ':' +
      String(profile.fontFamily) + ':' + profile.lineSpacing + ':' +
      profile.letterSpacing + ':' + profile.textAlign + ':' +
      theme.backgroundColor + ':' + theme.textColor;
  }

  private clearFlipSources(): void {
    if (this.flipFromPixelMap !== null) {
      this.flipFromPixelMap.release();
      this.flipFromPixelMap = null;
    }
    if (this.flipBottomPixelMap !== null) {
      this.flipBottomPixelMap.release();
      this.flipBottomPixelMap = null;
    }
    this.flipFrontKey = '';
    this.flipBottomKey = '';
  }

  private async captureBottomLayer(page: PageSlot): Promise<void> {
    try {
      if (this.disposed) {
        return;
      }
      const cached: image.PixelMap | undefined = this.takeFromCache(this.pageTextureKey(page));
      if (cached !== undefined) {
        this.flipBottomPixelMap = cached;
        hilog.info(0x3900, 'OhEngine',
          'capture bottom: page=%{public}d role=bottom source=bottomCache key=%{public}s',
          page.pageNumber, this.pageTextureKey(page));
        return;
      }
      if (this.flipBottomPixelMap !== null) {
        this.flipBottomPixelMap.release();
        this.flipBottomPixelMap = null;
      }
      const pm: image.PixelMap | null = await this.deps.renderer.renderPageToPixelMap(page, this.deps.getDensity());
      if (pm !== null && !this.disposed) {
        this.flipBottomPixelMap = await this.normalizeFlipPixelMap(pm);
        if (this.disposed) {
          this.flipBottomPixelMap.release();
          this.flipBottomPixelMap = null;
        }
      } else if (pm !== null) {
        pm.release();
      }
      hilog.info(0x3900, 'OhEngine',
        'capture bottom: page=%{public}d role=bottom source=renderPageToPixelMap pm=%{public}s key=%{public}s',
        page.pageNumber, this.flipBottomPixelMap === null ? 'null' : 'ok', this.pageTextureKey(page));
    } catch (e) {
      hilog.error(0x3900, 'OhEngine', 'captureBottomLayer failed: %{public}s', String(e));
      if (this.flipBottomPixelMap !== null) {
        this.flipBottomPixelMap.release();
      }
      this.flipBottomPixelMap = null;
    }
  }

  private async captureFromPageSnapshot(currentPage: PageSlot): Promise<void> {
    try {
      if (this.disposed) {
        return;
      }
      if (this.flipFromPixelMap !== null) {
        this.flipFromPixelMap.release();
        this.flipFromPixelMap = null;
      }
      const currentKey: string = this.pageTextureKey(currentPage);
      if (this.retainedPagePixelMap !== null && this.retainedPageKey === currentKey) {
        this.flipFromPixelMap = this.retainedPagePixelMap;
        this.retainedPagePixelMap = null;
        this.retainedPageKey = '';
        hilog.info(0x3900, 'OhEngine',
          'capture front: page=%{public}d role=front source=retained key=%{public}s',
          currentPage.pageNumber, currentKey);
        return;
      }
      const snapshotStart: number = Date.now();
      const pm: image.PixelMap | null = await this.deps.renderer.renderPageToPixelMap(
        currentPage, this.deps.getDensity());
      if (pm !== null && !this.disposed) {
        this.flipFromPixelMap = await this.normalizeFlipPixelMap(pm);
        if (this.disposed) {
          this.flipFromPixelMap.release();
          this.flipFromPixelMap = null;
        }
        hilog.info(0x3900, 'OhEngine-Perf', 'flip screenshot+normalize=%{public}dms',
          Date.now() - snapshotStart);
      } else if (pm !== null) {
        pm.release();
      }
      hilog.info(0x3900, 'OhEngine',
        'capture front: page=%{public}d role=front source=renderPageToPixelMap pm=%{public}s key=%{public}s',
        currentPage.pageNumber, this.flipFromPixelMap === null ? 'null' : 'ok', currentKey);
    } catch (e) {
      hilog.error(0x3900, 'OhEngine', 'captureFromPageSnapshot failed: %{public}s', String(e));
      if (this.flipFromPixelMap !== null) {
        this.flipFromPixelMap.release();
      }
      this.flipFromPixelMap = null;
    }
  }

  private async normalizeFlipPixelMap(pm: image.PixelMap): Promise<image.PixelMap> {
    try {
      const size = pm.getImageInfoSync().size;
      const displayW: number = Math.max(1, Math.round(this.deps.getCanvasW() * this.deps.getDensity()));
      const displayH: number = Math.max(1, Math.round(this.deps.getCanvasH() * this.deps.getDensity()));
      const displayMax: number = Math.max(displayW, displayH);
      const maxTextureDimension: number = displayMax > 2048 ? 2048 : displayMax;
      const scale: number = Math.min(1, maxTextureDimension / Math.max(size.width, size.height));
      if (scale < 0.999) {
        await pm.scale(scale, scale);
      }
    } catch (e) {
      hilog.warn(0x3900, 'OhEngine', 'normalizeFlipPixelMap failed: %{public}s', String(e));
    }
    return pm;
  }

  // ── 页图预取缓存（消除翻页前底图渲染等待） ──
  private bottomCache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private readonly BOTTOM_CACHE_MAX: number = 2;
  private prefetching: boolean = false;

  private takeFromCache(key: string): image.PixelMap | undefined {
    const pm: image.PixelMap | undefined = this.bottomCache.get(key);
    if (pm !== undefined) {
      this.bottomCache.delete(key);
    }
    return pm;
  }

  private clearBottomCache(): void {
    this.bottomCache.forEach((pm: image.PixelMap) => {
      pm.release();
    });
    this.bottomCache.clear();
  }

  /** 翻页完成后后台预渲染"下一页/上一页"页图，下次翻页时底图 0ms 就绪。 */
  private async prefetchBottomCache(): Promise<void> {
    if (this.prefetching) {
      return;
    }
    this.prefetching = true;
    try {
      const next: PageSlot | undefined = this.deps.engine.peekPage(TurnDirection.FORWARD);
      const prev: PageSlot | undefined = this.deps.engine.peekPage(TurnDirection.BACKWARD);
      const targets: PageSlot[] = [];
      if (next !== undefined) {
        targets.push(next);
      }
      if (prev !== undefined) {
        targets.push(prev);
      }
      for (const p of targets) {
        if (this.disposed) {
          return;
        }
        const key: string = this.pageTextureKey(p);
        if (this.bottomCache.has(key)) {
          continue;
        }
        if (this.bottomCache.size >= this.BOTTOM_CACHE_MAX) {
          const first: string | undefined = this.bottomCache.keys().next().value;
          if (first !== undefined) {
            const old: image.PixelMap | undefined = this.bottomCache.get(first);
            if (old !== undefined) {
              old.release();
            }
            this.bottomCache.delete(first);
          }
        }
        const pm: image.PixelMap | null = await this.deps.renderer.renderPageToPixelMap(p, this.deps.getDensity());
        if (pm !== null) {
          const normalized: image.PixelMap = await this.normalizeFlipPixelMap(pm);
          if (this.disposed) {
            normalized.release();
            return;
          }
          this.bottomCache.set(key, normalized);
        }
      }
    } catch (e) {
      hilog.error(0x3900, 'OhEngine', 'prefetchBottomCache failed: %{public}s', String(e));
    } finally {
      this.prefetching = false;
    }
  }
}
