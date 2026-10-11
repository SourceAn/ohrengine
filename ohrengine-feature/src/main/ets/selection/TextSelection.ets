/**
 * TextSelection — Canvas-based text selection system
 *
 * Provides:
 * 1. SelectionRange — data interface for current selection
 * 2. HitTester — static (x,y) touch → character index mapping
 * 3. SelectionRenderer — canvas overlay for selection highlight
 * 4. SelectionGestureHandler — long-press detection and handle-drag adjustment
 * 5. ContextMenuManager — clipboard copy / share / lookup actions
 */
import { LineBox } from 'ohrengine-common';
import { pasteboard } from '@kit.BasicServicesKit';
import { UIContext } from '@kit.ArkUI';

// ────────────────────────────────────────────────────────────────────────────
// 1. SelectionRange — data interface
// ────────────────────────────────────────────────────────────────────────────
export interface SelectionRange {
  /** Global character offset from chapter start (inclusive) */
  startCharOffset: number;
  /** Global character offset from chapter start (inclusive) */
  endCharOffset: number;
  /** Index into PageSlot.lines for the start line */
  startLineIndex: number;
  /** Index into PageSlot.lines for the end line */
  endLineIndex: number;
  /** The full selected text snippet */
  text: string;
}

// ────────────────────────────────────────────────────────────────────────────
// 2. HitTester — static hit-test utility
// ────────────────────────────────────────────────────────────────────────────
export class HitTester {
  /**
   * Map (x, y) touch coords to a character offset within a line.
   * @returns null if no character was hit (tapped outside any line).
   */
  public static hitTest(pageLines: LineBox[], x: number, y: number): number | null {
    if (pageLines.length === 0) {
      return null;
    }

    // Find the line containing y (binary search by renderedY)
    let lo: number = 0;
    let hi: number = pageLines.length - 1;
    let lineIndex: number = -1;

    while (lo <= hi) {
      const mid: number = (lo + hi) >>> 1;
      const lb: LineBox = pageLines[mid];
      const lineTop: number = lb.renderedY;
      const lineBottom: number = lineTop + lb.height;
      if (y < lineTop) {
        hi = mid - 1;
      } else if (y > lineBottom) {
        lo = mid + 1;
      } else {
        lineIndex = mid;
        break;
      }
    }

    // Fallback: nearest line if hit test between lines or at edges
    if (lineIndex === -1) {
      // Clamp to closest line
      if (hi < 0) {
        lineIndex = 0;
      } else if (lo >= pageLines.length) {
        lineIndex = pageLines.length - 1;
      } else {
        // Between lines — pick the closest
        const topLine: LineBox = pageLines[hi >= 0 ? hi : 0];
        const bottomLine: LineBox = pageLines[lo < pageLines.length ? lo : pageLines.length - 1];
        const distTop: number = y < topLine.renderedY ? topLine.renderedY - y : 0;
        const distBottom: number = y > bottomLine.renderedY + bottomLine.height ? y - (bottomLine.renderedY + bottomLine.height) : 0;
        lineIndex = distTop <= distBottom ? (hi >= 0 ? hi : 0) : (lo < pageLines.length ? lo : pageLines.length - 1);
      }
    }

    const line: LineBox = pageLines[lineIndex];
    const charPositions: number[] = line.charPositions;
    const charWidths: number[] = line.charWidths;

    if (charPositions.length === 0 || charWidths.length === 0) {
      return null;
    }

    // Binary search charPositions to find the character at x
    lo = 0;
    hi = charPositions.length - 1;
    let charIndex: number = 0;

    while (lo <= hi) {
      const mid: number = (lo + hi) >>> 1;
      const pos: number = charPositions[mid];
      const endPos: number = pos + (charWidths[mid] || 0);
      if (x < pos) {
        hi = mid - 1;
      } else if (x > endPos) {
        lo = mid + 1;
      } else {
        charIndex = mid;
        break;
      }
    }

    // If exact hit failed, use the nearest position
    if (lo > hi) {
      // Clamp to nearest
      if (hi < 0) {
        charIndex = 0;
      } else if (lo >= charPositions.length) {
        charIndex = charPositions.length - 1;
      } else {
        const leftDist: number = x - (charPositions[hi] + (charWidths[hi] || 0));
        const rightDist: number = charPositions[lo] - x;
        charIndex = leftDist <= rightDist ? hi : lo;
      }
    }

    // Return global char offset
    return line.startCharOffset + charIndex;
  }

