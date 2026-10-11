/**
 * ControlSpec — 底部菜单栏控制条统一尺寸规范。
 *
 * 阅读进度条 / 字号滑杆 / 行距滑杆共享同一套尺寸参数，
 * 保证所有进度条长度一致、触控区域与轨道水平垂直居中、视觉统一。
 */
export class ControlSpec {
  /** 控制行固定高度（胶囊容器内） */
  static readonly ROW_H: number = 48;
  /** 轨道中心 Y（垂直完全居中） */
  static readonly CENTER_Y: number = 24;
  /** 轨道高度（进度条 / 字号 / 行距统一） */
  static readonly TRACK_H: number = 28;
  /** 滑块圆点直径（白色圆点，进度条与滑杆统一） */
  static readonly THUMB: number = 28;
  /** 拖动时滑块宽度（胶囊形 1.5x） */
  static readonly ACTIVE_THUMB_W: number = 42;
  /** 触控热区（以滑块中心为中点的水平判定带） */
  static readonly TOUCH_BAND: number = 48;
  /** 档位点安全边界（两侧留白，避免圆点贴近侧边图示） */
  static readonly SAFE: number = 12;

  // ==================== 底部菜单 / 顶部栏 几何 ====================
  /** 功能胶囊统一高度（背景/翻页方式/深色/设置等） */
  static readonly FUNC_CAPSULE_H: number = 48;
  /** 功能胶囊行高（含上下内边距） */
  static readonly FUNC_ROW_H: number = 53;
  /** 底部安全间距（距底部导航栏） */
  static readonly BOTTOM_SAFE: number = 6;
  /** 顶部圆形按钮直径 */
  static readonly TOP_BAR_BUTTON: number = 46;
  /** 顶部栏按钮底边（avoidTop + 按钮高 → 弹窗锚点） */
  static readonly TOP_BAR_BOTTOM: number = 56;
}