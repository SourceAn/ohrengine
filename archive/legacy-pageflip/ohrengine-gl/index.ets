/*
 * ohrengine-gl — Public API
 *
 * GLES page-curl flip engine：XComponent(SURFACE) + GL shader 渲染，
 * soloist 独立帧回调，帧率按设备刷新率和交互阶段动态调整。
 * GL 初始化失败由上层显示明确不可用状态，不再回退 2D 翻页。
 *
 * 意图级 API（0.6/0.13/FR-021）：beginGesture→BeginGestureResult、
 * updateGesture(token,x,y,timestampMs)、endGesture(token,x,y)、
 * cancelGesture(token)、beginReboundRecovery、releaseTextureTransaction。
 * 完成回调 payload {token, result} 经 setCompletionHandler 注册的常驻回调返回。
 */
export { GlFlipSurface } from './src/main/ets/GlFlipSurface.ets';
export { GlFlipEngine } from './src/main/ets/GlFlipEngine.ets';
export type { BeginGestureResult, FlipCompletionHandler } from './src/main/ets/GlFlipEngine.ets';
export { GestureFailureReason } from './src/main/ets/GlFlipEngine.ets';