  /**
   * Find the line index containing a given global character offset.
   */
  public static findLineByCharOffset(pageLines: LineBox[], charOffset: number): number {
    for (let i = 0; i < pageLines.length; i++) {
      const lb: LineBox = pageLines[i];
      const prefixLen: number = (i === 0 && lb.text.length > 0) ? 2 : 0;
      const contentLen: number = Math.max(0, lb.text.length - prefixLen);
      const lineEnd: number = lb.startCharOffset + contentLen;
      if (charOffset >= lb.startCharOffset && charOffset < lineEnd) {
        return i;
      }
    }
    return pageLines.length - 1;
  }
}

// ────────────────────────────────────────────────────────────────────────────
// 3. SelectionRenderer — canvas overlay drawing
// ────────────────────────────────────────────────────────────────────────────
export class SelectionRenderer {
  private static readonly FILL_COLOR: string = 'rgba(37, 135, 255, 0.25)';
  private static readonly HANDLE_COLOR: string = '#2587FF';
  private static readonly HANDLE_RADIUS: number = 6;

  /**
   * Draw selection highlight overlay on the canvas.
   */
  public static renderSelection(
    ctx: CanvasRenderingContext2D,
    selection: SelectionRange,
    pageLines: LineBox[]
  ): void {
    if (selection.startLineIndex < 0 || selection.endLineIndex >= pageLines.length) {
      return;
    }

    ctx.save();
    ctx.fillStyle = SelectionRenderer.FILL_COLOR;

    const startLine: LineBox = pageLines[selection.startLineIndex];
    const endLine: LineBox = pageLines[selection.endLineIndex];

    const startCharLocal: number = Math.max(0, selection.startCharOffset - startLine.startCharOffset);
    const endCharLocal: number = Math.max(0, selection.endCharOffset - endLine.startCharOffset);

    if (selection.startLineIndex === selection.endLineIndex) {
      // Single line selection
      const x1: number = startLine.charPositions[startCharLocal];
      const x2: number = endCharLocal < endLine.charPositions.length
        ? endLine.charPositions[endCharLocal] + (endLine.charWidths[endCharLocal] || 0)
        : startLine.charPositions[startLine.charPositions.length - 1] +
          (startLine.charWidths[startLine.charWidths.length - 1] || 0);
      const y: number = startLine.renderedY;
      const h: number = startLine.height;
      ctx.fillRect(x1, y, x2 - x1, h);
    } else {
      // Multi-line selection
      // First line (partial from startChar)
      if (startCharLocal < startLine.charPositions.length) {
        const x1: number = startLine.charPositions[startCharLocal];
        const xEnd: number = startLine.charPositions[startLine.charPositions.length - 1] +
          (startLine.charWidths[startLine.charWidths.length - 1] || 0);
        ctx.fillRect(x1, startLine.renderedY, xEnd - x1, startLine.height);
      }

      // Middle lines (full width)
      for (let i = selection.startLineIndex + 1; i < selection.endLineIndex; i++) {
        const midLine: LineBox = pageLines[i];
        if (midLine.charPositions.length > 0) {
          const x1: number = midLine.charPositions[0];
          const xEnd: number = midLine.charPositions[midLine.charPositions.length - 1] +
            (midLine.charWidths[midLine.charWidths.length - 1] || 0);
          ctx.fillRect(x1, midLine.renderedY, xEnd - x1, midLine.height);
        }
      }

      // Last line (partial up to endChar)
      if (endCharLocal < endLine.charPositions.length) {
        const x1: number = endLine.charPositions[0];
        const xEnd: number = endLine.charPositions[endCharLocal] + (endLine.charWidths[endCharLocal] || 0);
        ctx.fillRect(x1, endLine.renderedY, xEnd - x1, endLine.height);
      }
    }

    // Draw start/end handles
    SelectionRenderer.drawHandle(ctx, startLine, startCharLocal, 'start');
    SelectionRenderer.drawHandle(ctx, endLine, endCharLocal, 'end');

    ctx.restore();
  }

