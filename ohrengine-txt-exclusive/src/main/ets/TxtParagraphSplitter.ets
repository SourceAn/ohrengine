/**
 * TxtParagraphSplitter — TXT 段落结构化
 *
 * 旧实现把整章纯文本直接塞进 HTML 管线，段间结构丢失。
 * 本切分器将章节正文还原为段落级结构并生成 <p> HTML：
 *
 *   - 段落边界：空行（\n\s*\n）优先；块内再按「句末标点断行 /
 *     下一行缩进」解包硬换行（固定宽度换行的文本可正确合并）；
 *   - 单段超过 MAX_MERGED_PARAGRAPH_LENGTH 强制断段兜底；
 *   - 输出前做 HTML 实体转义（& < >），防止正文中的尖括号
 *     被下游 HtmlParser 当作标签吞掉。
 */

import { TxtConfig } from './TxtConfig.ets';

export class TxtParagraphSplitter {
  /**
   * 将章节正文切分为段落数组。
   *
   * @param bodyText - 章节原始正文（换行应为 LF）
   * @returns 非空段落数组
   */
  public static split(bodyText: string): string[] {
    const paragraphs: string[] = [];
    const rawBlocks: string[] =
      TxtParagraphSplitter.splitByBlankLines(bodyText);
    for (let b: number = 0; b < rawBlocks.length; b++) {
      const blockLines: string[] = TxtParagraphSplitter.toLines(rawBlocks[b]);
      TxtParagraphSplitter.mergeBlockLines(blockLines, paragraphs);
    }
    return paragraphs;
  }

  /**
   * 段落数组 → 章节 HTML（每段一个 <p>，已做实体转义）。
   */
  public static toHtml(paragraphs: string[]): string {
    const parts: string[] = [];
    for (let i: number = 0; i < paragraphs.length; i++) {
      const escaped: string = TxtParagraphSplitter.escapeHtml(paragraphs[i]);
      if (escaped.length > 0) {
        parts.push('<p>' + escaped + '</p>');
      }
    }
    return parts.join('\n');
  }

  /**
   * 按空行切块（连续空行视为一个分隔符）。
   */
  private static splitByBlankLines(text: string): string[] {
    const normalized: string = text
      .replace(new RegExp('\\r\\n', 'g'), '\n')
      .replace(new RegExp('\\r', 'g'), '\n');
    const blocks: string[] = [];
    const pattern: RegExp = new RegExp('\\n\\s*\\n', 'g');
    let lastEnd: number = 0;
    let match: RegExpExecArray | null;
    while ((match = pattern.exec(normalized)) !== null) {
      const block: string = normalized.substring(lastEnd, match.index);
      if (block.trim().length > 0) {
        blocks.push(block);
      }
      lastEnd = match.index + match[0].length;
    }
    const tail: string = normalized.substring(lastEnd);
    if (tail.trim().length > 0) {
      blocks.push(tail);
    }
    return blocks;
  }

  /**
   * 块内按行拆分并去掉空行/首尾空白与全角缩进。
   */
  private static toLines(block: string): string[] {
    const rawLines: string[] = block.split('\n');
    const lines: string[] = [];
    for (let i: number = 0; i < rawLines.length; i++) {
      const trimmed: string = rawLines[i]
        .replace(new RegExp('^[　 \\t]+', ''), '')
        .replace(new RegExp('[　 \\t]+$', ''), '');
      if (trimmed.length > 0) {
        lines.push(trimmed);
      }
    }
    return lines;
  }

  /**
   * 硬换行解包：把被排版软件强制折断的行合并回同一段落。
   *
   * 断段条件（满足其一且当前缓冲非空）：
   *   - 缓冲以句末标点结尾；
   *   - 合并后长度超 MAX_MERGED_PARAGRAPH_LENGTH（强制兜底）。
   */
  private static mergeBlockLines(lines: string[], out: string[]): void {
    let buffer: string = '';
    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i];
      if (buffer.length > 0 &&
        (TxtParagraphSplitter.endsWithSentencePunct(buffer) ||
          buffer.length + line.length > TxtConfig.MAX_MERGED_PARAGRAPH_LENGTH)) {
        out.push(buffer);
        buffer = '';
      }
      buffer = buffer.length === 0 ? line : buffer + line;
    }
    if (buffer.length > 0) {
      out.push(buffer);
    }
  }

  private static endsWithSentencePunct(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    const lastChar: string = text.charAt(text.length - 1);
    return TxtConfig.SENTENCE_ENDING_PUNCTUATION.indexOf(lastChar) >= 0;
  }

  private static escapeHtml(text: string): string {
    let out: string = text;
    out = out.replace(/&/g, '&amp;');
    out = out.replace(/</g, '&lt;');
    out = out.replace(/>/g, '&gt;');
    return out;
  }
}
