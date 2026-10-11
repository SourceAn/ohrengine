/*
 * GlFlipEngine.ets — ArkTS 侧薄封装（调用 libohrengine_gl.so 的 N-API 方法）
 *
 * 职责边界（Phase A，T026）：
 *  - 只做参数转换（PixelMap → RGBA ArrayBuffer、意图枚举编组）与 native 调用转发；
 *  - 不包含任何翻页状态机/业务逻辑/动画物理（0.6：速度/时长/阈值判定全部迁移
 *    native 状态机）；翻页逻辑仍在 reader/PageFlipController.ets。
 *  - 所有位置参数为 Surface 坐标系 px（0.14，经 controller 侧 glPx/glPy 换算后传入）。
 *
 * 意图级 API（0.6/0.13，FR-021）：
 *  beginGesture(direction, spine, downX, downY, model, synthetic?)
 *    → BeginGestureResult{operationToken, success, failureReason}
 *  updateGesture(token, x, y, timestampMs)
 *  endGesture(token, x, y)
 *  cancelGesture(token)
 *  beginReboundRecovery(prevToken, direction) → BeginGestureResult
 *  releaseTextureTransaction(token)
 *  完成回调 payload {token, result} 经常驻 TSFN 回调传入（setCompletionHandler 注册）。
 *
 * 已移除（0.6/0.14）：setTouch/beginAnimation/endAnimation 及
 * animToX/animToY/animMs/velX/velY 参数（ArkTS 不再计算速度/时长/阈值）。
 */
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CurlModel } from 'ohrengine-common';

/** 书脊方向（与 reader 侧约定一致） */
export type FlipSpine = 'left' | 'right';

/** 翻页方向（与 ohrengine-common TurnDirection 数值约定：1=FORWARD / -1=BACKWARD） */
export const FLIP_FORWARD: number = 1;
export const FLIP_BACKWARD: number = -1;

/** beginGesture 失败原因（0.6；与 native FailureReason 数值一致） */
export enum GestureFailureReason {
  NONE = 0,
  TSFN_UNAVAILABLE = 1,
  OPERATION_IN_PROGRESS = 2,
  TOKEN_EXHAUSTED = 3,
  NO_RETAINED_TRANSACTION = 4
}

/** 结构化返回值（0.6）：失败时 operationToken 恒为 0 */
export interface BeginGestureResult {
  operationToken: number;
  success: boolean;
  failureReason: GestureFailureReason;
}

/** 完成回调结果（0.6/0.10，与 native FlipResult 语义一致） */
export type FlipCompletionResult = 'completed' | 'rebound';
/** 完成回调签名：token + result（双向校验，0.13） */
export type FlipCompletionHandler = (token: number, result: string) => void;

/**
 * native context 接口（= InitModule exports，经 onLoad/getXComponentContext 获取）。
 * 与 ohrengine-gl/src/main/cpp/napi/napi_init.cpp 的 napi_define_properties
 * 严格一致（T030 核验项）。
 */
interface NativeFlipContext {
  init(): boolean;
  setDisplayRefreshRate(rate: number): void;
  setTextures(front: ArrayBuffer, frontW: number, frontH: number,
    back: ArrayBuffer, backW: number, backH: number,
    frontKey: string, backKey: string): boolean;
  setCompletionHandler(handler: (token: number, result: string) => void): void;
  beginGesture(direction: number, spine: number, downX: number, downY: number,
    model: number, synthetic?: number, pageGeneration?: number): BeginGestureResult;
  updateGesture(token: number, x: number, y: number, timestampMs: number): void;
  endGesture(token: number, x: number, y: number): void;
  cancelGesture(token: number): void;
  beginReboundRecovery(prevToken: number, direction: number): BeginGestureResult;
  releaseTextureTransaction(token: number): void;
  destroy(): void;
}

/**
 * GL 翻页引擎薄封装（静态类）。
 * 调用方式沿用第四轮约定：XComponent libraryname 加载 → onLoad context
 * （InitModule exports）类型化为 NativeFlipContext 后调用。
 */