  private static drawHandle(
    ctx: CanvasRenderingContext2D,
    line: LineBox,
    charLocal: number,
    _side: 'start' | 'end'
  ): void {
    if (charLocal < 0 || charLocal >= line.charPositions.length) {
      return;
    }
    const cx: number = line.charPositions[charLocal];
    const cy: number = line.renderedY + line.height / 2;
    ctx.beginPath();
    ctx.arc(cx, cy, SelectionRenderer.HANDLE_RADIUS, 0, Math.PI * 2);
    ctx.fillStyle = SelectionRenderer.HANDLE_COLOR;
    ctx.fill();
  }
}

// ────────────────────────────────────────────────────────────────────────────
// 4. SelectionGestureHandler — long-press & handle drag
// ────────────────────────────────────────────────────────────────────────────
export class SelectionGestureHandler {
  private static longPressTimer: number = -1;

  /**
   * Reset internal state (call on page change / configure).
   */
  public static reset(): void {
    if (SelectionGestureHandler.longPressTimer > 0) {
      clearTimeout(SelectionGestureHandler.longPressTimer);
      SelectionGestureHandler.longPressTimer = -1;
    }
  }

  /**
   * Handle TouchEvent.Down for long-press detection.
   * 由调用方以自身长按阈值（ReaderGestureController 420ms）定时触发闭包，
   * 触发前调用 reset() 可取消本次候选选区。
   * @returns a partial SelectionRange (start only) if long-press triggers, or null.
   */
  public static handleTouchDown(
    x: number,
    y: number,
    pageLines: LineBox[]
  ): (() => SelectionRange | null) {
    SelectionGestureHandler.reset();
    // Return a cancellable closure that the caller invokes when long-press fires
    return (): SelectionRange | null => {
      const charOffset: number | null = HitTester.hitTest(pageLines, x, y);
      if (charOffset === null) {
        return null;
      }
      // Select the word at this offset (simple heuristic: expand to word boundaries)
      return SelectionGestureHandler.selectWord(pageLines, charOffset);
    };
  }

  /**
   * Expand a character offset to word boundaries.
   * 精准选词（行内）：英文按连续字母/数字扩，中文/日文按相邻汉字/假名连续串扩；
   * 命中点本身是标点/空白时跳到右侧相邻词（无右侧词则取左侧），避免选中标点。
   * 行首缩进 2em 由 line.x 偏移实现（text 无缩进占位符），扩到行首即自然停止。
   */
  private static selectWord(pageLines: LineBox[], charOffset: number): SelectionRange | null {
    const lineIndex: number = HitTester.findLineByCharOffset(pageLines, charOffset);
    if (lineIndex < 0 || lineIndex >= pageLines.length) {
      return null;
    }

    const line: LineBox = pageLines[lineIndex];
    const text: string = line.text;
    let localIdx: number = charOffset - line.startCharOffset;

    if (localIdx < 0 || localIdx >= text.length) {
      return null;
    }

    // 命中分隔符：向右找最近词内字符；无则向左找
    if (!SelectionGestureHandler.isWordChar(text[localIdx])) {
      let foundRight: boolean = false;
      for (let i: number = localIdx + 1; i < text.length; i++) {
        if (SelectionGestureHandler.isWordChar(text[i])) {
          localIdx = i;
          foundRight = true;
          break;
        }
      }
      if (!foundRight) {
        for (let i: number = localIdx - 1; i >= 0; i--) {
          if (SelectionGestureHandler.isWordChar(text[i])) {
            localIdx = i;
            break;
          }
        }
      }
      if (!SelectionGestureHandler.isWordChar(text[localIdx])) {
        return null;
      }
    }

    // Expand left
    let startLocal: number = localIdx;
    while (startLocal > 0 && SelectionGestureHandler.isWordChar(text[startLocal - 1])) {
      startLocal--;
    }

    // Expand right
    let endLocal: number = localIdx;
    while (endLocal < text.length - 1 && SelectionGestureHandler.isWordChar(text[endLocal + 1])) {
      endLocal++;
    }

    const startOff: number = line.startCharOffset + startLocal;
    const endOff: number = line.startCharOffset + endLocal;

    return {
      startCharOffset: startOff,
      endCharOffset: endOff,
      startLineIndex: lineIndex,
      endLineIndex: lineIndex,
      text: text.substring(startLocal, endLocal + 1)
    };
  }

