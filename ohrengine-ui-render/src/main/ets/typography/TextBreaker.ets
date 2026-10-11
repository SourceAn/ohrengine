/**
 * TextBreaker — Knuth-Plass 最优换行
 *
 * 核心流程：
 * 1. tokenize() → 按 CJK / ASCII 单词 / 空格分词
 * 2. 估算每个 token 宽度（基于字符类型 × fontSize × 系数）
 * 3. DP 求最小 badness 的断行方案
 * 4. 回溯 → 生成 LineBox[]
 *
 * 宽度估算采用与 LayoutEngine 原 estimation 逻辑一致的系数（0.55），
 * 保证所有计算在统一坐标系（vp/fp）中进行，无需依赖 ArkUI 测量 API。
 *
 * 参考：Knuth & Plass "Breaking Paragraphs into Lines" (1981)
 */
import { createEmptyLineBox } from 'ohrengine-common';
import type { LineBox } from 'ohrengine-common';
import { justify } from './JustifyEngine.ets';

// ── 行首禁则（不能出现在行首） ──
const LINE_START_PROHIBITED: string =
  '」』）】〕〉》”’〕］、。，．：；？！' +
  'ァィゥェォッャュョヮヵヶ' +
  'っゃゅょゎゕゖ' +
  'ㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ' +
  'ー〜…‥・';

// ── 行尾禁则（不能出现在行尾） ──
const LINE_END_PROHIBITED: string =
  '「『（【〔〈《“‘〔［';

// ── 辅助函数 ──

function isCJK(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  return (code >= 0x2E80 && code <= 0x9FFF) ||
         (code >= 0xF900 && code <= 0xFAFF) ||
         (code >= 0xFE30 && code <= 0xFE6F) ||
         (code >= 0x3000 && code <= 0x303F) ||
         (code >= 0xFF01 && code <= 0xFF60) ||
         (code >= 0xFFE0 && code <= 0xFFE6);
}

function isSpace(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  return code === 0x20 || code === 0x3000 || code === 0x09 || code === 0x0A || code === 0x0D;
}

function isTextCJK(text: string): boolean {
  if (text.length === 0) return false;
  let cjkCount: number = 0;
  for (let i = 0; i < text.length; i++) {
    if (isCJK(text[i])) {
      cjkCount++;
    }
  }
  return cjkCount > text.length / 2;
}

function isASCIIWordChar(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  return (code >= 0x30 && code <= 0x39) || // digit
         (code >= 0x41 && code <= 0x5A) || // A-Z
         (code >= 0x61 && code <= 0x7A) || // a-z
         code === 0x27 || // apostrophe '
         code === 0x2D;   // hyphen -
}

// ── 导出类型 ──

export interface BreakerResult {
  lines: LineBox[];
  totalLines: number;
  charsPerLine: number;
}

// ── TextBreaker 主类 ──

export class TextBreaker {
  private fontSize: number = 16;
  private maxWidth: number = 376;
  private lineHeight: number = 24;
  private density: number = 3.0;
  private textIndent: number = 32; // 首行缩进 (vp)，默认 2em（随 setFontSize 联动）
  private textIndentExplicit: boolean = false; // 显式 setTextIndent 覆盖优先于 2em 联动
  private lineSpacing: number = 0; // 行间距增量 (vp)
  private safetyMargin: number = 0.99; // 宽度安全系数（原 0.95 右侧留白过宽；1.0 无余量，现取 0.99 保留 1% 抗渲染偏差余量）
  private fontFamily: string = ''; // 字体族（空串 = 默认字体 'HarmonyOS Sans'）

  /**
   * DP fallback 回调：DP 异常回退到贪婪换行时触发
   * 参数：(tokenCount: number, lineCount: number)
   */
  public onDpFallback: ((nTokens: number, lineCount: number) => void) | null = null;

  public setFontSize(fp: number): void {
    this.fontSize = fp;
    // 默认 2em 首行缩进：未显式设置 textIndent 时随字号同步（fp * 2）
    if (!this.textIndentExplicit) {
      this.textIndent = fp * 2;
    }
  }

  public setMaxWidth(vp: number): void {
    this.maxWidth = vp;
  }

  public setLineHeight(vp: number): void {
    this.lineHeight = vp;
  }

  public setDensity(density: number): void {
    this.density = density;
  }

  public setTextIndent(vp: number): void {
    this.textIndent = vp;
    this.textIndentExplicit = true;
  }

  public setLineSpacing(spacing: number): void {
    this.lineSpacing = spacing;
  }