export class GlFlipEngine {
  private static ready: boolean = false;
  /** onLoad context（= InitModule exports）引用 */
  private static ctx: NativeFlipContext | null = null;
  private static configuredRefreshRate: number = 60;
  /** 完成回调（native 常驻 TSFN → setCompletionHandler） */
  private static completionHandler: FlipCompletionHandler | null = null;

  /** 查询 GL 引擎就绪状态（surface 创建 + EGL 初始化完成） */
  static isReady(): boolean {
    return GlFlipEngine.ready;
  }

  /**
   * XComponent onLoad 时调用：保存 native context 并查询就绪状态。
   * @param context 官方 onLoad context（getXComponentContext() 或 onLoad event）
   */
  static async onSurfaceLoaded(context: Object): Promise<void> {
    try {
      const ctx: NativeFlipContext = context as NativeFlipContext;
      GlFlipEngine.ctx = ctx;
      ctx.setDisplayRefreshRate(GlFlipEngine.configuredRefreshRate);
      GlFlipEngine.ready = ctx.init();
      // 重新注册完成回调（surface 重建后 TSFN 重新建立）
      if (GlFlipEngine.completionHandler !== null) {
        ctx.setCompletionHandler(GlFlipEngine.completionHandler);
      }
      hilog.info(0x3900, 'OhEngine', 'GlFlipEngine.onSurfaceLoaded: ready=%{public}s',
        GlFlipEngine.ready ? 'true' : 'false');
    } catch (e) {
      hilog.error(0x3900, 'OhEngine', 'GlFlipEngine.onSurfaceLoaded failed: %{public}s', String(e));
      GlFlipEngine.ready = false;
    }
  }

  /**
   * 注册完成回调（常驻 TSFN 目标函数）。回调签名 (token, result)，
   * result ∈ 'completed' | 'rebound'。ArkTS 侧必须按 0.13 双向校验 token。
   */
  static setCompletionHandler(handler: FlipCompletionHandler): void {
    GlFlipEngine.completionHandler = handler;
    GlFlipEngine.ctx?.setCompletionHandler(handler);
  }

  static setDisplayRefreshRate(rate: number): void {
    GlFlipEngine.configuredRefreshRate = Math.round(rate);
    GlFlipEngine.ctx?.setDisplayRefreshRate(GlFlipEngine.configuredRefreshRate);
  }

  /**
   * 上传翻页纹理（正页 + 底页）。必须在 beginGesture 之前完成，
   * native 以 beginGesture 返回的 operationToken 登记纹理事务（0.12）。
   */
  static async setTextures(front: image.PixelMap, bottom: image.PixelMap | null,
    frontKey: string, bottomKey: string): Promise<boolean> {
    if (!GlFlipEngine.ready) {
      return false;
    }
    try {
      const frontInfo = front.getImageInfoSync();
      const fw: number = frontInfo.size.width;
      const fh: number = frontInfo.size.height;
      const frontBuf: ArrayBuffer = new ArrayBuffer(front.getPixelBytesNumber());
      await front.readPixelsToBuffer(frontBuf);
      let bw: number = fw;
      let bh: number = fh;
      let backBuf: ArrayBuffer = frontBuf;
      if (bottom !== null) {
        const backInfo = bottom.getImageInfoSync();
        bw = backInfo.size.width;
        bh = backInfo.size.height;
        backBuf = new ArrayBuffer(bottom.getPixelBytesNumber());
        await bottom.readPixelsToBuffer(backBuf);
      }
      hilog.info(0x3900, 'OhEngine',
        'setTextures roles frontKey=%{public}s bottomKey=%{public}s front=%{public}dx%{public}d bottom=%{public}dx%{public}d',
        frontKey, bottomKey, fw, fh, bw, bh);
      return GlFlipEngine.ctx?.setTextures(frontBuf, fw, fh, backBuf, bw, bh,
        frontKey, bottomKey) ?? false;
    } catch (e) {
      return false;
    }
  }

