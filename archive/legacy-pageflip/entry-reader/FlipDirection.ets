/*
 * FlipDirection.ets — 翻页方向推导唯一纯函数（0.9，FR-013）
 *
 * 统一方向推导规则：点击式翻页（synthetic gesture）与拖拽式翻页共用本函数，
 * 不存在第二份方向判断逻辑。方向在 beginGesture 时确定后整个手势生命周期不可变。
 *
 * 坐标空间标注（0.9/0.14）：本函数入参全部为**内容坐标系（vp）**——
 * downX/downY/touchX/touchY/contentW 均为未经 Surface px 换算的内容 vp 坐标，
 * 与 beginGesture 使用的 Surface px（xPx/yPx）是两个独立坐标空间，禁止混用。
 */
import { TurnDirection } from 'ohrengine-common';

/**
 * 推导翻页方向（0.9 公式，唯一实现）。
 *
 * forwardSign = spine === 'right' ? 1 : -1
 * dx = touchX - downX；dy = touchY - downY
 * |dx| > |dy| * 0.35
 *   ? (dx * forwardSign > 0 ? FORWARD : BACKWARD)            // 横向位移主导
 *   : ((downX - contentW / 2) * forwardSign < 0 ? FORWARD : BACKWARD)  // 纵向位移主导
 *
 * @param downX 按下点 x（内容 vp）
 * @param downY 按下点 y（内容 vp）
 * @param touchX 当前/释放点 x（内容 vp）
 * @param touchY 当前/释放点 y（内容 vp）
 * @param spine 书脊 'left' | 'right'
 * @param contentW 内容区宽（vp）
 */
export function deriveFlipDirection(downX: number, downY: number,
  touchX: number, touchY: number, spine: string, contentW: number): TurnDirection {
  const forwardSign: number = spine === 'right' ? 1 : -1;
  const dx: number = touchX - downX;
  const dy: number = touchY - downY;
  let dir: number = 0;
  if (Math.abs(dx) > Math.abs(dy) * 0.35) {
    dir = dx * forwardSign > 0 ? 1 : -1;
  } else {
    // 纵向位移主导 / 点击（down==touch）：按按下点所在半区推断。
    // 注意符号取反：spine=left 时 forwardSign=-1，点击右半区应判 FORWARD（与
    // 旧 ReaderGestureController 点击翻页分支 x>contentWidth*0.75 → FORWARD 等价，
    // 0.9"等价 direction 值"要求），故用 `< 0` 而非 `> 0`。
    dir = (downX - contentW / 2) * forwardSign < 0 ? 1 : -1;
  }
  return dir > 0 ? TurnDirection.FORWARD : TurnDirection.BACKWARD;
}
