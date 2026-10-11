import { display } from '@kit.ArkUI';

/**
 * ReaderTheme —— 阅读器 UI 面板主题（深浅色 + 平板横竖屏适配）
 *
 * - 深浅色：以 AppStorage('darkMode') 为准（由 entry 侧 Index 同步系统深浅色），
 *   面板组件需声明 @StorageProp('darkMode') 以响应系统切换自动重建；
 *   本模块颜色与阅读正文主题（Theme）解耦，仅服务 UI 面板/浮层。
 * - 平板横竖屏：screenWidthVp() 实时读取屏宽（vp），面板按断点自适应，
 *   组件在 aboutToAppear / onAreaChange 中计算并缓存到 @State。
 */

/** 当前是否深色模式（读取 AppStorage('darkMode')） */
export function readerIsDark(): boolean {
  return AppStorage.get<boolean>('darkMode') ?? false;
}

/** 当前屏幕宽度（vp）；读取失败时回退 360（手机竖屏基准） */
export function screenWidthVp(): number {
  try {
    const d = display.getDefaultDisplaySync();
    return d.width / d.densityPixels;
  } catch (e) {
    return 360;
  }
}

/** 当前屏幕高度（vp）；读取失败时回退 780 */
export function screenHeightVp(): number {
  try {
    const d = display.getDefaultDisplaySync();
    return d.height / d.densityPixels;
  } catch (e) {
    return 780;
  }
}

/** 平板 / 大屏断点（vp）：宽度 >= 600 视为平板横竖屏场景 */
export function isWideScreen(): boolean {
  return screenWidthVp() >= 600;
}

/**
 * 卡片 / 浮层面板宽度（vp）：
 * - 窄屏（手机）：取原设计宽（fit 内不超过 屏宽-32 防止溢出）；
 * - 平板 / 大屏：放大到 屏宽一半（上限 tabletMax），视觉协调不铺满。
 */
export function adaptivePanelWidth(phoneWidth: number, tabletMax: number = 480): number {
  const w: number = screenWidthVp();
  const minW: number = Math.min(phoneWidth, w - 32);
  if (w >= 600) {
    return Math.min(Math.max(phoneWidth, w * 0.5), tabletMax);
  }
  return Math.max(minW, 240);
}

/** 阅读器 UI 面板主题色（深浅色双套，静态 getter 跟随 AppStorage('darkMode')） */
export class ReaderTheme {
  /** 主文字 / 图标 */
  static get textPrimary(): string {
    return readerIsDark() ? '#E3E5E8' : '#2B2B2B';
  }

  /** 次级文字 / 图标 */
  static get textSecondary(): string {
    return readerIsDark() ? '#AEB4BA' : '#4A4F55';
  }

  /** 弱辅助文字（时间戳 / 说明 / 未激活） */
  static get textTertiary(): string {
    return readerIsDark() ? '#8A8A8E' : '#9AA0A6';
  }

  /** 占位 / 禁用文字 */
  static get textPlaceholder(): string {
    return readerIsDark() ? '#5A5F66' : '#B3B3B8';
  }

  /** 主强调色（链接 / 激活态文字） */
  static get accent(): string {
    return readerIsDark() ? '#5BB5FF' : '#2679E8';
  }

  /** 危险 / 退出 */
  static get danger(): string {
    return readerIsDark() ? '#FF6B6B' : '#E5484D';
  }

  /** 卡片 / 面板底 */
  static get bgCard(): string {
    return readerIsDark() ? '#1C1C1E' : '#FFFFFF';
  }

  /** 底部抽屉 / 大浮层面板底 */
  static get bgSheet(): string {
    return readerIsDark() ? 'rgba(28,28,30,0.96)' : 'rgba(255,255,255,0.97)';
  }

  /** 行 / 胶囊底色（轻灰） */
  static get bgSoft(): string {
    return readerIsDark() ? '#2C2C2E' : '#F2F2F7';
  }

  /** 分割线 / 描边 */
  static get divider(): string {
    return readerIsDark() ? '#3A3A3C' : '#E5E5EA';
  }

  /** 遮罩 / 覆盖层 */
  static get scrim(): string {
    return readerIsDark() ? 'rgba(0,0,0,0.60)' : 'rgba(0,0,0,0.35)';
  }

  /** 轻覆盖（按压 / 行选中底） */
  static get scrimLight(): string {
    return readerIsDark() ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.08)';
  }
}
