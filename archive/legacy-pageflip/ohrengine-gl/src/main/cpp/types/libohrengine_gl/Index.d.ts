/**
 * ohrengine-gl native 模块类型声明（libohrengine_gl.so）
 *
 * Phase A（T030）：native 已改为意图级 API（napi/napi_init.cpp exports）。
 * ArkTS 侧仍经 onLoad context 调用（XComponent libraryname 加载路径），
 * GlFlipEngine.ets 的 NativeFlipContext interface 与本声明保持一致。
 *
 * 坐标契约（0.14）：所有位置参数为 Surface px（ArkTS 侧 glPx/glPy 之后）。
 * 完成回调：常驻 TSFN → setCompletionHandler(cb)，cb(token, result)。
 */

/** 查询 GL 引擎就绪状态（EGL surface 已创建）。 */
export const init: () => boolean;

/** 设置显示刷新率（影响 soloist 期望帧率档位裁剪）。 */
export const setDisplayRefreshRate: (rate: number) => void;

/**
 * 上传翻起页/底页纹理（RGBA8888 原始像素），缓存双槽 ping-pong。
 * 必须在 beginGesture 之前完成，native 以返回的 operationToken 登记纹理事务。
 */
export const setTextures: (front: ArrayBuffer, frontW: number, frontH: number,
  back: ArrayBuffer, backW: number, backH: number,
  frontKey: string, backKey: string) => boolean;

/**
 * 注册完成回调（常驻 TSFN 目标函数）。
 * @param handler 完成回调 (token: number, result: 'completed'|'rebound') => void
 */
export const setCompletionHandler: (handler: (token: number, result: string) => void) => void;

/**
 * 开始一次翻页手势（意图级，0.6/0.13）。
 * @param direction 1=FORWARD / -1=BACKWARD（beginGesture 锁定）
 * @param spine 0=left / 1=right
 * @param downX 按下点 x（Surface px）
 * @param downY 按下点 y（Surface px）
 * @param model 卷曲模型 0=CYLINDER / 1=CONE / 2=HYBRID
 * @param synthetic 可选：1=合成手势（点击翻页）
 * @param pageGeneration 可选：pageGeneration 快照副本（诊断）
 * @returns BeginGestureResult {operationToken, success, failureReason}
 */
export const beginGesture: (direction: number, spine: number,
  downX: number, downY: number, model: number,
  synthetic?: number, pageGeneration?: number) => BeginGestureResult;

/**
 * 更新手势（Surface px 坐标 + 单调时间戳 ms）。
 * 完成/回弹判定、速度估算由 native 状态机负责（ArkTS 不传速度）。
 */
export const updateGesture: (token: number, x: number, y: number, timestampMs: number) => void;

/** 结束手势（释放位置，Surface px）。 */
export const endGesture: (token: number, x: number, y: number) => void;

/** 取消手势（系统打断）：native 立即 B1 清屏并回 Idle。 */
export const cancelGesture: (token: number) => void;

/**
 * 合成回弹补救（0.12）。复用 prevToken 对应的保留期纹理事务播放回弹动画。
 * @returns BeginGestureResult（成功时 operationToken = 新 recovery token）
 */
export const beginReboundRecovery: (prevToken: number, direction: number) => BeginGestureResult;

/** 显式释放纹理事务（ArkTS 确定最终结果后调用；超时由 native 自动清理）。 */
export const releaseTextureTransaction: (token: number) => void;

/** 释放 EGL/GL/纹理资源（页面销毁时调用）。 */
export const destroy: () => void;

/** 结构化返回值（0.6）：失败时 operationToken 恒为 0。 */
export interface BeginGestureResult {
  operationToken: number;
  success: boolean;
  failureReason: number;
}