  public getLineSpacing(): number {
    return this.lineSpacing;
  }

  private letterSpacing: number = 0; // vp，LayoutProfile.letterSpacing
  private wordSpacing: number = 0;   // vp，LayoutProfile.wordSpacing

  public setLetterSpacing(spacing: number): void {
    this.letterSpacing = spacing;
  }

  public setWordSpacing(spacing: number): void {
    this.wordSpacing = spacing;
  }

  public textAlign: 'left' | 'right' | 'center' | 'justify' = 'justify';

  public setTextAlign(align: 'left' | 'right' | 'center' | 'justify'): void {
    this.textAlign = align;
  }

  private whiteSpace: string = 'normal';
  private overflow: string = 'visible';
  private textOverflow: string = 'clip';

  public setWhiteSpace(val: string): void {
    this.whiteSpace = val;
  }

  public setOverflow(val: string): void {
    this.overflow = val;
  }

  public setTextOverflow(val: string): void {
    this.textOverflow = val;
  }

  public setFontFamily(family: string): void {
    this.fontFamily = family;
  }

  /**
   * 测量文本宽度（vp）— 确定性估算，不依赖 MeasureText。
   *
   * 字宽规则（与 JustifyEngine.measureCharWidth 完全一致，保证断行宽度 =
   * justify 逐字位置累加，杜绝字块重叠）：
   *   - CJK / 全角字符 / 全角+半角标点 / Emoji → 1em（= fontSize）
   *   - 半角字母数字（Latin/digit）→ 0.55em
   *   - 空格 → 0.5em（词间距由 wordSpacing 单独附加）
   *
   * 每行宽度 = Σ(字符槽宽)，槽宽 ≥ 实际渲染字宽 → 字符间永无重叠；
   * 且每行容纳整数个字符槽，字号切换后自动重排，同样不重叠。
   */
  public measureWidth(text: string, fontFamily?: string): number {
    if (text.length === 0) {
      return 0;
    }
    let width: number = 0;
    for (let i = 0; i < text.length; i++) {
      width += TextBreaker.charSlotWidth(text[i], this.fontSize);
    }
    width += this.letterSpacing * text.length;
    if (text.length === 1 && (text[0] === ' ' || text[0] === '\u00A0')) {
      width += this.wordSpacing;
    }
    return width;
  }

  /**
   * 单字符槽宽（vp）— 与 JustifyEngine.measureCharWidth 同一套规则。
   * @param ch 字符
   * @param fontSize 当前字号（vp）
   * @returns 字符分配的槽宽
   */
  static charSlotWidth(ch: string, fontSize: number): number {
    const code: number = ch.charCodeAt(0);
    if (isCJK(ch)) {
      return fontSize; // CJK / 全角 → 1em
    }
    if (code >= 0x1F000) {
      return fontSize; // Emoji → 1em
    }
    if (TextBreaker.isPunct(ch)) {
      return fontSize; // 全角+半角标点 → 1em（用户要求符号固定 1 字宽）
    }
    if (isSpace(ch)) {
      return fontSize * 0.5; // 空格 → 0.5em
    }
    return fontSize * 0.55; // 半角字母数字 → 0.55em
  }

  /**
   * 标点判定：全角标点 + 半角标点均返回 true（统一按 1em 槽宽处理）
   */
  static isPunct(ch: string): boolean {
    const code: number = ch.charCodeAt(0);
    // 全角标点（含 CJK 标点区 0x3000-0x303F 已在 isCJK 覆盖）
    if (code >= 0xFF01 && code <= 0xFF65) {
      return true;
    }
    // 半角标点
    if ((code >= 0x21 && code <= 0x2F) ||  // ! " # $ % & ' ( ) * + , - . /
        (code >= 0x3A && code <= 0x3F) ||  // : ; < = > ? 
        code === 0x40 ||                    // @
        (code >= 0x5B && code <= 0x5F) ||  // [ \ ] ^ _
        code === 0x60 ||                    // `
        (code >= 0x7B && code <= 0x7E)) {  // { | } ~
      return true;
    }
    return false;
  }

  // ── 分词 ──
  // CJK 逐字分词；ASCII 单词（字母/数字）合并；空格单独成 token

