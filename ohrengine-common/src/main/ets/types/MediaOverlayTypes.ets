/**
 * MediaOverlayTypes — 媒体叠加通用状态类型
 *
 * 从 ohrengine-epub 的 MediaOverlayTypes.ets 拆分而来：
 * - SMIL 领域类型（SmilFile/SmilPar 等）保留在 ohrengine-epub
 * - 通用播放状态类型下沉到 ohrengine-common，供渲染层解耦引用
 */

/**
 * 媒体叠加播放状态
 */
export interface MediaOverlayState {
  /** 是否正在播放 */
  isPlaying: boolean;
  /** 当前播放的 SMIL 文件路径 */
  currentSmil: string;
  /** 当前播放段落索引 */
  currentParIndex: number;
  /** 总段落数 */
  totalPars: number;
  /** 当前高亮文本片段列表 { epubCfis: string[], bounds: HighlightBounds[] } */
  highlightBounds: HighlightBounds[];
  /** 播放进度（0–1） */
  progress: number;
}

/**
 * 高亮矩形区域（在页面坐标中）
 */
export interface HighlightBounds {
  /** 行 X 坐标 */
  x: number;
  /** 行 Y 坐标 */
  y: number;
  /** 高亮宽度 */
  width: number;
  /** 高亮高度 */
  height: number;
  /** 高亮颜色（默认 #FFFF0066） */
  color: string;
}

/**
 * 创建默认 MediaOverlayState
 */
export function createDefaultMediaOverlayState(): MediaOverlayState {
  return {
    isPlaying: false,
    currentSmil: '',
    currentParIndex: 0,
    totalPars: 0,
    highlightBounds: [],
    progress: 0
  };
}

/**
 * 媒体叠加控制器接口
 *
 * 渲染层（ohrengine-ui-render）仅依赖此接口，
 * 具体实现由 ohrengine-epub 的 MediaOverlayController 或
 * ui-render 内建的空实现提供。
 */
export interface IMediaOverlayController {
  /** 获取当前播放/高亮状态 */
  getState(): MediaOverlayState;
  /** 停止播放并清理 */
  stop(): void;
}
