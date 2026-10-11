/**
 * MathMLRenderer — MathML 公式渲染器
 *
 * 职责：
 * - parseMathMl(): 将 MathMlExpression 树转换为归一化的布局树
 * - measure():     递归计算 MathML 表达式的尺寸
 * - draw():        在 Canvas 上绘制 MathML 表达式
 *
 * 参考文献：
 * - MathML 3.0 (W3C): https://www.w3.org/TR/MathML3/
 * - 排版参考：Charles Sanders Peirce 的数学排版约定
 */

import type { MathMlExpression } from 'ohrengine-common';
/**
 * 测量结果 — 宽度/高度/基线
 */
export interface MathMlMeasure {
  width: number;
  height: number;
  baseline: number; // 从顶部到基线的距离
}

/**
 * 渲染选项
 */
export interface MathMlRenderOptions {
  fontSize: number;
  fontFamily: string;
  color: string;
  lineWidth: number; // 分数线和根号的线宽
  fractionLineExtra: number; // 分数线上下与子表达式的间距
  radicalExtra: number;     // 根号与根号主体的间距
  scriptScale: number;      // 上标/下标的字号比例
  scriptOffset: number;     // 上标/下标的垂直偏移比例（相对字号）
  unit?: string;            // 字体单位（'vp' | 'px'），离屏渲染传 'px'
}

/**
 * 默认渲染选项 — 中号 / 常规
 */
function defaultOptions(fontSize: number): MathMlRenderOptions {
  return {
    fontSize: fontSize,
    fontFamily: 'HarmonyOS Sans',
    color: '#000000',
    lineWidth: Math.max(1, fontSize / 24),
    fractionLineExtra: fontSize * 0.15,
    radicalExtra: fontSize * 0.05,
    scriptScale: 0.65,
    scriptOffset: 0.4
  };
}

/**
 * MathML 渲染器 - 静态方法
 */
export class MathMLRenderer {
  /**
   * 解析 MathMlExpression 树并返回归一化结构
   * 当前实现直接返回输入（表达式树结构已符合要求）
   */
  public static parseMathMl(expr: MathMlExpression): MathMlExpression {
    return expr;
  }

  /**
   * 递归测量 MathML 表达式尺寸
   *
   * @param expr     MathML 表达式节点
   * @param options  渲染选项（使用 fontSize 确定比例）
   * @returns MathMlMeasure 宽度、高度、基线
   */
  public static measure(expr: MathMlExpression, options?: MathMlRenderOptions): MathMlMeasure {
    const opts: MathMlRenderOptions = options ?? defaultOptions(12);
    const fs: number = opts.fontSize;

    switch (expr.type) {
      case 'text': {
        const text: string = expr.value ?? '';
        // 近似：平均字符宽度 0.6em，高度 1.2em
        const w: number = text.length * fs * 0.6;
        const h: number = fs * 1.2;
        return { width: w, height: h, baseline: fs };
      }

      case 'placeholder': {
        const text: string = expr.value ?? '[Math]';
        const w: number = text.length * fs * 0.6;
        const h: number = fs * 1.2;
        return { width: w, height: h, baseline: fs };
      }

      case 'fraction': {
        const numM: MathMlMeasure = expr.numerator !== undefined
          ? MathMLRenderer.measure(expr.numerator, opts)
          : { width: 0, height: 0, baseline: 0 };
        const denM: MathMlMeasure = expr.denominator !== undefined
          ? MathMLRenderer.measure(expr.denominator, opts)
          : { width: 0, height: 0, baseline: 0 };
        const gap: number = opts.fractionLineExtra;
        const lineH: number = opts.lineWidth;
        const w: number = Math.max(numM.width, denM.width);
        const h: number = numM.height + gap + lineH + gap + denM.height;
        // 基线位于分数线中心，但更接近实际视觉中心
        return { width: w, height: h, baseline: numM.height + gap + lineH / 2 };
      }

      case 'radical': {
        const radM: MathMlMeasure = expr.radicand !== undefined
          ? MathMLRenderer.measure(expr.radicand, opts)
          : { width: 0, height: 0, baseline: 0 };
        const radicalWidth: number = fs * 0.8; // √ 符号宽度
        const extra: number = opts.radicalExtra;
        return {
          width: radicalWidth + extra + radM.width,
          height: radM.height + fs * 0.1,
          baseline: radM.baseline + fs * 0.1
        };
      }

      case 'superscript': {
        const baseM: MathMlMeasure = expr.base !== undefined
          ? MathMLRenderer.measure(expr.base, opts)
          : { width: 0, height: 0, baseline: 0 };
        const scriptOpts: MathMlRenderOptions = {
          fontSize: opts.fontSize * opts.scriptScale,
          fontFamily: opts.fontFamily,
          color: opts.color,
          lineWidth: opts.lineWidth,
          fractionLineExtra: opts.fractionLineExtra,
          radicalExtra: opts.radicalExtra,
          scriptScale: opts.scriptScale,
          scriptOffset: opts.scriptOffset
        };
        const scriptM: MathMlMeasure = expr.script !== undefined
          ? MathMLRenderer.measure(expr.script, scriptOpts)
          : { width: 0, height: 0, baseline: 0 };
        const w: number = baseM.width + scriptM.width;
        const h: number = baseM.height + scriptM.height * opts.scriptOffset;
        return { width: w, height: h, baseline: baseM.baseline };
      }

      case 'subscript': {
        const baseM: MathMlMeasure = expr.base !== undefined
          ? MathMLRenderer.measure(expr.base, opts)
          : { width: 0, height: 0, baseline: 0 };
        const scriptOpts: MathMlRenderOptions = {
          fontSize: opts.fontSize * opts.scriptScale,
          fontFamily: opts.fontFamily,
          color: opts.color,
          lineWidth: opts.lineWidth,
          fractionLineExtra: opts.fractionLineExtra,
          radicalExtra: opts.radicalExtra,
          scriptScale: opts.scriptScale,
          scriptOffset: opts.scriptOffset
        };
        const scriptM: MathMlMeasure = expr.script !== undefined
          ? MathMLRenderer.measure(expr.script, scriptOpts)
          : { width: 0, height: 0, baseline: 0 };
        const w: number = baseM.width + scriptM.width;
        const h: number = baseM.height + scriptM.height * (1 - opts.scriptOffset);
        return { width: w, height: h, baseline: baseM.baseline };
      }

      default: {
        return { width: 0, height: 0, baseline: 0 };
      }
    }
  }