  private tokenize(text: string): string[] {
    const tokens: string[] = [];
    let buf: string = '';
    for (let i = 0; i < text.length; i++) {
      const ch: string = text[i];
      if (isCJK(ch)) {
        if (buf.length > 0) {
          tokens.push(buf);
          buf = '';
        }
        tokens.push(ch);
      } else if (isSpace(ch)) {
        if (buf.length > 0) {
          tokens.push(buf);
          buf = '';
        }
        tokens.push(ch);
      } else if (isASCIIWordChar(ch)) {
        buf += ch;
      } else {
        // 其他字符（英文标点等）并入当前缓冲区
        buf += ch;
      }
    }
    if (buf.length > 0) {
      tokens.push(buf);
    }
    return tokens;
  }

  // ── 断行判断 ──
  // breakIdx: 在 token 序列的哪个位置断开
  // tokens[breakIdx] 是新行的第一个 token

  private isBreakAllowed(tokens: string[], breakIdx: number): boolean {
    // 开头和结尾永远允许断
    if (breakIdx <= 0 || breakIdx >= tokens.length) {
      return true;
    }
    const cur: string = tokens[breakIdx];
    const prev: string = tokens[breakIdx - 1];

    // 行尾禁则：prev 不能在行尾
    if (LINE_END_PROHIBITED.indexOf(prev) >= 0) {
      return false;
    }
    // 行首禁则：cur 不能在行首
    if (LINE_START_PROHIBITED.indexOf(cur) >= 0) {
      return false;
    }

    // 空格前断行（空格留在行尾被 trim）
    if (isSpace(cur)) {
      return true;
    }

    // CJK 字符间允许断
    if (isCJK(prev) || isCJK(cur)) {
      return true;
    }

    // 默认允许（ASCII 字母/数字/标点之间）
    return true;
  }

  // ── Knuth-Plass 最优换行 ──