  /**
   * 开始一次翻页手势（意图级，0.6/0.13）。
   * @param direction 1=FORWARD / -1=BACKWARD（beginGesture 锁定，生命周期内不可变）
   * @param spine 'left' | 'right'
   * @param downX 按下点 x（Surface px）
   * @param downY 按下点 y（Surface px）
   * @param model 卷曲模型（CurlModel）
   * @param synthetic 合成手势（点击翻页，缺省 false）
   * @param pageGeneration 当前 pageGeneration 快照（诊断副本；校验以 ArkTS 为准）
   * @returns BeginGestureResult{operationToken, success, failureReason}
   */
  static beginGesture(direction: number, spine: string, downX: number, downY: number,
    model: CurlModel, synthetic: boolean = false,
    pageGeneration: number = 0): BeginGestureResult {
    const invalid: BeginGestureResult = {
      operationToken: 0,
      success: false,
      failureReason: GestureFailureReason.TSFN_UNAVAILABLE
    };
    if (!GlFlipEngine.ready) {
      return invalid;
    }
    const ctx: NativeFlipContext | null = GlFlipEngine.ctx;
    if (ctx === null) {
      return invalid;
    }
    try {
      return ctx.beginGesture(direction, spine === 'right' ? 1 : 0, downX, downY,
        model, synthetic ? 1 : 0, pageGeneration);
    } catch (e) {
      hilog.error(0x3900, 'OhEngine', 'beginGesture failed: %{public}s', String(e));
      return invalid;
    }
  }

  /** 更新手势（Surface px 坐标 + 单调时间戳 ms，0.14） */
  static updateGesture(token: number, touchX: number, touchY: number,
    timestampMs: number): void {
    if (!GlFlipEngine.ready || token <= 0) {
      return;
    }
    GlFlipEngine.ctx?.updateGesture(token, touchX, touchY, timestampMs);
  }

  /** 结束手势（释放位置，Surface px）；判定/速度由 native 状态机负责 */
  static endGesture(token: number, releaseX: number, releaseY: number): void {
    if (!GlFlipEngine.ready || token <= 0) {
      return;
    }
    GlFlipEngine.ctx?.endGesture(token, releaseX, releaseY);
  }

  /** 取消手势（系统打断）：native 立即 B1 清屏并回 Idle */
  static cancelGesture(token: number): void {
    if (!GlFlipEngine.ready || token <= 0) {
      return;
    }
    GlFlipEngine.ctx?.cancelGesture(token);
  }

  /**
   * 合成回弹补救（0.12，Phase A 仅提供绑定；完整集成在 gated Phase B）。
   * 复用 prevToken 对应的保留期纹理事务，播放回弹动画。
   */
  static beginReboundRecovery(prevToken: number, direction: number): BeginGestureResult {
    const invalid: BeginGestureResult = {
      operationToken: 0,
      success: false,
      failureReason: GestureFailureReason.NO_RETAINED_TRANSACTION
    };
    if (!GlFlipEngine.ready || prevToken <= 0) {
      return invalid;
    }
    const ctx: NativeFlipContext | null = GlFlipEngine.ctx;
    if (ctx === null) {
      return invalid;
    }
    try {
      return ctx.beginReboundRecovery(prevToken, direction);
    } catch (e) {
      hilog.error(0x3900, 'OhEngine', 'beginReboundRecovery failed: %{public}s', String(e));
      return invalid;
    }
  }

  /** 显式释放纹理事务（ArkTS 确定最终结果后调用；超时由 native 自动清理） */
  static releaseTextureTransaction(token: number): void {
    if (!GlFlipEngine.ready || token <= 0) {
      return;
    }
    GlFlipEngine.ctx?.releaseTextureTransaction(token);
  }

  /** 释放全部 GL 资源（aboutToDisappear 调用） */
  static destroy(): void {
    if (GlFlipEngine.ready) {
      try {
        GlFlipEngine.ctx?.destroy();
      } catch (e) {
        // 忽略释放异常
      }
    }
    GlFlipEngine.ready = false;
  }
}
