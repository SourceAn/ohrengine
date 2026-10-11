/**
 * 列表渲染器 — 标记生成与列表布局
 *
 * 参考：CSS Lists Module Level 3
 *
 * 职责：
 * 1. 根据列表类型和层级生成标记字符串（• ◦ ▪ 1. a. i. 等）
 * 2. 计算列表项缩进与标记定位
 * 3. 供排版引擎和渲染层使用
 */

/**
 * 列表标记类型
 */
export enum ListStyleType {
  DISC = 'disc',
  CIRCLE = 'circle',
  SQUARE = 'square',
  DECIMAL = 'decimal',
  LOWER_ALPHA = 'lower-alpha',
  UPPER_ALPHA = 'upper-alpha',
  LOWER_ROMAN = 'lower-roman',
  UPPER_ROMAN = 'upper-roman',
  NONE = 'none'
}

/**
 * 将整数转换为罗马数字字符串（1–3999）
 */
export function toRoman(num: number): string {
  const values: number[] = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
  const numerals: string[] = ['M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I'];
  let result: string = '';
  let n: number = num;
  for (let i = 0; i < values.length; i++) {
    while (n >= values[i]) {
      result += numerals[i];
      n -= values[i];
    }
  }
  return result;
}

/**
 * 根据索引、标记类型和层级生成标记文本
 *
 * @param index 0-based 索引（第几项）
 * @param type  标记类型（ListStyleType）
 * @param level 嵌套层级（0-based，仅对无序列表的 disc→circle→square 循环有影响）
 * @returns 标记字符串（如 "•", "1.", "a.", "iii."）
 */
export function generateMarker(index: number, type: ListStyleType, level: number, listStyleImage?: string): string {
  // list-style-image 存在时，标记文本为空（由渲染层绘制图片）
  if (listStyleImage !== undefined && listStyleImage.length > 0) {
    return '';
  }
  switch (type) {
    case ListStyleType.DISC:
      return '\u2022'; // •
    case ListStyleType.CIRCLE:
      return '\u25E6'; // ◦
    case ListStyleType.SQUARE:
      return '\u25AA'; // ▪
    case ListStyleType.DECIMAL:
      return (index + 1) + '.';
    case ListStyleType.LOWER_ALPHA: {
      if (index >= 0 && index < 26) {
        return String.fromCharCode(97 + index) + '.';
      }
      return (index + 1) + '.'; // fallback
    }
    case ListStyleType.UPPER_ALPHA: {
      if (index >= 0 && index < 26) {
        return String.fromCharCode(65 + index) + '.';
      }
      return (index + 1) + '.'; // fallback
    }
    case ListStyleType.LOWER_ROMAN:
      return toRoman(index + 1).toLowerCase() + '.';
    case ListStyleType.UPPER_ROMAN:
      return toRoman(index + 1) + '.';
    case ListStyleType.NONE:
      return '';
    default:
      return '\u2022'; // fallback disc
  }
}

/**
 * 返回无序列表在嵌套层级上的默认标记类型
 * disc → circle → square → disc → … 循环
 *
 * @param level 嵌套层级（0-based，0=最外层）
 * @returns 对应于该层级的 ListStyleType
 */
export function getLevelDefaultMarkerType(level: number): ListStyleType {
  const types: ListStyleType[] = [ListStyleType.DISC, ListStyleType.CIRCLE, ListStyleType.SQUARE];
  return types[level % 3];
}

/**
 * 根据标记文本估算宽度（vp 单位，用于布局）
 * 后续渲染时用 ctx.measureText() 精确测量
 */
export function estimateMarkerWidth(marker: string, fontSize: number): number {
  if (marker.length === 0) {
    return 0;
  }
  // 符号类标记：• ◦ ▪ 约 0.8em
  const firstChar: number = marker.charCodeAt(0);
  if (firstChar === 0x2022 || firstChar === 0x25E6 || firstChar === 0x25AA) {
    return fontSize * 0.8;
  }
  // 文字类标记：每字符约 0.6em + 点号 0.4em
  return (marker.length - 1) * fontSize * 0.6 + fontSize * 0.4;
}

/**
 * 列表项布局结果
 */
export interface ListItemLayout {
  markerX: number;
  contentX: number;
  contentWidth: number;
  markerImageSrc?: string;   // list-style-image 图片路径
  markerFontSize?: number;   // ::marker 自定义字号
  markerColor?: string;      // ::marker 自定义颜色
}

/**
 * 列表项布局计算
 * 负责 outside 定位的标记位置 + 内容缩进
 */
export class ListLayoutEngine {
  /**
   * 计算列表项的标记位置和内容区域
   *
   * @param level       嵌套层级（0-based）
   * @param markerWidth 标记文本宽度（vp）
   * @param indentWidth 每层缩进宽度（vp，通常 32）
   * @param viewWidth   可用总宽度（vp）
   * @returns markerX（标记 X 坐标）, contentX（文本内容 X 坐标）, contentWidth（文本内容可用宽度）
   */
  public layoutListItem(
    level: number,
    markerWidth: number,
    indentWidth: number,
    viewWidth: number
  ): ListItemLayout {
    const indent: number = indentWidth * level;
    const gap: number = 4; // 标记与文本之间的间距
    const contentX: number = indent + markerWidth + gap;
    const contentWidth: number = Math.max(0, viewWidth - contentX);
    const result: ListItemLayout = {
      markerX: indent,
      contentX: contentX,
      contentWidth: contentWidth
    };
    return result;
  }
}