  public breakText(text: string): BreakerResult {
    if (text.length === 0) {
      return { lines: [], totalLines: 0, charsPerLine: 0 };
    }

    // Single-line ellipsis truncation: white-space:nowrap + overflow:hidden + text-overflow:ellipsis
    if (this.whiteSpace === 'nowrap' && this.overflow === 'hidden' && this.textOverflow === 'ellipsis') {
      return this.breakSingleLineWithEllipsis(text);
    }

    const tokens: string[] = this.tokenize(text);
    const nTokens: number = tokens.length;

    // 1) 计算 token 宽度前缀和
    const tokenWidths: number[] = new Array<number>(nTokens);
    for (let i = 0; i < nTokens; i++) {
      tokenWidths[i] = this.measureWidth(tokens[i]);
    }
    const prefixW: number[] = new Array<number>(nTokens + 1);
    prefixW[0] = 0;
    for (let i = 0; i < nTokens; i++) {
      prefixW[i + 1] = prefixW[i] + tokenWidths[i];
    }

    // 1.5) 预计算 CJK 字符和空格 token 前缀和（用于 justify 模式的 stretch-ratio badness）
    const cjkPrefix: number[] = new Array<number>(nTokens + 1);
    const spacePrefix: number[] = new Array<number>(nTokens + 1);
    cjkPrefix[0] = 0;
    spacePrefix[0] = 0;
    for (let i = 0; i < nTokens; i++) {
      const tok: string = tokens[i];
      let cjkCount: number = 0;
      for (let j = 0; j < tok.length; j++) {
        if (isCJK(tok[j])) {
          cjkCount++;
        }
      }
      cjkPrefix[i + 1] = cjkPrefix[i] + cjkCount;
      spacePrefix[i + 1] = spacePrefix[i] + (tok.length === 1 && isSpace(tok[0]) ? 1 : 0);
    }

    // 2) 预计算 isBreakAllowed 以减少 DP 内层重复调用
    const canBreakHere: boolean[] = new Array<boolean>(nTokens + 1);
    canBreakHere[0] = true;
    for (let i = 1; i <= nTokens; i++) {
      canBreakHere[i] = this.isBreakAllowed(tokens, i);
    }

    // 3) 断点候选：所有 token 边界都参与 DP
    // 非允许的位置有额外 badness 惩罚
    const brk: number[] = new Array<number>(nTokens + 1);
    for (let i = 0; i <= nTokens; i++) {
      brk[i] = i;
    }
    const M: number = brk.length;

    // 4) DP: dp[j] = min_i (dp[i] + badness(i,j))
    const INF: number = 1e9;
    const dp: number[] = new Array<number>(M);
    const prv: number[] = new Array<number>(M);
    for (let i = 0; i < M; i++) {
      dp[i] = INF;
      prv[i] = -1;
    }
    dp[0] = 0;

    const maxW: number = Math.max(1, this.maxWidth);
    const spaceWidth: number = this.measureWidth(' ');

    for (let j = 1; j < M; j++) {
      for (let i = 0; i < j; i++) {
        const lineStart: number = brk[i];
        const lineEnd: number = brk[j];
        const lineW: number = prefixW[lineEnd] - prefixW[lineStart];

        // 有效最大宽度：首行减去 textIndent，其余行不变；再乘以 safetyMargin
        const effectiveMaxW: number = (i === 0)
          ? (this.maxWidth - this.textIndent) * this.safetyMargin
          : this.maxWidth * this.safetyMargin;

        // 跳过超宽的多 token 行
        if (lineW > effectiveMaxW && (lineEnd - lineStart > 1)) {
          continue;
        }

        // 计算 badness
        let badness: number;
        if (lineEnd === nTokens) {
          // 最后一行：badness = 0（不追求最后一行填满）
          badness = 0.0;
        } else if (this.textAlign === 'justify' && lineW < effectiveMaxW) {
          // TeX stretch-ratio badness 公式：两端对齐模式下用均匀拉伸比的立方
          const nCJK: number = cjkPrefix[lineEnd] - cjkPrefix[lineStart];
          const nSpaces: number = spacePrefix[lineEnd] - spacePrefix[lineStart];
          const totalStretch: number = Math.max(1, spaceWidth * nSpaces + 2 * spaceWidth * nCJK);
          const stretchRatio: number = (effectiveMaxW - lineW) / totalStretch;
          badness = (stretchRatio * 100) * (stretchRatio * 100) * (stretchRatio * 100) / 10000;
        } else if (lineW <= effectiveMaxW) {
          const diff: number = effectiveMaxW - lineW;
          badness = (diff * diff) / (effectiveMaxW * effectiveMaxW);
        } else {
          // 单 token 超宽
          const over: number = lineW - effectiveMaxW;
          badness = 1.0 + (over * over) / (effectiveMaxW * effectiveMaxW);
        }

        // 非允许断点的惩罚（仅在非最后一行时）
        // 使用预计算的 canBreakHere 替代 isBreakAllowed 调用
        if (lineEnd !== nTokens && !canBreakHere[lineEnd]) {
          badness += 0.5;
        }

        const cost: number = dp[i] + badness;
        if (cost < dp[j]) {
          dp[j] = cost;
          prv[j] = i;
        }
      }
    }

    // 5) 回溯最优断点
    let breakList: number[] = [];
    if (prv[M - 1] >= 0) {
      let cur: number = M - 1;
      while (cur > 0) {
        breakList.unshift(brk[cur]);
        cur = prv[cur];
      }
      breakList.unshift(0);
    } else {
      // DP 异常时回退到贪婪换行
      breakList = [0];
      let accW: number = 0;
      for (let i = 1; i < nTokens; i++) {
        const tw: number = prefixW[i] - prefixW[i - 1];
        if (accW + tw > maxW) {
          breakList.push(i);
          accW = 0;
        } else {
          accW += tw;
        }
      }
      breakList.push(nTokens);
      if (this.onDpFallback !== null) {
        this.onDpFallback(nTokens, breakList.length - 1);
      }
    }

    // 5) 生成 LineBox
    const lines: LineBox[] = [];
    let lineY: number = 0;
    let totalChars: number = 0;

    for (let i = 0; i < breakList.length - 1; i++) {
      const startTok: number = breakList[i];
      const endTok: number = breakList[i + 1];
      if (startTok >= endTok) {
        continue;
      }
      const lineText: string = tokens.slice(startTok, endTok).join('').trim();
      if (lineText.length === 0) {
        continue;
      }

      totalChars += lineText.length;

      const lb: LineBox = createEmptyLineBox();
      lb.text = lineText;
      lb.x = (i === 0) ? this.textIndent : 0;
      lb.y = lineY;
      lb.width = prefixW[endTok] - prefixW[startTok];
      lb.height = this.lineHeight + this.lineSpacing;
      lb.ascent = this.fontSize;
      lb.descent = this.lineHeight + this.lineSpacing - this.fontSize;
      lb.estimatedLines = 1;
      lines.push(lb);

      lineY += this.lineHeight + this.lineSpacing;
    }

    // 6) 对齐 post-processing
    if (lines.length > 0) {
      // 标记最后一行作为段落末行
      lines[lines.length - 1].isLastLineOfParagraph = true;
    }
    const fullWidth: number = this.maxWidth * this.safetyMargin;
    for (let i = 0; i < lines.length; i++) {
      const lb: LineBox = lines[i];
      lb.isCJK = isTextCJK(lb.text);
      if (this.textAlign === 'justify') {
        // 仅非段落末行执行两端对齐
        if (!lb.isLastLineOfParagraph) {
          // 行起点非 0（如首行缩进）时，可用宽度需减去起点偏移，否则末字符超出右边界
          const availableWidth: number = Math.max(1, fullWidth - lb.x);
          justify(lb, availableWidth, this.density);
        }
      } else if (this.textAlign === 'right' || this.textAlign === 'center') {
        // 右对齐 / 居中对齐：先横向平移行（相对整行可用宽度），再按新起点填充字符位置。
        // 右对齐：行末贴右缘；居中：行居中于可用宽度。
        const lineW: number = lb.width;
        const delta: number = this.textAlign === 'right'
          ? fullWidth - (lb.x + lineW)
          : (fullWidth - lineW) / 2 - lb.x;
        if (delta > 0) {
          lb.x += delta;
        }
        this.fillCharPositions(lb);
      } else {
        // 左对齐：填充字符位置（文本选择命中测试依赖 charPositions/charWidths）
        this.fillCharPositions(lb);
      }
    }

    const avgCPL: number = lines.length > 0 ? Math.round(totalChars / lines.length) : 0;

    return { lines, totalLines: lines.length, charsPerLine: avgCPL };
  }