  /** 词内字符：字母数字 / 带变音拉丁字母 / 希腊西里尔 / 假名 / 汉字 / 谚文 / 全角字母数字（标点与空白为分隔符） */
  private static isWordChar(ch: string): boolean {
    const code: number = ch.charCodeAt(0);
    if ((code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A)) {
      return true;
    }
    if (code >= 0x00C0 && code <= 0x024F) {
      return true;
    }
    if ((code >= 0x0370 && code <= 0x03FF) || (code >= 0x0400 && code <= 0x04FF)) {
      return true;
    }
    if (code >= 0x3040 && code <= 0x30FF) {
      return true;
    }
    if (code >= 0x3400 && code <= 0x9FFF) {
      return true;
    }
    if (code >= 0xAC00 && code <= 0xD7AF) {
      return true;
    }
    if (code >= 0xF900 && code <= 0xFAFF) {
      return true;
    }
    if (code >= 0xFF10 && code <= 0xFF19) {
      return true;
    }
    if ((code >= 0xFF21 && code <= 0xFF3A) || (code >= 0xFF41 && code <= 0xFF5A)) {
      return true;
    }
    if (code >= 0xFF66 && code <= 0xFF9F) {
      return true;
    }
    return false;
  }

  /**
   * Handle TouchEvent.Move to adjust selection edges.
   * This is a simplified version; in a full implementation the gesture handler
   * would detect which handle is being dragged and return an updated SelectionRange.
   */
  public static handleTouchMove(
    x: number,
    y: number,
    existingSelection: SelectionRange,
    pageLines: LineBox[],
    adjustStart: boolean
  ): SelectionRange | null {
    const charOffset: number | null = HitTester.hitTest(pageLines, x, y);
    if (charOffset === null) {
      return null;
    }

    const lineIndex: number = HitTester.findLineByCharOffset(pageLines, charOffset);
    if (lineIndex < 0) {
      return null;
    }

    if (adjustStart) {
      const newStart: number = Math.min(charOffset, existingSelection.endCharOffset);
      const newStartLine: number = HitTester.findLineByCharOffset(pageLines, newStart);
      return {
        startCharOffset: newStart,
        endCharOffset: existingSelection.endCharOffset,
        startLineIndex: newStartLine,
        endLineIndex: existingSelection.endLineIndex,
        text: '' // caller should recompute text from full chapter
      };
    } else {
      const newEnd: number = Math.max(charOffset, existingSelection.startCharOffset);
      const newEndLine: number = HitTester.findLineByCharOffset(pageLines, newEnd);
      return {
        startCharOffset: existingSelection.startCharOffset,
        endCharOffset: newEnd,
        startLineIndex: existingSelection.startLineIndex,
        endLineIndex: newEndLine,
        text: '' // caller should recompute text from full chapter
      };
    }
  }
}

// ────────────────────────────────────────────────────────────────────────────
// 5. ContextMenuManager — clipboard & share actions
// ────────────────────────────────────────────────────────────────────────────
export class ContextMenuManager {

  /**
   * Copy the selected text to system clipboard.
   */
  public static copyToClipboard(text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(
        pasteboard.MIMETYPE_TEXT_PLAIN, text
      );
      const sysPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      sysPasteboard.setData(pasteData);
    } catch (err) {}
  }

  /**
   * Share the selected text via system share dialog.
   *
   * @param text 选中文本
   * @param uiContext 当前 UI 上下文（用于 UIContext.getPromptAction()，替代废弃的
   *                  全局 promptAction.showDialog/showToast，避免 UI 上下文不明确）
   */
  public static shareText(text: string, uiContext: UIContext): void {
    if (text.length === 0) {
      return;
    }
    try {
      // Initially designed for systemShare, currently fallback to clipboard copy
      const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const pasteboardObj: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      pasteboardObj.setData(pasteData);
      uiContext.getPromptAction().showDialog({
        title: '已复制到剪贴板',
        message: text,
        buttons: [{ text: 'OK', color: '#0078D4' }]
      });
    } catch (err) {}
  }

  /**
   * Lookup the selected text.
   *
   * NOTE: The actual lookup UI is now delegated to Index.ets, which creates
   * and opens a WordLookupDialog (@CustomDialog) instead of calling this
   * static method. See Index.ets context menu "查词" button handler.
   *
   * This stub is kept for backward compatibility — it logs the lookup request
   * but the real word definition dialog is handled by Index.ets.
   */
  public static lookupText(text: string): void {
    if (text.length === 0) {
      return;
    }
  }
}
