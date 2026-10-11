/**
 * 排版常量（Single Source of Truth）
 *
 * 引擎中所有硬编码的数值常量归到此文件。
 * 其他地方只读引用，不许重复定义。
 */
export class ReadingMetrics {
  /** 行高倍率：lineHeight = fontSize × LINE_HEIGHT_RATIO */
  static readonly LINE_HEIGHT_RATIO = 1.5;

  /** Canvas 文字基线在行高中的垂直位置（0=行顶，1=行底） */
  static readonly BASELINE_OFFSET = 0.8;

  /** 半角字符宽度占字号的系数，用于 estimateTextWidth */
  static readonly CHAR_WIDTH_COEFFICIENT = 0.55;

  /** Stub 页估算用的每页行高（vp） */
  static readonly STUB_LINE_HEIGHT = 24;

  /** Stub 页估算用的字号（vp） */
  static readonly STUB_FONT_SIZE = 16;

  /** 首行缩进默认宽度（vp），约2个汉字 */
  static readonly DEFAULT_TEXT_INDENT = 34;

  /** 行间距增量默认值（vp） */
  static readonly DEFAULT_LINE_SPACING = 0;

  /** 字间距默认值（px） */
  static readonly DEFAULT_LETTER_SPACING = 0;
}
