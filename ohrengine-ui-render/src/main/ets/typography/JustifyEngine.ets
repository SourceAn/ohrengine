/**
 * JustifyEngine — 两端对齐逐字定位
 *
 * 在 Knuth-Plass 最优换行完成后，为每一行计算每个字符的精确 x 位置。
 * CJK 行使用均匀字间距；Latin 行使用均匀词间距；最后一行不做拉伸。
 */
import type { LineBox } from 'ohrengine-common';

/**
 * 为一行执行两端对齐，填充 line.charPositions
 * @param line 行盒（需预填 text, width, x, isCJK, isLastLineOfParagraph）
 * @param lineWidth 该行可用的最大宽度（vp）
 * @param density 屏幕密度（px → vp 转换）
 */
export function justify(line: LineBox, lineWidth: number, density: number): void {
  const text: string = line.text;
  const len: number = text.length;
  if (len === 0) {
    line.charPositions = [];
    line.charWidths = [];
    return;
  }

  const positions: number[] = new Array<number>(len);
  const widths: number[] = new Array<number>(len);
  const remaining: number = lineWidth - line.width;

  if (remaining <= 0 || line.isLastLineOfParagraph) {
    // 已超宽或段落最后一行 → 左对齐连续排列
    let cursor: number = line.x;
    for (let i = 0; i < len; i++) {
      positions[i] = cursor;
      const cw: number = measureCharWidth(text[i], line.height, line.ascent, density);
      widths[i] = cw;
      cursor += cw;
    }
    line.charPositions = positions;
    line.charWidths = widths;
    return;
  }

  if (line.isCJK) {
    // ── CJK 行：标点感知均匀字间距（文档 §2.2 adjustForPunctuation） ──
    const spread: number = Math.max(0, remaining) / len;
    let cursor: number = line.x;
    for (let i = 0; i < len; i++) {
      positions[i] = cursor;
      const cw: number = measureCharWidth(text[i], line.height, line.ascent, density);
      widths[i] = cw;
      let gap: number = spread;
      if (i < len - 1) {
        const cur: string = text[i];
        const next: string = text[i + 1];
        if (isLineStartForbidden(next)) {
          gap = spread * 0.3; // 行首禁则符号前只加 30%
        } else if (isLineEndForbidden(cur)) {
          gap = spread * 0.3; // 行尾禁则符号后只加 30%
        } else if (isPunctuation(cur) && isPunctuation(next)) {
          gap = spread * 0.5; // 相邻标点间只加 50%
        }
      }
      cursor += cw + gap;
      // 溢出钳制：末字符不得超过行宽（防止缩进行/测量误差导致超出右边界）
      if (positions[i] > lineWidth) {
        positions[i] = lineWidth;
      }
    }
  } else {
    // ── Latin 行：均匀词间距 ──
    // 按空格分词，在单词之间均匀分配间距
    const segments: string[] = [];
    const segSpaces: boolean[] = [];
    let buf: string = '';
    for (let i = 0; i < len; i++) {
      const ch: string = text[i];
      if (isSpace(ch)) {
        if (buf.length > 0) {
          segments.push(buf);
          segSpaces.push(false);
          buf = '';
        }
        segments.push(ch);
        segSpaces.push(true);
      } else {
        buf += ch;
      }
    }
    if (buf.length > 0) {
      segments.push(buf);
      segSpaces.push(false);
    }

    // 统计词间隙的数量（两个非空格段之间的空格数）
    let gapCount: number = 0;
    for (let i = 0; i < segments.length; i++) {
      if (segSpaces[i]) {
        gapCount++;
      }
    }
    // 如果没空间隙，退化为左对齐
    if (gapCount === 0) {
      let cursor: number = line.x;
      for (let i = 0; i < len; i++) {
        positions[i] = cursor;
        const cw: number = measureCharWidth(text[i], line.height, line.ascent, density);
        widths[i] = cw;
        cursor += cw;
      }
      line.charPositions = positions;
      line.charWidths = widths;
      return;
    }

    const spread: number = remaining / gapCount;

    // 重新逐字计算位置，遇到空格时分配 spread
    let cursor: number = line.x;
    let spaceIdx: number = 0; // 当前经过的第几个词间隙
    for (let i = 0; i < len; i++) {
      const ch: string = text[i];
      positions[i] = cursor;
      const cw: number = measureCharWidth(ch, line.height, line.ascent, density);
      widths[i] = cw;
      cursor += cw;
      if (isSpace(ch) && spaceIdx < gapCount) {
        cursor += spread;
        spaceIdx++;
      }
      // 溢出钳制：末字符不得超过行宽（防止缩进行/测量误差导致超出右边界）
      if (positions[i] > lineWidth) {
        positions[i] = lineWidth;
      }
    }
  }
  line.charPositions = positions;
  line.charWidths = widths;
}

/**
 * 估算单个字符槽宽（vp）— 确定性规则，与 TextBreaker.measureWidth 完全一致。
 *
 * 不再使用 MeasureText 实测：实测宽度与 Canvas 渲染宽度存在偏差，导致
 * justify 逐字位置与渲染错位 → 字块重叠。改为统一槽宽（槽宽 ≥ 渲染字宽）：
 *   - CJK / 全角 / Emoji → 1em（fontSize）
 *   - 全角+半角标点 → 1em（用户要求符号固定 1 字宽，防止符号与汉字重叠）
 *   - 空格 → 0.5em
 *   - 半角字母数字 → 0.55em
 *
 * @param char 待测量字符
 * @param lineHeight 行高（保留，用于未来扩展）
 * @param fontSize 字号（fp）
 * @param density 屏幕密度（保留，不再用于转换）
 */
function measureCharWidth(char: string, lineHeight: number, fontSize: number, density: number): number {
  const code: number = char.charCodeAt(0);
  if (isCJKChar(char)) {
    return fontSize;
  }
  if (code >= 0x1F000) {
    return fontSize; // Emoji
  }
  if (isPunctuation(char)) {
    return fontSize; // 全角+半角标点 → 1em
  }
  if (isSpace(char)) {
    return fontSize * 0.5; // 空格
  }
  return fontSize * 0.55; // 半角字母数字
}

/** CJK/全角字符判定（与 TextBreaker.isCJK 一致） */
function isCJKChar(ch: string): boolean {
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

/** 行首禁则：不能出现在行首的字符 */
function isLineStartForbidden(ch: string): boolean {
  return '」』』〕〉》」』〕】】，。、；：？！）'.indexOf(ch) >= 0;
}

/** 行尾禁则：不能出现在行尾的字符 */
function isLineEndForbidden(ch: string): boolean {
  return '「『『〔〈《「『〔【【（'.indexOf(ch) >= 0;
}

/** 判断是否为标点符号（含半角标点——统一按 1em 槽宽处理，防止与汉字重叠） */
function isPunctuation(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  if (code >= 0x3000 && code <= 0x303F) {  // CJK 符号和标点
    return true;
  }
  if (code >= 0xFF00 && code <= 0xFFEF) {  // 全角 ASCII + 全角标点
    return true;
  }
  if ('，。、；：？！—…·–'.indexOf(ch) >= 0) {
    return true;
  }
  // 半角标点：! " # $ % & ' ( ) * + , - . / : ; < = > ? @ [ \ ] ^ _ ` { | } ~
  if ((code >= 0x21 && code <= 0x2F) ||
      (code >= 0x3A && code <= 0x3F) ||
      code === 0x40 ||
      (code >= 0x5B && code <= 0x5F) ||
      code === 0x60 ||
      (code >= 0x7B && code <= 0x7E)) {
    return true;
  }
  return false;
}
