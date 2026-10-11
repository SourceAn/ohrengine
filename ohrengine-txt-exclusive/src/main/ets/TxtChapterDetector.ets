/**
 * TxtChapterDetector — TXT 智能章节标题检测
 *
 * 旧实现仅按空行分段并把每段命名为 "Page N"，目录毫无语义。
 * 本检测器按行扫描，识别常见中文章节标题模式：
 *
 *   - 「第X章 / 第X回 / 第X卷 / 第X节 …」（中文数字或阿拉伯数字 + 可选标题）
 *   - Chapter N / CHAPTER N（含罗马数字）
 *   - 「序章 / 楔子 / 引子 / 尾声 / 后记 / 番外」等独立成行的特殊标题
 *   - 行首阿拉伯数字编号：「12、标题」「3. 标题」
 *
 * 防误判约束：
 *   - 标题必须独占一行（整行匹配），行内出现的「第X章」不影响正文；
 *   - 行长超过 MAX_HEADING_LINE_LENGTH 视为正文；
 *   - 以句末标点结尾的行不视为标题；
 *   - 命中数 < MIN_DETECTED_CHAPTERS 时返回 undefined，
 *     调用方回退到旧的空行分段策略。
 */

import { TxtConfig } from './TxtConfig.ets';

/** 单个章节块：标题 + 原始正文（未做段落结构化） */
export class TxtChapterBlock {
  public readonly title: string;
  public readonly body: string;

  constructor(title: string, body: string) {
    this.title = title;
    this.body = body;
  }
}

export class TxtChapterDetector {
  /** 中文序号字符集（含〇两等异体写法） */
  private static readonly CN_NUM_CLASS: string =
    '0-9０-９零一二三四五六七八九十百千万亿两〇ＯＯ';
  /** 章节单位字 */
  private static readonly CN_UNIT_CLASS: string = '章回节卷集部篇话幕则';

  /** 「第X章 标题」整行匹配 */
  private static readonly PATTERN_CN_NUMBERED: RegExp = new RegExp(
    '^\\s*[（(]?\\s*第\\s*[' + TxtChapterDetector.CN_NUM_CLASS + ']+\\s*' +
    '[' + TxtChapterDetector.CN_UNIT_CLASS + ']' +
    '(\\s*[、.:：．]\\s*|\\s*)[^。！？；，…]{0,' +
    (TxtConfig.MAX_HEADING_LINE_LENGTH - 4) + '}\\s*[)）]?\\s*$');

  /** 「序章/楔子/尾声…」独立成行 */
  private static readonly PATTERN_CN_NAMED: RegExp = new RegExp(
    '^\\s*[（(]?(序章|序言|自序|前言|引子|楔子|尾声|终章|后记|番外' +
    '|附录|后话)[)）]?\\s*$');

  /** 「Chapter 12」/「CHAPTER IV」整行匹配 */
  private static readonly PATTERN_EN_NUMBERED: RegExp = new RegExp(
    '^\\s*(Chapter|CHAPTER|chapter)\\s+([0-9]+|[IVXLCDMivxlcdm]+)' +
    '[^。！？；…]{0,' + (TxtConfig.MAX_HEADING_LINE_LENGTH - 12) + '}\\s*$');

  /** 行首数字编号：「1、标题」「2. 标题」「3：标题」 */
  private static readonly PATTERN_NUMERIC_PREFIX: RegExp = new RegExp(
    '^\\s*[0-9]{1,4}\\s*[、.．,:：]\\s*[^。！？；，…]{1,' +
    (TxtConfig.MAX_HEADING_LINE_LENGTH - 6) + '}\\s*$');

  /** 句末标点：以此结尾的行绝不视为标题 */
  private static readonly SENTENCE_END: string =
    TxtConfig.SENTENCE_ENDING_PUNCTUATION;

  /**
   * 对归一化文本（换行统一为 LF）做章节切分。
   *
   * @param normalizedText - 已做换行归一化的全文
   * @returns 章节块数组；命中标题过少时返回 undefined（回退空行分段）
   */
  public static detect(normalizedText: string): TxtChapterBlock[] | undefined {
    const lines: string[] = normalizedText.split('\n');
    const headingIndexes: number[] = [];
    for (let i: number = 0; i < lines.length; i++) {
      if (TxtChapterDetector.isHeadingLine(lines[i])) {
        headingIndexes.push(i);
      }
    }
    if (headingIndexes.length < TxtConfig.MIN_DETECTED_CHAPTERS) {
      return undefined;
    }

    const blocks: TxtChapterBlock[] = [];
    // 首个标题之前的内容作为「前言/开头」块（无独立标题时可能为全书正文）
    if (headingIndexes[0] > 0) {
      const headBody: string =
        TxtChapterDetector.joinLines(lines, 0, headingIndexes[0]);
      if (headBody.trim().length > 0) {
        blocks.push(new TxtChapterBlock('开篇', headBody));
      }
    }
    for (let h: number = 0; h < headingIndexes.length; h++) {
      const startLine: number = headingIndexes[h];
      const endLine: number = (h + 1 < headingIndexes.length)
        ? headingIndexes[h + 1]
        : lines.length;
      const title: string = lines[startLine].trim();
      const body: string =
        TxtChapterDetector.joinLines(lines, startLine + 1, endLine);
      blocks.push(new TxtChapterBlock(title, body));
    }
    return blocks;
  }

  /**
   * 判断单行是否为章节标题（公开入口，供流式索引复用同一规则）。
   */
  public static isHeadingLineFor(line: string): boolean {
    return TxtChapterDetector.isHeadingLine(line);
  }

  /**
   * 判断单行是否为章节标题。
   */
  private static isHeadingLine(line: string): boolean {
    const trimmed: string = line.trim();
    if (trimmed.length === 0 ||
      trimmed.length > TxtConfig.MAX_HEADING_LINE_LENGTH) {
      return false;
    }
    const lastChar: string = trimmed.charAt(trimmed.length - 1);
    if (TxtChapterDetector.SENTENCE_END.indexOf(lastChar) >= 0) {
      return false;
    }
    return TxtChapterDetector.PATTERN_CN_NUMBERED.test(trimmed) ||
      TxtChapterDetector.PATTERN_CN_NAMED.test(trimmed) ||
      TxtChapterDetector.PATTERN_EN_NUMBERED.test(trimmed) ||
      TxtChapterDetector.PATTERN_NUMERIC_PREFIX.test(trimmed);
  }

  /**
   * 拼接 [start, end) 行区间为正文文本。
   */
  private static joinLines(lines: string[], start: number, end: number): string {
    const parts: string[] = [];
    for (let i: number = start; i < end; i++) {
      parts.push(lines[i]);
    }
    return parts.join('\n');
  }
}