  /**
   * Single-line ellipsis truncation for white-space:nowrap + overflow:hidden + text-overflow:ellipsis.
   * Measures characters one-by-one via measureWidth() and appends ellipsis (…) when the text exceeds maxWidth.
   */
  private breakSingleLineWithEllipsis(text: string): BreakerResult {
    const ellipsis: string = '…';
    const ellipsisW: number = this.measureWidth(ellipsis);
    const availableW: number = Math.max(1, this.maxWidth - ellipsisW);

    if (this.measureWidth(text) <= this.maxWidth) {
      // Text fits without truncation
      const lb: LineBox = createEmptyLineBox();
      lb.text = text;
      lb.x = 0;
      lb.y = 0;
      lb.width = this.measureWidth(text);
      lb.height = this.lineHeight + this.lineSpacing;
      lb.ascent = this.fontSize;
      lb.descent = this.lineHeight + this.lineSpacing - this.fontSize;
      lb.estimatedLines = 1;
      lb.isLastLineOfParagraph = true;
      return { lines: [lb], totalLines: 1, charsPerLine: text.length };
    }

    // Truncate char by char until remaining chars + ellipsis fits
    let truncateLen: number = 0;
    let accW: number = 0;
    for (let i = 0; i < text.length; i++) {
      const charW: number = this.measureWidth(text[i]);
      if (accW + charW > availableW) {
        break;
      }
      accW += charW;
      truncateLen++;
    }

    // Ensure at least 1 char (plus ellipsis) is shown
    if (truncateLen < 1 && text.length > 0) {
      truncateLen = 1;
    }

    const truncated: string = text.substring(0, truncateLen) + ellipsis;
    const totalW: number = accW + ellipsisW;

    const lb: LineBox = createEmptyLineBox();
    lb.text = truncated;
    lb.x = 0;
    lb.y = 0;
    lb.width = totalW;
    lb.height = this.lineHeight + this.lineSpacing;
    lb.ascent = this.fontSize;
    lb.descent = this.lineHeight + this.lineSpacing - this.fontSize;
    lb.estimatedLines = 1;
    lb.isLastLineOfParagraph = true;
    return { lines: [lb], totalLines: 1, charsPerLine: truncateLen };
  }

  /**
   * 为一行填充 charPositions/charWidths（左/右/居中模式用）。
   * 文本选择命中测试（HitTester）依赖这两个数组，缺失会导致长按选词失效；
   * 位置从 line.x 起按 measureWidth 逐字累计，与绘制原点一致。
   */
  private fillCharPositions(line: LineBox): void {
    const text: string = line.text;
    const len: number = text.length;
    if (len === 0) {
      line.charPositions = [];
      line.charWidths = [];
      return;
    }
    const positions: number[] = new Array<number>(len);
    const widths: number[] = new Array<number>(len);
    let cursor: number = line.x;
    for (let i = 0; i < len; i++) {
      positions[i] = cursor;
      const cw: number = this.measureWidth(text[i]);
      widths[i] = cw;
      cursor += cw;
    }
    line.charPositions = positions;
    line.charWidths = widths;
  }
}
