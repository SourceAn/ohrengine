/**
 * ThemeTypes — 主题与字体主题的纯数据类型（ARCH-003）
 *
 * 将 Feature 中的纯数据（Theme/FontTheme 及预设常量）下沉到 common，
 * 使 ui-render 排版核心依赖 common 类型而非 feature 业务类，
 * 解除 ui-render → feature 的结构性耦合。
 *
 * 职责边界：
 * - 仅承载数据类型与预设常量，不含状态/持久化/事件逻辑。
 * - ThemeManager / FontThemeManager（状态与订阅）仍留在 ohrengine-feature，
 *   其类型依赖此处，由 Runtime 装配注入到排版核心。
 */

/** 阅读主题（颜色方案） */
export interface Theme {
  id: string;
  name: string;
  backgroundColor: string;
  textColor: string;
  linkColor: string;
  uiBackgroundColor: string;
  uiTextColor: string;
  uiBorderColor?: string;
  highlightColors?: string[];
  statusBarStyle?: 'light' | 'dark';
  imageFilter?: 'none' | 'dim' | 'invert';
}

/** 内置阅读主题预设 */
export const PRESET_THEMES: Theme[] = [
  {
    id: 'day', name: '白天', backgroundColor: '#FFFFFF', textColor: '#333333',
    linkColor: '#1A73E8', uiBackgroundColor: '#F5F5F5', uiTextColor: '#333333',
    statusBarStyle: 'dark', imageFilter: 'none'
  },
  {
    id: 'night', name: '夜间', backgroundColor: '#1A1A1A', textColor: '#CCCCCC',
    linkColor: '#4A9BFF', uiBackgroundColor: '#2A2A2A', uiTextColor: '#CCCCCC',
    statusBarStyle: 'light', imageFilter: 'dim'
  },
  {
    id: 'sepia', name: '护眼', backgroundColor: '#F5E6C8', textColor: '#5C4B37',
    linkColor: '#0066CC', uiBackgroundColor: '#E8D5B0', uiTextColor: '#5C4B37',
    statusBarStyle: 'dark', imageFilter: 'none'
  },
  {
    id: 'green', name: '绿色', backgroundColor: '#C7EDCC', textColor: '#3B5E3B',
    linkColor: '#006633', uiBackgroundColor: '#B5D8BA', uiTextColor: '#3B5E3B',
    statusBarStyle: 'dark', imageFilter: 'none'
  },
  {
    id: 'blue', name: '浅蓝', backgroundColor: '#D6EAF8', textColor: '#2C3E50',
    linkColor: '#1A5276', uiBackgroundColor: '#C5DFF0', uiTextColor: '#2C3E50',
    statusBarStyle: 'dark', imageFilter: 'none'
  },
  {
    id: 'pink', name: '浅粉', backgroundColor: '#FADBD8', textColor: '#5D4037',
    linkColor: '#8E4A49', uiBackgroundColor: '#F0C9C5', uiTextColor: '#5D4037',
    statusBarStyle: 'dark', imageFilter: 'none'
  },
  {
    id: 'purple', name: '浅紫', backgroundColor: '#E8DAEF', textColor: '#4A3B5C',
    linkColor: '#6C4F8E', uiBackgroundColor: '#DCC9E8', uiTextColor: '#4A3B5C',
    statusBarStyle: 'dark', imageFilter: 'none'
  },
  {
    id: 'teal', name: '墨绿', backgroundColor: '#D0E8E0', textColor: '#2E4A43',
    linkColor: '#1E6E5E', uiBackgroundColor: '#BCD8CE', uiTextColor: '#2E4A43',
    statusBarStyle: 'dark', imageFilter: 'none'
  },
];

/** 字体主题（排版字体族方案） */
export interface FontTheme {
  id: string;
  name: string;
  /** Main reading font-family string (CSS font-family value, comma-separated fallbacks) */
  fontFamily: string;
  /** CJK-optimized font name (for Chinese/Japanese text specifically) */
  cjkFontFamily?: string;
  /** Monospace override for code blocks */
  monospaceOverride?: string;
  /** Preset font size in vp (applied when theme is switched) */
  fontSizePreset?: number;
  /** Preset line spacing increment in vp */
  lineSpacingPreset?: number;
  /**
   * Font loading strategy:
   *   - 'none': use system fonts
   *   - 'built-in': font is bundled in the app resources
   *   - 'loadable': font must be registered via font.registerFont() at runtime
   */
  loadingStrategy: 'none' | 'built-in' | 'loadable';
  /** File path to the font resource (used when loadingStrategy is 'loadable') */
  loadPath?: string;
}

/**
 * 字体主题提供者端口（ARCH-003）——ui-render 排版核心仅依赖此最小接口，
 * 不直接依赖 ohrengine-feature 的 FontThemeManager 类。实现由 Runtime 装配
 * 注入（feature 的 FontThemeManager 满足该结构）。
 */
export interface IFontThemeProvider {
  readonly currentTheme: FontTheme;
}

/** 内置字体主题预设 */
export const FONT_THEMES: FontTheme[] = [
  {
    id: 'serif', name: '衬线',
    fontFamily: 'Noto Serif CJK SC, Source Han Serif SC, STSong, SimSun, serif',
    cjkFontFamily: 'Noto Serif CJK SC',
    monospaceOverride: 'Courier New, Consolas, monospace',
    fontSizePreset: 18, lineSpacingPreset: 8, loadingStrategy: 'none'
  },
  {
    id: 'sans-serif', name: '无衬线',
    fontFamily: 'HarmonyOS Sans, Noto Sans CJK SC, Source Han Sans SC, PingFang SC, sans-serif',
    cjkFontFamily: 'HarmonyOS Sans',
    monospaceOverride: 'Courier New, Consolas, monospace',
    fontSizePreset: 18, lineSpacingPreset: 6, loadingStrategy: 'none'
  },
  {
    id: 'monospace', name: '等宽',
    fontFamily: 'Courier New, Source Code Pro, Consolas, monospace',
    cjkFontFamily: 'HarmonyOS Sans',
    monospaceOverride: 'Courier New, Consolas, monospace',
    fontSizePreset: 16, lineSpacingPreset: 10, loadingStrategy: 'none'
  },
  {
    id: 'handwriting', name: '手写',
    fontFamily: 'KaiTi, STKaiti, DFKai-SB, serif',
    cjkFontFamily: 'KaiTi',
    monospaceOverride: 'Courier New, Consolas, monospace',
    fontSizePreset: 20, lineSpacingPreset: 8, loadingStrategy: 'none'
  }
];