  /**
   * 在 Canvas 上绘制 MathML 表达式
   *
   * @param ctx     Canvas 渲染上下文
   * @param expr    MathML 表达式节点
   * @param x       绘制起始 X（左边界）
   * @param y       绘制基线 Y
   * @param options 渲染选项
   */
  public static draw(
    ctx: CanvasRenderingContext2D,
    expr: MathMlExpression,
    x: number,
    y: number,
    options?: MathMlRenderOptions
  ): void {
    const opts: MathMlRenderOptions = options ?? defaultOptions(12);
    const fs: number = opts.fontSize;
    const savedFill: string | number | CanvasGradient | CanvasPattern = ctx.fillStyle;
    const savedStroke: string | number | CanvasGradient | CanvasPattern = ctx.strokeStyle;
    const savedLineWidth: number = ctx.lineWidth;

    switch (expr.type) {
      case 'text': {
        const text: string = expr.value ?? '';
        ctx.font = fs + (opts.unit ?? 'vp') + ' ' + opts.fontFamily + ', sans-serif';
        ctx.fillStyle = opts.color;
        ctx.fillText(text, x, y);
        break;
      }

      case 'placeholder': {
        const text: string = expr.value ?? '[Math]';
        ctx.font = fs + (opts.unit ?? 'vp') + ' ' + opts.fontFamily + ', sans-serif';
        ctx.fillStyle = opts.color;
        ctx.fillText(text, x, y);
        break;
      }

      case 'fraction': {
        const numM: MathMlMeasure = expr.numerator !== undefined
          ? MathMLRenderer.measure(expr.numerator, opts)
          : { width: 0, height: 0, baseline: 0 };
        const denM: MathMlMeasure = expr.denominator !== undefined
          ? MathMLRenderer.measure(expr.denominator, opts)
          : { width: 0, height: 0, baseline: 0 };
        const gap: number = opts.fractionLineExtra;
        const lineH: number = opts.lineWidth;
        const totalW: number = Math.max(numM.width, denM.width);
        const contentTop: number = y - numM.baseline - gap - lineH / 2;

        // 分子 — 水平居中
        if (expr.numerator !== undefined) {
          const numX: number = x + (totalW - numM.width) / 2;
          const numY: number = contentTop + numM.baseline;
          MathMLRenderer.draw(ctx, expr.numerator, numX, numY, opts);
        }

        // 分数线
        ctx.strokeStyle = opts.color;
        ctx.lineWidth = lineH;
        ctx.beginPath();
        ctx.moveTo(x, contentTop + numM.height + gap + lineH / 2);
        ctx.lineTo(x + totalW, contentTop + numM.height + gap + lineH / 2);
        ctx.stroke();

        // 分母 — 水平居中
        if (expr.denominator !== undefined) {
          const denX: number = x + (totalW - denM.width) / 2;
          const denY: number = contentTop + numM.height + gap + lineH + gap + denM.baseline;
          MathMLRenderer.draw(ctx, expr.denominator, denX, denY, opts);
        }
        break;
      }

      case 'radical': {
        const radM: MathMlMeasure = expr.radicand !== undefined
          ? MathMLRenderer.measure(expr.radicand, opts)
          : { width: 0, height: 0, baseline: 0 };
        const radicalWidth: number = fs * 0.8;
        const extra: number = opts.radicalExtra;
        const radY: number = y - fs * 0.1;

        // 绘制根号：左竖线、上横线、右侧延伸
        ctx.strokeStyle = opts.color;
        ctx.lineWidth = opts.lineWidth;
        ctx.beginPath();
        // 根号左侧竖线
        ctx.moveTo(x + radicalWidth * 0.3, radY - radM.height * 0.8);
        ctx.lineTo(x + radicalWidth * 0.1, radY);
        // 根号底部到顶部
        ctx.lineTo(x, radY);
        ctx.lineTo(x + radicalWidth * 0.3, radY - radM.height * 0.8);
        // 根号顶部横线向右延伸
        ctx.moveTo(x + radicalWidth * 0.3, radY - radM.height * 0.8);
        ctx.lineTo(x + radicalWidth, radY - radM.height * 0.8);
        ctx.stroke();

        // 上横线覆盖根号主体上方
        ctx.beginPath();
        ctx.moveTo(x + radicalWidth * 0.3, radY - radM.height * 0.8);
        ctx.lineTo(x + radicalWidth + extra + radM.width, radY - radM.height * 0.8);
        ctx.stroke();

        // 绘制根号内的表达式
        if (expr.radicand !== undefined) {
          MathMLRenderer.draw(ctx, expr.radicand, x + radicalWidth + extra, radY, opts);
        }
        break;
      }

      case 'superscript': {
        const baseM: MathMlMeasure = expr.base !== undefined
          ? MathMLRenderer.measure(expr.base, opts)
          : { width: 0, height: 0, baseline: 0 };
        const scriptOpts: MathMlRenderOptions = {
          fontSize: opts.fontSize * opts.scriptScale,
          fontFamily: opts.fontFamily,
          color: opts.color,
          lineWidth: opts.lineWidth,
          fractionLineExtra: opts.fractionLineExtra,
          radicalExtra: opts.radicalExtra,
          scriptScale: opts.scriptScale,
          scriptOffset: opts.scriptOffset
        };
        if (expr.base !== undefined) {
          MathMLRenderer.draw(ctx, expr.base, x, y, opts);
        }
        if (expr.script !== undefined) {
          const scriptX: number = x + baseM.width;
          const scriptY: number = y - baseM.height * opts.scriptOffset + fs * opts.scriptScale * 0.8;
          MathMLRenderer.draw(ctx, expr.script, scriptX, scriptY, scriptOpts);
        }
        break;
      }

      case 'subscript': {
        const baseM: MathMlMeasure = expr.base !== undefined
          ? MathMLRenderer.measure(expr.base, opts)
          : { width: 0, height: 0, baseline: 0 };
        const scriptOpts: MathMlRenderOptions = {
          fontSize: opts.fontSize * opts.scriptScale,
          fontFamily: opts.fontFamily,
          color: opts.color,
          lineWidth: opts.lineWidth,
          fractionLineExtra: opts.fractionLineExtra,
          radicalExtra: opts.radicalExtra,
          scriptScale: opts.scriptScale,
          scriptOffset: opts.scriptOffset
        };
        if (expr.base !== undefined) {
          MathMLRenderer.draw(ctx, expr.base, x, y, opts);
        }
        if (expr.script !== undefined) {
          const scriptX: number = x + baseM.width;
          const scriptY: number = y + fs * opts.scriptScale * 0.2;
          MathMLRenderer.draw(ctx, expr.script, scriptX, scriptY, scriptOpts);
        }
        break;
      }

      default: {
        break;
      }
    }

    ctx.fillStyle = savedFill;
    ctx.strokeStyle = savedStroke;
    ctx.lineWidth = savedLineWidth;
  }
}
