/**
 * RubyRenderer — 注音/振り仮名 (furigana) 渲染
 *
 * 渲染方式：
 * - 单字符 base：ruby 文本居中于 base 字符上方
 * - 多字符 base：ruby 文本居中于 base 文本上方（均匀分布）
 *
 * § RubySegment 附着于 LineBox，在 Index.ets renderPage() 中绘制
 */

import type { RubyPair } from 'ohrengine-common';

/**
 * 行盒上的 ruby 段索引
 */
export interface LineRubySegment {
  rubyText: string;
  baseStartIndex: number;
  baseEndIndex: number;
  rubyPosition?: string; // 'over' | 'under'，从 computedStyle 继承
  rubyAlign?: string;    // 'auto' | 'start' | 'center'
}

/**
 * Ruby 渲染选项 — 字体/颜色/字号/位置/对齐可配置
 */
export interface RubyRenderOptions {
  rubyFontFamily?: string;   // 注音字体，默认 'HarmonyOS Sans'
  rubyColor?: string;        // 注音颜色，默认 '#888888'
  rubyFontSizeRatio?: number; // 注音字号比例，默认 0.5
  rubyPosition?: string;     // 'over' | 'under'，默认 'over'
  rubyAlign?: string;        // 'auto' | 'start' | 'center'，默认 'auto'
  unit?: string;             // 字体单位（'vp' | 'px'），离屏渲染传 'px'
}

/**
 * Ruby 渲染器 - 静态方法
 */
export class RubyRenderer {
  /**
   * 在 Canvas 上绘制一段 ruby 注音
   *
   * @param ctx        Canvas 上下文
   * @param rubyText   注音文本
   * @param baseStartX base 字符 X 起始位置
   * @param baseWidth  base 文本宽度
   * @param baselineY  base 基线 Y
   * @param baseFontSize 正文字号
   * @param textColor  正文颜色（用于恢复）
   * @param options    可选的 ruby 渲染选项
   */
  public static drawRuby(
    ctx: CanvasRenderingContext2D,
    rubyText: string,
    baseStartX: number,
    baseWidth: number,
    baselineY: number,
    baseFontSize: number,
    textColor: string,
    options?: RubyRenderOptions
  ): void {
    const ratio: number = options?.rubyFontSizeRatio ?? 0.5;
    const fontFamily: string = options?.rubyFontFamily ?? 'HarmonyOS Sans';
    const color: string = options?.rubyColor ?? '#888888';
    const rubyFontSize: number = baseFontSize * ratio;
    ctx.font = rubyFontSize + (options?.unit ?? 'vp') + ' ' + fontFamily + ', sans-serif';

    // 测量注音文本宽度（使用 Canvas measureText，返回 vp 单位）
    const rubyWidth: number = ctx.measureText(rubyText).width;

    // ruby-align：计算注音 X 位置
    let rubyX: number;
    switch (options?.rubyAlign ?? 'auto') {
      case 'start':
        rubyX = baseStartX;
        break;
      case 'center':
        rubyX = baseStartX + (baseWidth - rubyWidth) / 2;
        break;
      default: // 'auto' — 同上居中
        rubyX = baseStartX + (baseWidth - rubyWidth) / 2;
        break;
    }

    // ruby-position：计算注音 Y 位置
    const rubyY: number = (options?.rubyPosition ?? 'over') === 'under'
      ? baselineY + baseFontSize * 0.15
      : baselineY - baseFontSize * 0.35;

    ctx.fillStyle = color;
    ctx.fillText(rubyText, rubyX, rubyY);
    ctx.fillStyle = textColor;
  }
}
