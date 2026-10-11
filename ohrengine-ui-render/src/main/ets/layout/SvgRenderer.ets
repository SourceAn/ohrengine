/**
 * SvgRenderer — 内联 SVG 矢量图形渲染器
 *
 * 职责：
 * - parseSvg():      归一化 SvgDocument 结构（当前为恒等操作）
 * - resolveViewport(): 计算 viewport 尺寸（考虑 viewBox 缩放）
 * - draw():           在 Canvas 上绘制 SVG 形状
 *
 * 支持的基本形状：rect, circle, ellipse, line, polyline, polygon, path, text
 */

import type { SvgDocument, SvgShape, SvgViewBox, SvgPoint } from 'ohrengine-common';

/**
 * Viewport 解析结果
 */
export interface SvgViewportResult {
  width: number;
  height: number;
  scale: number;
  offsetX: number;
  offsetY: number;
}

/**
 * SVG 渲染器 — 静态方法
 */
export class SvgRenderer {
  /**
   * 归一化 SVG 文档结构
   */
  public static parseSvg(doc: SvgDocument): SvgDocument {
    return doc;
  }

  /**
   * 计算 SVG viewport 尺寸和缩放
   *
   * @param doc             SVG 文档
   * @param availableWidth  可用的内容宽度
   * @param availableHeight 可用的内容高度
   * @returns viewport 结果（含缩放比例和平移偏移）
   */
  public static resolveViewport(
    doc: SvgDocument,
    availableWidth: number,
    availableHeight: number
  ): SvgViewportResult {
    // 优先使用显式宽度/高度
    let vpW: number = doc.width !== null ? doc.width : availableWidth;
    let vpH: number = doc.height !== null ? doc.height : availableHeight;

    if (vpW <= 0) {
      vpW = availableWidth;
    }
    if (vpH <= 0) {
      vpH = availableHeight;
    }

    // 如果有 viewBox，按 viewBox 计算缩放以保持纵横比
    let scale: number = 1;
    let offsetX: number = 0;
    let offsetY: number = 0;

    if (doc.viewBox !== null) {
      const vb: SvgViewBox = doc.viewBox;
      if (vb.w > 0 && vb.h > 0) {
        const scaleX: number = vpW / vb.w;
        const scaleY: number = vpH / vb.h;
        scale = Math.min(scaleX, scaleY);
        // 居中
        offsetX = (vpW - vb.w * scale) / 2 - vb.x * scale;
        offsetY = (vpH - vb.h * scale) / 2 - vb.y * scale;
      }
    }

    return { width: vpW, height: vpH, scale: scale, offsetX: offsetX, offsetY: offsetY };
  }

  /**
   * 在 Canvas 上绘制 SVG 文档
   *
   * @param ctx    Canvas 渲染上下文
   * @param doc    SVG 文档（含形状列表）
   * @param x      绘制区域左上角 X
   * @param y      绘制区域左上角 Y
   * @param width  绘制区域宽度
   * @param height 绘制区域高度
   */
  public static draw(
    ctx: CanvasRenderingContext2D,
    doc: SvgDocument,
    x: number,
    y: number,
    width: number,
    height: number,
    densityScale: number = 1
  ): void {
    if (doc.shapes.length === 0) {
      return;
    }

    const vp: SvgViewportResult = SvgRenderer.resolveViewport(doc, width, height);

    const savedFill: string | number | CanvasGradient | CanvasPattern = ctx.fillStyle;
    const savedStroke: string | number | CanvasGradient | CanvasPattern = ctx.strokeStyle;
    const savedLineWidth: number = ctx.lineWidth;

    ctx.save();
    ctx.translate(x + vp.offsetX, y + vp.offsetY);
    ctx.scale(vp.scale, vp.scale);

    for (let i = 0; i < doc.shapes.length; i++) {
      const shape: SvgShape = doc.shapes[i];
      SvgRenderer.drawShape(ctx, shape, densityScale);
    }

    ctx.restore();

    ctx.fillStyle = savedFill;
    ctx.strokeStyle = savedStroke;
    ctx.lineWidth = savedLineWidth;
  }

