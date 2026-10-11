/**
 * VChapter — TXT 虚拟章节索引层（Phase 8 D2）
 *
 * 语义（00 L89-90 + Phase 0：canonical = 全局 UTF-16 charOffset）：
 *   - 在章节 plain text（HTML 剥标签后的文本）上按「每 5000–10000 chars、
 *     段落边界」切分虚拟章节 vchapter_XXXXX；
 *   - 切分确定性：同输入 → 同 vchapter 集合（缓存键稳定，不依赖布局）；
 *   - vchapter ID 与 pageIndex 无关，禁止进入 CacheKey 的唯一性来源。
 *
 * 本模块只负责「切分决策 + ID 生成 + 章节内映射」：
 *   输入章节（HTML <p>…</p>）→ 输出 vchapter 列表（id/startEndChar/paragraphs）。
 *
 * 迁移（旧 chapter-N）：
 *   old chapter-index ↔ 由 oldChapterStart 数组定位首/次 vchapter；
 *   恢复时旧 chapter-N 映射到该章的 vchapter 范围。
 */

/** 目标段大小（字符数）：**目标**，允许 ±PARA_MAX_OVER 超调至段落边界 */
export const VCHAPTER_TARGET_CHARS: number = 8000;
/** 单段允许超调上限，避免小段落切割爆段 */
export const VCHAPTER_MAX_OVER: number = 2000;

/** vchapter ID 前缀 */
export const VCHAPTER_PREFIX: string = 'vchapter_';

/** 虚拟章节（输入为 HTML 段落文本列表） */
export interface VChapterDef {
  /** vchapter_XXXXX */
  id: string;
  /** 本章在全书章节序列中的全局序号（0-based） */
  index: number;
  /** 所在旧章 idx（拆分前的原章序号） */
  oldChapterIndex: number;
  /** 本 vchapter 在旧章中的段落起止（含） */
  paraStart: number;
  paraEnd: number;
  /** 本 vchapter 的全文（HTML <p> 连接） */
  html: string;
  /** 旧章内 plainText 起始字符偏移（累计） */
  charStart: number;
  /** 旧章内 plainText 结束字符偏移（累计，开区间） */
  charEnd: number;
}

/** 单章的 vchapter 索引（供映射/恢复用） */
export interface VChapterMapping {
  oldChapterIndex: number;
  vchapterRangeStart: number;
  vchapterCount: number;
}

/**
 * 生成 vchapter id：vchapter_00001（5 位，确定，前缀）。
 */
export function vchapterId(globalIndex: number): string {
  let num: string = String(globalIndex);
  while (num.length < 5) {
    num = '0' + num;
  }
  return VCHAPTER_PREFIX + num;
}

/**
 * 由「旧章 ID」解析旧章索引（chapter-1 → 0，page-N → N-1 归一章）。
 * @param chapterId 旧格式章节 id（chapter-N / page-N）
 * @returns 旧章索引；无法解析返回 -1
 */
export function oldChapterIndexFromId(chapterId: string): number {
  if (chapterId.startsWith('chapter-')) {
    const num: number = parseInt(chapterId.substring('chapter-'.length), 10);
    return !isNaN(num) && num > 0 ? num - 1 : -1;
  }
  if (chapterId.startsWith('page-')) {
    const num: number = parseInt(chapterId.substring('page-'.length), 10);
    return !isNaN(num) && num > 0 ? num - 1 : -1;
  }
  return -1;
}

/**
 * 将「章节 HTML」（epub 风格，但 TXT 引擎输入为 <p>…</p> 连接）切为 vchapter 列表。
 *
 * @param chapterIndex 旧章索引
 * @param paragraphs 该章段落文本（strip 后）
 * @param texts 与 paragraphs 等长的段落原始 HTML（<p>text</p>）
 * @returns vchapter 定义（按顺序；至少一个——空章返回单空 vchapter）
 */
export function buildVChapters(chapterIndex: number,
  paragraphs: string[], texts: string[], idStartIndex: number = 0): VChapterDef[] {
  const result: VChapterDef[] = [];
  if (paragraphs.length === 0) {
    result.push({
      id: vchapterId(idStartIndex),
      index: 0,
      oldChapterIndex: chapterIndex,
      paraStart: 0,
      paraEnd: 0,
      html: '',
      charStart: 0,
      charEnd: 0
    });
    return result;
  }
  // Phase 24（Issue A 根因修复 #2）：id 序号从 idStartIndex 起（全局连续），
  // 禁止每次调用从 0 重计——否则跨旧章 vchapter id 撞号，恢复解析错章。
  let globalIndex: number = idStartIndex;
  let paraStart: number = 0;
  let charStart: number = 0;
  let charsAcc: number = 0;
  for (let i = 0; i < paragraphs.length; i++) {
    const len: number = paragraphs[i].length;
    // 达到目标且段落即将结束（或下一段将超出最大超调）→ 在此段后切开
    const over: number = charsAcc + len - VCHAPTER_TARGET_CHARS;
    const isLast: boolean = i === paragraphs.length - 1;
    const shouldCut: boolean = (charsAcc + len >= VCHAPTER_TARGET_CHARS && over >= 0 && !isLast) ||
      over >= VCHAPTER_MAX_OVER;
    if (shouldCut || isLast) {
      // 构造 html：texts[paraStart..i] 拼接
      let html: string = '';
      for (let j = paraStart; j <= i; j++) {
        html += texts[j];
      }
      result.push({
        id: vchapterId(globalIndex),
        index: globalIndex,
        oldChapterIndex: chapterIndex,
        paraStart: paraStart,
        paraEnd: i,
        html: html,
        charStart: charStart,
        charEnd: charStart + (charsAcc + len)
      } as VChapterDef);
      globalIndex++;
      paraStart = i + 1;
      charStart = charStart + (charsAcc + len);
      charsAcc = 0;
    } else {
      charsAcc += len;
    }
  }
  return result;
}