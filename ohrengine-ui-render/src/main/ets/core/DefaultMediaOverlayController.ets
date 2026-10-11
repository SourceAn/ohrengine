/**
 * DefaultMediaOverlayController — 媒体叠加默认空实现
 *
 * 渲染层默认使用此实现，保持对 ohrengine-epub 的零依赖。
 * 状态恒为默认空状态（无 SMIL 加载时与真实控制器行为等价）。
 * 需要完整媒体叠加能力时，可在 OhEngineCore 构造时注入
 * 具体实现（如 ohrengine-epub 的 MediaOverlayController）。
 */

import { IMediaOverlayController, MediaOverlayState,
  createDefaultMediaOverlayState } from 'ohrengine-common';

/**
 * 空实现：不执行任何播放/清理动作，状态始终为默认值
 */
export class DefaultMediaOverlayController implements IMediaOverlayController {
  getState(): MediaOverlayState {
    return createDefaultMediaOverlayState();
  }

  stop(): void {
    // 无操作：没有加载任何 SMIL
  }
}
