import { SelectionRange, SelectionGestureHandler } from 'ohrengine-feature';
import { TurnDirection } from 'ohrengine-common';
import type { LineBox, Margins } from 'ohrengine-common';
import type { FlipGestureAdapter } from './FlipPageController.ets';
import { ReaderTurnMode } from '../utils/ReaderSettings.ets';
import { KeyCode } from '@kit.InputKit';

export interface ReaderGestureControllerDeps {
  getSelection: () => SelectionRange | null;
  setSelection: (s: SelectionRange | null) => void;
  getPageLines: () => LineBox[];
  getContentWidth: () => number;
  getContentHeight: () => number;
  getMargins: () => Margins;
  onRenderPage: () => void;
  onHideControls: () => void;
  onToggleControls: () => void;
  /** 当前翻页方式（仿真→翻页动画；横滑/上下/无动效→即时翻页） */
  getTurnMode: () => ReaderTurnMode;
  /** 单手模式：点击左右两侧均为下一页 */
  getSingleHand: () => boolean;
  /** 是否处于自动翻页（点击正文唤起控制栏而非翻页） */
  isAutoTurning: () => boolean;
  /** 自动翻页激活时点击正文（唤起自动翻页控制栏） */
  onAutoTurnTap: () => void;
  /** 即时翻页（非仿真模式；direction 为视觉方向） */
  onQuickTurn: (direction: TurnDirection) => void;
  /** 横滑/上下滑动补间控制器（HORIZONTAL/VERTICAL 模式；null=不可用） */
  getSlideTurn: () => FlipGestureAdapter | null;
  /** 仿真翻页控制器（仿真模式翻页的唯一出口） */
  flip: FlipGestureAdapter;
  /** 下拉添加书签：拖动进度回调（dy 为当前下拉位移 vp，>0 时随手指弹性拉伸） */
  onBookmarkPullMove: (dy: number) => void;
  /** 下拉结束：add=true 表示达到触发距离（添加书签）；false 仅弹性回弹 */
  onBookmarkPullEnd: (add: boolean) => void;
  /** 音量键翻页：是否启用（true 时音量键触发 onVolumeKeyTurn） */
  getVolumeFlip?: () => boolean;
  /** 音量键翻页回调（音量下=下一页 FORWARD，音量上=上一页 BACKWARD） */
  onVolumeKeyTurn?: (direction: TurnDirection) => void;
  /** Phase 16.3: 选择交互前恢复当前页逐字几何（惰性 production path） */
  ensurePageLinesGeometry?: () => void;
}

/**
 * 阅读手势控制器：点击/滑动翻页、长按选词与拖动扩选、
 * 单手模式、翻页方式（仿真/横滑/上下滑动/无动效）、自动翻页交互。
 */
export class ReaderGestureController {
  private deps: ReaderGestureControllerDeps;
  private longPressTimer: number = -1;
  private longPressClosure: (() => SelectionRange | null) | null = null;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  /** 手势起点全屏 vp 坐标（翻页方向判定用；快速滑动时当前点已偏移） */
  private touchStartFullX: number = 0;
  private hasMoved: boolean = false;
  private activePointerId: number = -1;
  /** 下拉添加书签手势是否已激活 */
  private bookmarkPullActive: boolean = false;

  /** 下拉进入书签手势的最小位移（避免与单击/微动混淆） */
  private static readonly PULL_ENGAGE: number = 14;
  /** 达到该位移判定书签添加成功（画布书签填充满） */
  private static readonly PULL_TRIGGER: number = 80;
  /** 上下滑动翻页模式保留顶部触控带限制（下拉=上一页，避免冲突） */
  private static readonly PULL_TOP_BAND: number = 0.22;

  constructor(deps: ReaderGestureControllerDeps) {
    this.deps = deps;
  }

  getHasMoved(): boolean {
    return this.hasMoved;
  }

  hideControls(): void {
    this.deps.onHideControls();
  }

  /**
   * 音量键翻页（由宿主按键事件回调调用）：
   *  - 仅按下瞬间（isDown=true）触发，避免按住重复；
   *  - 音量下 = 下一页（FORWARD），音量上 = 上一页（BACKWARD）；
   *  - 未启用（getVolumeFlip 未提供或返回 false）时静默忽略。
   */
  handleVolumeKeyEvent(keyCode: number, isDown: boolean): void {
    if (!isDown) {
      return;
    }
    if (this.deps.getVolumeFlip === undefined || !this.deps.getVolumeFlip()) {
      return;
    }
    if (this.deps.onVolumeKeyTurn === undefined) {
      return;
    }
    if (keyCode === KeyCode.KEYCODE_VOLUME_DOWN) {
      this.deps.onVolumeKeyTurn(TurnDirection.FORWARD);
    } else if (keyCode === KeyCode.KEYCODE_VOLUME_UP) {
      this.deps.onVolumeKeyTurn(TurnDirection.BACKWARD);
    }
  }