  /**
   * 绘制单个 SVG 形状
   */
  private static drawShape(ctx: CanvasRenderingContext2D, shape: SvgShape,
                            densityScale: number = 1): void {
    const fillColor: string = shape.fill ?? 'none';
    const strokeColor: string = shape.stroke ?? 'none';
    const strokeW: number = shape.strokeWidth ?? 1;

    ctx.lineWidth = strokeW;
    ctx.strokeStyle = strokeColor;

    switch (shape.type) {
      case 'rect': {
        const rx: number = shape.x ?? 0;
        const ry: number = shape.y ?? 0;
        const rw: number = shape.w ?? 0;
        const rh: number = shape.h ?? 0;
        if (fillColor !== 'none') {
          ctx.fillStyle = fillColor;
          ctx.fillRect(rx, ry, rw, rh);
        }
        if (strokeColor !== 'none') {
          ctx.strokeRect(rx, ry, rw, rh);
        }
        break;
      }

      case 'circle': {
        const cx: number = shape.cx ?? 0;
        const cy: number = shape.cy ?? 0;
        const r: number = shape.r ?? 0;
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, Math.PI * 2);
        if (fillColor !== 'none') {
          ctx.fillStyle = fillColor;
          ctx.fill();
        }
        if (strokeColor !== 'none') {
          ctx.stroke();
        }
        break;
      }

      case 'ellipse': {
        const ex: number = shape.cx ?? 0;
        const ey: number = shape.cy ?? 0;
        const rx: number = shape.rx ?? 0;
        const ry: number = shape.ry ?? 0;
        ctx.beginPath();
        ctx.ellipse(ex, ey, rx, ry, 0, 0, Math.PI * 2);
        if (fillColor !== 'none') {
          ctx.fillStyle = fillColor;
          ctx.fill();
        }
        if (strokeColor !== 'none') {
          ctx.stroke();
        }
        break;
      }

      case 'line': {
        const x1: number = shape.x1 ?? 0;
        const y1: number = shape.y1 ?? 0;
        const x2: number = shape.x2 ?? 0;
        const y2: number = shape.y2 ?? 0;
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        if (strokeColor !== 'none') {
          ctx.stroke();
        }
        break;
      }

      case 'polyline':
      case 'polygon': {
        const pts: SvgPoint[] = shape.points ?? [];
        if (pts.length === 0) {
          break;
        }
        ctx.beginPath();
        ctx.moveTo(pts[0].x, pts[0].y);
        for (let i = 1; i < pts.length; i++) {
          ctx.lineTo(pts[i].x, pts[i].y);
        }
        if (shape.type === 'polygon') {
          ctx.closePath();
        }
        if (fillColor !== 'none') {
          ctx.fillStyle = fillColor;
          ctx.fill();
        }
        if (strokeColor !== 'none') {
          ctx.stroke();
        }
        break;
      }

      case 'path': {
        const cmds: string[] = shape.commands ?? [];
        if (cmds.length === 0) {
          break;
        }
        ctx.beginPath();
        SvgRenderer.drawPathCommands(ctx, cmds);
        if (fillColor !== 'none') {
          ctx.fillStyle = fillColor;
          ctx.fill();
        }
        if (strokeColor !== 'none') {
          ctx.stroke();
        }
        break;
      }

      case 'text': {
        const tx: number = shape.x ?? 0;
        const ty: number = shape.y ?? 0;
        const content: string = shape.content ?? '';
        const fs: number = shape.fontSize ?? 16;
        if (content.length > 0) {
          ctx.font = (fs * densityScale) + 'px HarmonyOS Sans, sans-serif';
          if (fillColor !== 'none') {
            ctx.fillStyle = fillColor;
            ctx.fillText(content, tx, ty);
          }
        }
        break;
      }

      default: {
        break;
      }
    }
  }

  /**
   * 解析并执行基础 SVG path 命令
   * 支持: M/m (moveTo), L/l (lineTo), H/h (horizontal line), V/v (vertical line),
   * C/c (cubic bezier), Q/q (quad bezier), Z/z (close)
   */
  private static drawPathCommands(ctx: CanvasRenderingContext2D, commands: string[]): void {
    let currentX: number = 0;
    let currentY: number = 0;
    let startX: number = 0;
    let startY: number = 0;
    let firstMove: boolean = true;

    for (let i = 0; i < commands.length; i++) {
      const cmd: string = commands[i].trim();
      if (cmd.length === 0) {
        continue;
      }
      const cmdChar: string = cmd.charAt(0);
      const argsStr: string = cmd.substring(1).trim();
      const args: number[] = SvgRenderer.parseNumbers(argsStr);

      switch (cmdChar) {
        case 'M': {
          if (args.length >= 2) {
            currentX = args[0];
            currentY = args[1];
            if (firstMove) {
              startX = currentX;
              startY = currentY;
              firstMove = false;
            }
            ctx.moveTo(currentX, currentY);
          }
          break;
        }
        case 'm': {
          if (args.length >= 2) {
            currentX += args[0];
            currentY += args[1];
            if (firstMove) {
              startX = currentX;
              startY = currentY;
              firstMove = false;
            }
            ctx.moveTo(currentX, currentY);
          }
          break;
        }
        case 'L': {
          for (let ai = 0; ai + 1 < args.length; ai += 2) {
            currentX = args[ai];
            currentY = args[ai + 1];
            ctx.lineTo(currentX, currentY);
          }
          break;
        }
        case 'l': {
          for (let ai = 0; ai + 1 < args.length; ai += 2) {
            currentX += args[ai];
            currentY += args[ai + 1];
            ctx.lineTo(currentX, currentY);
          }
          break;
        }
        case 'H': {
          if (args.length >= 1) {
            currentX = args[0];
            ctx.lineTo(currentX, currentY);
          }
          break;
        }
        case 'h': {
          if (args.length >= 1) {
            currentX += args[0];
            ctx.lineTo(currentX, currentY);
          }
          break;
        }
        case 'V': {
          if (args.length >= 1) {
            currentY = args[0];
            ctx.lineTo(currentX, currentY);
          }
          break;
        }
        case 'v': {
          if (args.length >= 1) {
            currentY += args[0];
            ctx.lineTo(currentX, currentY);
          }
          break;
        }
        case 'C': {
          for (let ai = 0; ai + 5 < args.length; ai += 6) {
            const cp1x: number = args[ai];
            const cp1y: number = args[ai + 1];
            const cp2x: number = args[ai + 2];
            const cp2y: number = args[ai + 3];
            currentX = args[ai + 4];
            currentY = args[ai + 5];
            ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, currentX, currentY);
          }
          break;
        }
        case 'c': {
          for (let ai = 0; ai + 5 < args.length; ai += 6) {
            const cp1x: number = currentX + args[ai];
            const cp1y: number = currentY + args[ai + 1];
            const cp2x: number = currentX + args[ai + 2];
            const cp2y: number = currentY + args[ai + 3];
            currentX += args[ai + 4];
            currentY += args[ai + 5];
            ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, currentX, currentY);
          }
          break;
        }
        case 'Q': {
          for (let ai = 0; ai + 3 < args.length; ai += 4) {
            const cpx: number = args[ai];
            const cpy: number = args[ai + 1];
            currentX = args[ai + 2];
            currentY = args[ai + 3];
            ctx.quadraticCurveTo(cpx, cpy, currentX, currentY);
          }
          break;
        }
        case 'q': {
          for (let ai = 0; ai + 3 < args.length; ai += 4) {
            const cpx: number = currentX + args[ai];
            const cpy: number = currentY + args[ai + 1];
            currentX += args[ai + 2];
            currentY += args[ai + 3];
            ctx.quadraticCurveTo(cpx, cpy, currentX, currentY);
          }
          break;
        }
        case 'Z':
        case 'z': {
          ctx.closePath();
          currentX = startX;
          currentY = startY;
          break;
        }
        default: {
          break;
        }
      }
    }
  }

  /**
   * 从字符串中解析数字列表（空格或逗号分隔）
   */
  private static parseNumbers(input: string): number[] {
    const result: number[] = [];
    // 用正则查找所有数字（包括小数和负数）
    const pattern: RegExp = new RegExp('-?\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?', 'g');
    let match: RegExpExecArray | null = pattern.exec(input);
    while (match !== null) {
      result.push(parseFloat(match[0]));
      match = pattern.exec(input);
    }
    return result;
  }
}
