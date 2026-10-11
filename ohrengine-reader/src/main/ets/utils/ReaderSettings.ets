/**
 * ReaderSettings — 阅读器设置持久化（Preferences）
 *
 * 存储阅读器全局设置：
 *  - 翻页方式（仿真/横滑/上下滑动/无动效）
 *  - 单手模式开关
 *  - 页码显示模式（章节页数 / 总进度）
 *  - 自动翻页速度倍率（0.5x – 1.5x，1.0 为基准）
 *  - 眼动翻页开关（占位）
 *  - 对齐方式（左/右/自动/两端）
 */
import { preferences } from '@kit.ArkData';

/** 翻页方式 */
export enum ReaderTurnMode {
  SIMULATION = 'simulation',
  HORIZONTAL = 'horizontal',
  VERTICAL = 'vertical',
  NONE = 'none'
}

/** 页码显示模式 */
export enum ReaderPageNumberMode {
  /** 章节页数：本章第 X 页 / 本章共 Y 页（如 1/68） */
  CHAPTER = 'chapter',
  /** 总页数：当前页 / 全书总页数（无百分比） */
  TOTAL = 'progress',
  /** 进度百分比：仅百分比（如 34%） */
  PERCENT = 'percent'
}

/** 对齐方式（引擎 LayoutProfile.textAlign 直通；'auto' = 不覆盖，用引擎/书本默认） */
export type ReaderTextAlign = 'left' | 'right' | 'auto' | 'justify' | 'center';

export interface ReaderSettingsData {
  turnMode: ReaderTurnMode;
  singleHand: boolean;
  pageNumberMode: ReaderPageNumberMode;
  autoSpeed: number;      // 0.5 ~ 1.5
  eyeTracking: boolean;   // 占位
  textAlign: ReaderTextAlign;
  /** 字号档位 1~9 */
  fontSizeLevel: number;
  /** 行距档位 1~5 */
  lineSpacingLevel: number;
}

export function createDefaultReaderSettings(): ReaderSettingsData {
  return {
    turnMode: ReaderTurnMode.SIMULATION,
    singleHand: false,
    pageNumberMode: ReaderPageNumberMode.TOTAL,
    autoSpeed: 1.0,
    eyeTracking: false,
    textAlign: 'justify',
    fontSizeLevel: 5,
    lineSpacingLevel: 3
  };
}

/** 字号 10 档（fp，Apple Books 极简控制面板 n/10 规格；末位新增不影响既有 1~9 档语义） */
export const FONT_SIZE_LEVELS: number[] = [12, 13, 15, 16, 17, 19, 21, 24, 28, 33];
/** 行距 5 档（vp，行间额外间距） */
export const LINE_SPACING_LEVELS: number[] = [0, 2, 4, 6, 9];
/** 设计稿行距三档（紧凑/标准/宽松）映射到底层 5 档的档位值 */
export const LINE_SPACING_PRESETS: number[] = [1, 3, 5];

export class ReaderSettings {
  private static readonly PREFS_NAME: string = 'reader_settings_prefs';

  async save(ctx: Context, data: ReaderSettingsData): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, ReaderSettings.PREFS_NAME);
      await store.put('turnMode', data.turnMode);
      await store.put('singleHand', data.singleHand);
      await store.put('pageNumberMode', data.pageNumberMode);
      await store.put('autoSpeed', data.autoSpeed);
      await store.put('eyeTracking', data.eyeTracking);
      await store.put('textAlign', data.textAlign);
      await store.put('fontSizeLevel', data.fontSizeLevel);
      await store.put('lineSpacingLevel', data.lineSpacingLevel);
      await store.flush();
    } catch (_e) {
    }
  }

  async load(ctx: Context): Promise<ReaderSettingsData> {
    const defaults: ReaderSettingsData = createDefaultReaderSettings();
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, ReaderSettings.PREFS_NAME);
      const settings: ReaderSettingsData = createDefaultReaderSettings();
      const turnModeVal: preferences.ValueType = await store.get('turnMode', defaults.turnMode);
      settings.turnMode = this.toTurnMode(turnModeVal as string);
      const singleVal: preferences.ValueType = await store.get('singleHand', defaults.singleHand);
      settings.singleHand = singleVal as boolean;
      const pageVal: preferences.ValueType = await store.get('pageNumberMode', defaults.pageNumberMode);
      settings.pageNumberMode = this.toPageNumberMode(pageVal as string);
      const speedVal: preferences.ValueType = await store.get('autoSpeed', defaults.autoSpeed);
      settings.autoSpeed = this.clampSpeed(speedVal as number);
      const eyeVal: preferences.ValueType = await store.get('eyeTracking', defaults.eyeTracking);
      settings.eyeTracking = eyeVal as boolean;
      const alignVal: preferences.ValueType = await store.get('textAlign', defaults.textAlign);
      settings.textAlign = this.toTextAlign(alignVal as string);
      const fontVal: preferences.ValueType = await store.get('fontSizeLevel', defaults.fontSizeLevel);
      settings.fontSizeLevel = this.clampInt(fontVal as number, 1, FONT_SIZE_LEVELS.length);
      const lineVal: preferences.ValueType = await store.get('lineSpacingLevel', defaults.lineSpacingLevel);
      settings.lineSpacingLevel = this.clampInt(lineVal as number, 1, LINE_SPACING_LEVELS.length);
      return settings;
    } catch (_e) {
      return defaults;
    }
  }

  private clampSpeed(v: number): number {
    if (isNaN(v)) {
      return 1.0;
    }
    return Math.max(0.5, Math.min(1.5, v));
  }

  private clampInt(v: number, min: number, max: number): number {
    if (isNaN(v)) {
      return min;
    }
    return Math.max(min, Math.min(max, v));
  }

  private toTurnMode(v: string): ReaderTurnMode {
    switch (v) {
      case ReaderTurnMode.HORIZONTAL: return ReaderTurnMode.HORIZONTAL;
      case ReaderTurnMode.VERTICAL: return ReaderTurnMode.VERTICAL;
      case ReaderTurnMode.NONE: return ReaderTurnMode.NONE;
      default: return ReaderTurnMode.SIMULATION;
    }
  }

  private toPageNumberMode(v: string): ReaderPageNumberMode {
    switch (v) {
      case ReaderPageNumberMode.CHAPTER: return ReaderPageNumberMode.CHAPTER;
      case ReaderPageNumberMode.PERCENT: return ReaderPageNumberMode.PERCENT;
      default: return ReaderPageNumberMode.TOTAL;
    }
  }

  private toTextAlign(v: string): ReaderTextAlign {
    switch (v) {
      case 'right': return 'right';
      case 'auto': return 'auto';
      case 'left': return 'left';
      case 'center': return 'center';
      default: return 'justify';
    }
  }
}
