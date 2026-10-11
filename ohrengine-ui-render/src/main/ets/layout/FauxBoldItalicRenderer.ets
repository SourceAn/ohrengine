import { CssFontWeight, CssFontStyle } from 'ohrengine-common';

/**
 * FauxBoldItalicRenderer — 伪粗体 + 伪斜体 + 中文优化
 *
 * 当字体缺少粗体/斜体字型时，通过 Canvas 变换模拟：
 * - 伪粗体：strokeText + fillText 叠加（中文笔画密集时减少偏移量）
 * - 伪斜体：Canvas transform skew（中文不做伪斜体，效果差）
 */
export class FauxBoldItalicRenderer {

  /**
   * 将 CssFontWeight 枚举映射为数值 (100-900)
   */
  static cssWeightToNumber(weight: CssFontWeight): number {
    if (weight === CssFontWeight.NORMAL) {
      return 400;
    }
    if (weight === CssFontWeight.BOLD) {
      return 700;
    }
    if (weight === CssFontWeight.W_100) {
      return 100;
    }
    if (weight === CssFontWeight.W_200) {
      return 200;
    }
    if (weight === CssFontWeight.W_300) {
      return 300;
    }
    if (weight === CssFontWeight.W_400) {
      return 400;
    }
    if (weight === CssFontWeight.W_500) {
      return 500;
    }
    if (weight === CssFontWeight.W_600) {
      return 600;
    }
    if (weight === CssFontWeight.W_700) {
      return 700;
    }
    if (weight === CssFontWeight.W_800) {
      return 800;
    }
    if (weight === CssFontWeight.W_900) {
      return 900;
    }
    return 400;
  }

  /**
   * 将 CssFontStyle 枚举映射为字符串
   */
  static cssStyleToString(style: CssFontStyle): string {
    if (style === CssFontStyle.NORMAL) {
      return 'normal';
    }
    if (style === CssFontStyle.ITALIC) {
      return 'italic';
    }
    if (style === CssFontStyle.OBLIQUE) {
      return 'oblique';
    }
    return 'normal';
  }

  /**
   * 文本中 CJK 字符占比
   */
  public static cjkCharRatio(text: string): number {
    let cjk: number = 0;
    for (let i: number = 0; i < text.length; i++) {
      const cp: number = text.charCodeAt(i);
      if (cp >= 0x4E00 && cp <= 0x9FFF) {
        cjk++;
      }
    }
    if (text.length > 0) {
      return cjk / text.length;
    }
    return 0;
  }

  /**
   * 伪粗体偏移量 = fontSize × ratio
   * 中文笔画密集，偏移量减半避免糊成一团
   */
  public static getBoldOffset(fontSize: number, text: string): number {
    const cjkRatio: number = FauxBoldItalicRenderer.cjkCharRatio(text);
    const base: number = Math.max(0.5, fontSize * 0.03);
    if (cjkRatio > 0.5) {
      return base * 0.5;
    }
    return base;
  }

  /**
   * 渲染伪粗体
   */
  static renderBold(
    ctx: CanvasRenderingContext2D,
    text: string,
    x: number,
    y: number,
    fontSize: number,
    color: string
  ): void {
    const offset: number = FauxBoldItalicRenderer.getBoldOffset(fontSize, text);
    ctx.save();
    ctx.fillStyle = color;
    ctx.strokeStyle = color;
    ctx.lineWidth = offset * 2.5;
    ctx.lineJoin = 'round';
    ctx.strokeText(text, x, y);
    ctx.fillText(text, x, y);
    ctx.restore();
  }

  /**
   * 渲染伪斜体
   * 中文不做伪斜体（效果差），直接正常绘制
   */
  static renderItalic(
    ctx: CanvasRenderingContext2D,
    text: string,
    x: number,
    y: number,
    fontSize: number,
    color: string
  ): void {
    // 中文不做伪斜体（效果差）
    if (FauxBoldItalicRenderer.cjkCharRatio(text) > 0.5) {
      ctx.fillStyle = color;
      ctx.fillText(text, x, y);
      return;
    }
    ctx.save();
    const skew: number = 0.25;
    ctx.transform(1, 0, skew, 1, -fontSize * skew * 0.3, 0);
    ctx.fillStyle = color;
    ctx.fillText(text, x, y);
    ctx.restore();
  }
}
