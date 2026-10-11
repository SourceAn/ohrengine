/**
 * AnnotationRenderer — 在 Canvas 上绘制标注视觉效果
 *
 * 根据 Annotation 的字符偏移（locator.paragraphIndex / wordIndex）与
 * LineBox[] 的 startCharOffset / charWidths 进行匹配，在对应文字位置上
 * 绘制高亮、下划线、波浪线、删除线等标注效果。
 */
import { Annotation, AnnotationType } from 'ohrengine-common';
import type { LineBox } from 'ohrengine-common';
import { ReadingMetrics } from '../typography/ReadingMetrics.ets';

export class AnnotationRenderer {
  private static readonly HIGHLIGHT_COLOR: string = 'rgba(255, 255, 0, 0.35)';
  private static readonly UNDERLINE_COLOR: string = '#FF6B35';
  private static readonly WAVY_COLOR: string = '#E8465C';
  private static readonly STRIKETHROUGH_COLOR: string = '#888888';

  // ── 各标注类型的绘制方法 ──

  static renderHighlight(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number): void {
    ctx.fillStyle = AnnotationRenderer.HIGHLIGHT_COLOR;
    ctx.fillRect(x, y, w, h);
  }

  static renderUnderline(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number): void {
    const lineY: number = y + h + 1;
    ctx.strokeStyle = AnnotationRenderer.UNDERLINE_COLOR;
    ctx.lineWidth = 1.2;
    ctx.beginPath();
    ctx.moveTo(x, lineY);
    ctx.lineTo(x + w, lineY);
    ctx.stroke();
  }

  static renderWavyUnderline(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number): void {
    const waveY: number = y + h + 1;
    const amplitude: number = 2;
    const period: number = 4;
    ctx.strokeStyle = AnnotationRenderer.WAVY_COLOR;
    ctx.lineWidth = 1.0;
    ctx.beginPath();
    let px: number = x;
    while (px < x + w) {
      const localX: number = px - x;
      const waveOffset: number = amplitude * Math.sin((localX / period) * Math.PI);
      ctx.lineTo(px, waveY + waveOffset);
      px += 1;
    }
    ctx.stroke();
  }

  static renderStrikethrough(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number): void {
    const strikeY: number = y + h * 0.45;
    ctx.strokeStyle = AnnotationRenderer.STRIKETHROUGH_COLOR;
    ctx.lineWidth = 1.0;
    ctx.beginPath();
    ctx.moveTo(x, strikeY);
    ctx.lineTo(x + w, strikeY);
    ctx.stroke();
  }

  static renderNoteIcon(ctx: CanvasRenderingContext2D, x: number, y: number,
                         fontUnit: string = 'vp'): void {
    const size: number = 10;
    ctx.fillStyle = '#0078D4';
    ctx.beginPath();
    ctx.arc(x, y + size, size, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = '#ffffff';
    ctx.font = '10' + fontUnit + ' HarmonyOS Sans';
    ctx.fillText('N', x - 3, y + size + 3.5);
  }

  // ── 主入口 ──

  /**
   * 在 Canvas 上绘制所有标注视觉效果
   *
   * @param ctx - Canvas 渲染上下文
   * @param lines - 当前页的 LineBox 数组
   * @param annotations - 当前章节的标注列表
   * @param fontSize - 当前字号（vp）
   */
  static render(
    ctx: CanvasRenderingContext2D,
    lines: LineBox[],
    annotations: Annotation[],
    fontSize: number,
    fontUnit: string = 'vp'
  ): void {
    if (annotations.length === 0 || lines.length === 0) {
      return;
    }

    // 用 for 循环从头遍历 lines 分别计算行 Y 坐标（不依赖之前缓存的值）
    let currentY: number = 0;
    for (let li: number = 0; li < lines.length; li++) {
      const line: LineBox = lines[li];
      // 更新行的 renderedY（与 renderPage 中的逻辑一致）
      line.renderedY = currentY;

      const lineH: number = line.height > 0
        ? line.height
        : fontSize * ReadingMetrics.LINE_HEIGHT_RATIO;
      const lineStart: number = line.startCharOffset;
      const lineEnd: number = lineStart + line.text.length;

      // 遍历所有标注，检查是否与当前行有重叠
      for (let ai: number = 0; ai < annotations.length; ai++) {
        const ann: Annotation = annotations[ai];
        const annStart: number = ann.locator.paragraphIndex ?? 0;
        const annEnd: number = ann.locator.wordIndex ?? annStart;

        // 区间无重叠则跳过
        if (annStart >= lineEnd || annEnd <= lineStart) {
          continue;
        }

        // 计算在本行内的字符区间
        const localStart: number = Math.max(0, annStart - lineStart);
        const localEnd: number = Math.min(line.text.length, annEnd - lineStart);

        // 计算 X 坐标
        let segX: number = line.x;
        for (let ci: number = 0; ci < localStart && ci < line.charWidths.length; ci++) {
          segX += line.charWidths[ci];
        }
        let segW: number = 0;
        for (let ci: number = localStart; ci < localEnd && ci < line.charWidths.length; ci++) {
          segW += line.charWidths[ci];
        }
        // 回退：如果没有 charWidths，用字符数估算
        if (segW === 0 && localEnd > localStart) {
          const charCount: number = localEnd - localStart;
          segW = charCount * (fontSize * 0.6);
        }

        // 根据标注类型调用对应绘制方法
        const annType: AnnotationType = ann.type;
        if (annType === AnnotationType.HIGHLIGHT) {
          AnnotationRenderer.renderHighlight(ctx, segX, currentY, segW, lineH);
        } else if (annType === AnnotationType.UNDERLINE) {
          AnnotationRenderer.renderUnderline(ctx, segX, currentY, segW, lineH);
        } else if (annType === AnnotationType.NOTE) {
          AnnotationRenderer.renderHighlight(ctx, segX, currentY, segW, lineH);
          AnnotationRenderer.renderNoteIcon(ctx, segX + segW, currentY, fontUnit);
        } else if (annType === AnnotationType.BOOKMARK) {
          // BOOKMARK 不在此处渲染
        }
      }

      currentY += lineH;
    }
  }
}