  handleTouch(event: TouchEvent): void {
    let point: TouchObject | undefined;
    if (event.type === TouchType.Down) {
      if (this.activePointerId >= 0) {
        return;
      }
      point = event.changedTouches[0] ?? event.touches[0];
      if (point === undefined) {
        return;
      }
      this.activePointerId = point.id;
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const changed: TouchObject | undefined = event.changedTouches[0];
      if (changed === undefined || changed.id !== this.activePointerId) {
        return;
      }
      point = changed;
    } else {
      for (const touch of event.touches) {
        if (touch.id === this.activePointerId) {
          point = touch;
          break;
        }
      }
      if (point === undefined) {
        return;
      }
    }
    const tx: number = point.x;
    const ty: number = point.y;
    const margins: Margins = this.deps.getMargins();
    const contentWidth: number = this.deps.getContentWidth();
    const contentHeight: number = this.deps.getContentHeight();
    const x: number = tx - margins.left;
    const y: number = ty - margins.top;
    const inContent: boolean = x >= 0 && y >= 0 && x < contentWidth && y < contentHeight;
    if (!inContent && event.type !== TouchType.Up && event.type !== TouchType.Cancel) {
      return;
    }
    const cx: number = Math.max(0, Math.min(contentWidth, x));
    const cy: number = Math.max(0, Math.min(contentHeight, y));
    if (this.deps.isAutoTurning()) {
      this.handleAutoTurnTouch(event, tx, ty, cx, cy, contentWidth);
      return;
    }

    if (event.type === TouchType.Down) {
      this.touchStartX = cx;
      this.touchStartY = cy;
      this.touchStartFullX = tx;
      this.hasMoved = false;
      this.bookmarkPullActive = false;
      if (this.deps.getSelection() !== null) {
        this.deps.setSelection(null);
        this.deps.onRenderPage();
        this.hasMoved = true;
        return;
      }
      SelectionGestureHandler.reset();
      // Phase 16.3: 选择交互前按需恢复当前页逐字几何（Worker 传输已剔除的数组在此重建）
      if (this.deps.ensurePageLinesGeometry !== undefined) {
        this.deps.ensurePageLinesGeometry();
      }
      this.longPressClosure = SelectionGestureHandler.handleTouchDown(x, y, this.deps.getPageLines());
      this.longPressTimer = setTimeout(() => {
        if (this.longPressClosure !== null) {
          const result: SelectionRange | null = this.longPressClosure();
          if (result !== null) {
            this.deps.setSelection(result);
            this.hideControls();
            this.deps.onRenderPage();
          }
        }
        this.longPressTimer = -1;
      }, 420);
    } else if (event.type === TouchType.Move) {
      if (Math.abs(cx - this.touchStartX) > 15 || Math.abs(cy - this.touchStartY) > 15) {
        this.hasMoved = true;
        if (this.longPressTimer > 0) {
          clearTimeout(this.longPressTimer);
          this.longPressTimer = -1;
          this.longPressClosure = null;
        }
      }
      const selection: SelectionRange | null = this.deps.getSelection();
      if (selection !== null) {
        // 双向拖动扩选：靠近哪个手柄就调整哪一侧
        const adjustStart: boolean = this.nearStartHandle(cx, cy, selection);
        const updated: SelectionRange | null = SelectionGestureHandler.handleTouchMove(
          cx, cy, selection, this.deps.getPageLines(), adjustStart
        );
        if (updated !== null) {
          this.deps.setSelection(updated);
          this.deps.onRenderPage();
        }
        return;
      }
      // ── 下拉添加书签：正文向下拖 → 弹性拉伸 + 书签填充预览 ──
      const pullDy: number = cy - this.touchStartY;
      const pullDx: number = cx - this.touchStartX;
      // 上下滑动翻页模式：仅顶部触控带内触发（下拉=上一页，保留翻页语义）；
      // 仿真/横滑模式：下拉无其他用途，正文任意位置均可触发（更易发现）
      const restricted: boolean = this.deps.getTurnMode() === ReaderTurnMode.VERTICAL ||
        this.deps.getTurnMode() === ReaderTurnMode.NONE;
      const inPullZone: boolean = restricted
        ? this.touchStartY <= contentHeight * ReaderGestureController.PULL_TOP_BAND
        : true;
      if (!this.bookmarkPullActive &&
        inPullZone &&
        pullDy >= ReaderGestureController.PULL_ENGAGE &&
        pullDy > Math.abs(pullDx) * 1.15 &&
        Math.abs(pullDx) < 64) {
        if (this.longPressTimer > 0) {
          clearTimeout(this.longPressTimer);
          this.longPressTimer = -1;
          this.longPressClosure = null;
        }
        this.bookmarkPullActive = true;
        this.hideControls();
        this.deps.onBookmarkPullMove(pullDy);
        return;
      }
      if (this.bookmarkPullActive) {
        this.deps.onBookmarkPullMove(Math.max(0, pullDy));
        return;
      }
      // ── 仿真翻页：拖拽折叠跟随 ──
      if (this.deps.getTurnMode() === ReaderTurnMode.SIMULATION) {
        if (this.deps.flip.isFolding()) {
          this.deps.flip.updateFold(tx, ty);
          return;
        }
        const dx: number = cx - this.touchStartX;
        const dy: number = cy - this.touchStartY;
        if (Math.abs(dx) > Math.abs(dy) * 0.35 && Math.abs(dx) > 24) {
          const ok: boolean = this.deps.flip.beginFold(tx, ty, this.touchStartFullX);
          if (ok) {
            this.hideControls();
            return;
          }
        }
      }
    } else if (event.type === TouchType.Up) {
      if (this.bookmarkPullActive) {
        const pullUpDy: number = cy - this.touchStartY;
        const shouldAdd: boolean = pullUpDy >= ReaderGestureController.PULL_TRIGGER;
        this.deps.onBookmarkPullEnd(shouldAdd);
        this.bookmarkPullActive = false;
        this.touchStartX = 0;
        this.touchStartY = 0;
        this.hasMoved = false;
        this.activePointerId = -1;
        return;
      }
      if (this.longPressTimer > 0) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
        this.longPressClosure = null;
      }
      if (this.deps.flip.isFolding()) {
        this.deps.flip.updateFold(tx, ty);
        this.deps.flip.endFold();
      } else if (this.hasMoved && this.deps.getSelection() === null) {
        // 滑动翻页：方向由翻页方式决定
        const direction: TurnDirection = this.deriveSwipeDirection(cx, cy, contentWidth);
        if (this.isSwipeTurn(cx, cy, contentWidth)) {
          this.hideControls();
          this.turnPage(direction, tx, ty);
        }
      } else if (this.deps.getSelection() === null) {
        // 点击式翻页
        if (this.deps.getSingleHand()) {
          // 单手翻页模式（接口一：单手模式）：点击屏幕左右两侧均为下一页；
          // 中间区域保留呼出控制栏，避免单手模式下无法唤起菜单。
          const tapZone: number = this.tapZoneOf(cx, cy, contentWidth);
          if (tapZone === 0 || tapZone === 2) {
            this.hideControls();
            this.turnPage(TurnDirection.FORWARD, tx, ty);
          } else {
            this.deps.onToggleControls();
          }
        } else {
          // 日常模式（接口二：常规分区模式）——保持目前行为：
          // 左侧点击下一页 / 右侧点击上一页 / 中间呼出控制栏
          const tapZone: number = this.tapZoneOf(cx, cy, contentWidth);
          if (tapZone === 0) {
            this.hideControls();
            this.turnPage(TurnDirection.FORWARD, tx, ty);
          } else if (tapZone === 2) {
            this.hideControls();
            this.turnPage(TurnDirection.BACKWARD, tx, ty);
          } else {
            this.deps.onToggleControls();
          }
        }
      }
      this.touchStartX = 0;
      this.touchStartY = 0;
      this.hasMoved = false;
      this.activePointerId = -1;
    } else if (event.type === TouchType.Cancel) {
      if (this.bookmarkPullActive) {
        this.deps.onBookmarkPullEnd(false);
        this.bookmarkPullActive = false;
      }
      if (this.longPressTimer > 0) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
        this.longPressClosure = null;
      }
      if (this.deps.flip.isFolding()) {
        this.deps.flip.endFold();
      }
      this.touchStartX = 0;
      this.touchStartY = 0;
      this.hasMoved = false;
      this.activePointerId = -1;
    }
  }

  /** 自动翻页激活：点击正文唤起自动翻页控制栏；拖动忽略 */
  private handleAutoTurnTouch(event: TouchEvent, _tx: number, _ty: number,
    _cx: number, _cy: number, _contentWidth: number): void {
    if (event.type === TouchType.Up) {
      this.activePointerId = -1;
      this.hasMoved = false;
      this.deps.onAutoTurnTap();
    } else if (event.type === TouchType.Cancel) {
      this.activePointerId = -1;
      this.hasMoved = false;
    }
  }

  /**
   * 音量键等无触摸点场景的带动画翻页（与点击翻页同一出口）：
   *  - 仿真模式：以内容区中心为锚点播放翻页折叠动画；
   *  - 横滑/上下滑动：以内容区中心为起点播放补间动画；
   *  - 无动效：即时翻页。
   */
  turnPageWithAnimation(direction: TurnDirection): void {
    const contentWidth: number = this.deps.getContentWidth();
    const contentHeight: number = this.deps.getContentHeight();
    const tx: number = Math.max(1, contentWidth / 2);
    const ty: number = Math.max(1, contentHeight / 2);
    this.turnPage(direction, tx, ty);
  }

  /** 统一翻页出口：仿真走折叠动画；横滑/上下滑动走补间（忙/边界回退即时）；其余即时翻页 */
  private turnPage(direction: TurnDirection, tx: number, ty: number): void {
    const mode: ReaderTurnMode = this.deps.getTurnMode();
    if (mode === ReaderTurnMode.SIMULATION) {
      this.deps.flip.playFlip(direction, tx, ty);
    } else if (mode === ReaderTurnMode.HORIZONTAL || mode === ReaderTurnMode.VERTICAL) {
      const slide: FlipGestureAdapter | null = this.deps.getSlideTurn();
      if (slide !== null) {
        const ok: boolean = slide.playFlip(direction, tx, ty);
        if (ok) {
          return;
        }
      }
      this.deps.onQuickTurn(direction);
    } else {
      this.deps.onQuickTurn(direction);
    }
  }

  /** 是否构成滑动翻页（阈值 + 方向模式） */
  private isSwipeTurn(cx: number, cy: number, contentWidth: number): boolean {
    const dx: number = cx - this.touchStartX;
    const dy: number = cy - this.touchStartY;
    const mode: ReaderTurnMode = this.deps.getTurnMode();
    if (mode === ReaderTurnMode.VERTICAL) {
      return Math.abs(dy) > 40 && Math.abs(dy) > Math.abs(dx) * 0.45;
    }
    if (mode === ReaderTurnMode.NONE) {
      // 无动效：允许横滑/上下滑都触发（即时翻页）
      return Math.abs(dx) > 40 || Math.abs(dy) > 40;
    }
    // 仿真/横滑：横向主导
    return Math.abs(dx) > 58 && Math.abs(dx) > Math.abs(dy) * 0.45;
  }

  /** 滑动方向推导（按翻页方式） */
  private deriveSwipeDirection(cx: number, cy: number, contentWidth: number): TurnDirection {
    const dx: number = cx - this.touchStartX;
    const dy: number = cy - this.touchStartY;
    const mode: ReaderTurnMode = this.deps.getTurnMode();
    if (mode === ReaderTurnMode.VERTICAL) {
      // 上滑 → 下一页 FORWARD；下滑 → 上一页 BACKWARD
      return dy < 0 ? TurnDirection.FORWARD : TurnDirection.BACKWARD;
    }
    if (mode === ReaderTurnMode.NONE) {
      if (Math.abs(dy) > Math.abs(dx) * 1.2) {
        return dy < 0 ? TurnDirection.FORWARD : TurnDirection.BACKWARD;
      }
    }
    // 横向主导：左拖 → 下一页；右拖 → 上一页
    return dx < 0 ? TurnDirection.FORWARD : TurnDirection.BACKWARD;
  }

  /** 点击区：0=右半（下一页） 1=中间（切换控制层） 2=左半（上一页） */
  private tapZoneOf(cx: number, _cy: number, contentWidth: number): number {
    if (cx < contentWidth * 0.25) {
      return 2;
    }
    if (cx > contentWidth * 0.75) {
      return 0;
    }
    return 1;
  }

  /** 判断拖动点更靠近选区起点手柄还是终点手柄 */
  private nearStartHandle(cx: number, cy: number, selection: SelectionRange): boolean {
    const lines: LineBox[] = this.deps.getPageLines();
    if (selection.startLineIndex >= 0 && selection.startLineIndex < lines.length &&
      selection.endLineIndex >= 0 && selection.endLineIndex < lines.length) {
      const startLine: LineBox = lines[selection.startLineIndex];
      const endLine: LineBox = lines[selection.endLineIndex];
      const startLocal: number = Math.max(0, selection.startCharOffset - startLine.startCharOffset);
      const endLocal: number = Math.max(0, selection.endCharOffset - endLine.startCharOffset);
      if (startLine.charPositions.length > 0 && endLine.charPositions.length > 0) {
        const sx: number = startLine.charPositions[Math.min(startLocal, startLine.charPositions.length - 1)];
        const sy: number = startLine.renderedY;
        const ex: number = endLine.charPositions[Math.min(endLocal, endLine.charPositions.length - 1)] +
          (endLine.charWidths[Math.min(endLocal, endLine.charWidths.length - 1)] ?? 0);
        const ey: number = endLine.renderedY;
        const dStart: number = (cx - sx) * (cx - sx) + (cy - sy) * (cy - sy);
        const dEnd: number = (cx - ex) * (cx - ex) + (cy - ey) * (cy - ey);
        return dStart <= dEnd;
      }
    }
    return false;
  }
}
