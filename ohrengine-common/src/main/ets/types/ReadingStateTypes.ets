/**
 * ReadingStateTypes — 阅读位置恢复的纯数据类型与工具（Phase 1）
 *
 * 身份模型（《00-总控》三身份之一）：
 *   ReadingAnchor = { chapterId, paragraphIndex, paragraphHash, charOffset }
 *   ReadingState  = { schemaVersion, bookId, chapterId, anchor,
 *                     visualPageIndex, layoutSignature, lastReadTime,
 *                     contentFingerprint }
 *
 * 坐标约定（Phase 0 结论）：
 *   - canonical logicalOffset = 章节 stripped plain text 内的全局 UTF-16 charOffset；
 *   - ReadingAnchor.charOffset 为「段落内」偏移（paragraph-relative），UTF-16 单位；
 *   - paragraphIndex/paragraphHash 用于内容命中验证，global char 用于定位页面。
 *
 * paragraphIndex 不是全局唯一 ID：paragraphHash 允许重复，恢复时按最近邻选择。
 */

/** 阅读状态 schema 版本：ReadingState 结构不兼容时递增 */
export const READING_STATE_SCHEMA_VERSION: number = 1;

/** 段落 hash 算法标识（写入 hash 前缀，未来算法变更可区分） */
export const PARAGRAPH_HASH_ALGORITHM: string = 'fnv1a';

/** 段落提取时视为段落边界的块级标签（与 extractPlainText 的对齐） */
const BLOCK_CLOSE_TAGS: string[] = [
  'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li',
  'blockquote', 'tr', 'section', 'article', 'figure', 'figcaption',
  'td', 'th', 'header', 'footer', 'aside', 'pre', 'hr'
];

/**
 * ReadingAnchor — 阅读锚点（不可合并进 CacheKey，也不可替代 ReadingState）
 */
export interface ReadingAnchor {
  /** 章节稳定 ID：EPUB 取 spine href；TXT 取 virtual chapter id（Phase 1 先用 'chapter-N' 语义） */
  chapterId: string;
  /** 章节内段落下标（0-based，按段落提取结果） */
  paragraphIndex: number;
  /** 段落文本散列（fnv1a32，hex 字符串），仅用于命中验证，非全局唯一 */
  paragraphHash: string;
  /** 段落内 UTF-16 charOffset（paragraph-relative） */
  charOffset: number;
}

/**
 * ReadingState — 持久化阅读状态（L1）
 */
export interface ReadingState {
  schemaVersion: number;
  /** 稳定书 ID（与 history/bookmark 一致：EPUB dc:identifier 或 title） */
  bookId: string;
  /** 章节稳定 ID（与 ReadingAnchor.chapterId 一致性） */
  chapterId: string;
  anchor: ReadingAnchor;
  /** 派生态：视觉页码（可 stale，禁止作为唯一恢复依据） */
  visualPageIndex: number;
  /** 保存时的布局签名（layoutSignature 变化时重新映射 visualPageIndex） */
  layoutSignature: string;
  /** 最后阅读时间（epoch ms） */
  lastReadTime: number;
  /** 保存时的内容指纹（size:mtime）；改变时 ReadingState 失效 */
  contentFingerprint: string;
}

/**
 * 计算段落 FNV-1a 32 位散列（确定性、无锁、不依赖系统库）。
 * @param text 段落文本（UTF-16 编码单位参与计算）
 * @returns 8 位十六进制小写字符串
 */
export function hashParagraphText(text: string): string {
  let h: number = 0x811c9dc5;
  for (let i: number = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return PARAGRAPH_HASH_ALGORITHM + ':' + h.toString(16);
}

/**
 * 提取章节 HTML 的段落序列（确定性，不依赖布局/CSS 编译）。
 *
 * 以块级闭合标签与 <br>/<hr> 为段落边界，剥离标签并对齐实体，
 * 空白压缩后按行拆分；空行丢弃。结果与 extractPlainText 近似，
 * 但保留段落边界，用于 ReadingAnchor.paragraphIndex 的稳定映射。
 *
 * @param html 章节 HTML
 * @returns 段落文本数组（空章节返回 []）
 */
export function extractParagraphs(html: string): string[] {
  let text: string = html;
  // 移除 script/style 内容
  text = text.replace(/<script[^>]*>[\s\S]*?<\/script>/gi, '');
  text = text.replace(/<style[^>]*>[\s\S]*?<\/style>/gi, '');
  // 块级闭合标签 → 段落分隔
  for (let i: number = 0; i < BLOCK_CLOSE_TAGS.length; i++) {
    const tag: string = BLOCK_CLOSE_TAGS[i];
    text = text.replace(new RegExp('</' + tag + '[^>]*>', 'gi'), '\n');
    text = text.replace(new RegExp('<' + tag + '[^>]*>', 'gi'), '\n');
  }
  // 自闭合换行标签
  text = text.replace(/<br\s*\/?>/gi, '\n');
  // 剥离剩余标签
  text = text.replace(/<[^>]*>/g, '');
  // 对齐实体
  text = text.replace(/&nbsp;/g, ' ');
  text = text.replace(/&amp;/g, '&');
  text = text.replace(/&lt;/g, '<');
  text = text.replace(/&gt;/g, '>');
  text = text.replace(/&quot;/g, '"');
  text = text.replace(/&#39;/g, "'");
  // 按段落边界先拆行（保留 \n 分隔），再对每行压缩空白
  const rawLines: string[] = text.split('\n');
  const paragraphs: string[] = [];
  for (let i: number = 0; i < rawLines.length; i++) {
    const line: string = rawLines[i].replace(/\s+/g, ' ').trim();
    if (line.length > 0) {
      paragraphs.push(line);
    }
  }
  return paragraphs;
}

/**
 * 计算段落全局起始字符偏移数组（章节内，UTF-16）。
 * paragraphs[i] 的起始 offset = starts[i]，长度 = paragraphLengths[i]。
 * @param paragraphs 段落文本数组
 * @returns starts[i] 第 i 个段落在章节 plain text 内的起始字符偏移
 */
export function computeParagraphStarts(paragraphs: string[]): number[] {
  const starts: number[] = [];
  let acc: number = 0;
  for (let i: number = 0; i < paragraphs.length; i++) {
    starts.push(acc);
    acc += paragraphs[i].length;
  }
  return starts;
}

/**
 * 校验 charOffset 是否落在段落文本范围内（含段落末尾边界）。
 * @param charOffset 段落内偏移
 * @param paragraphText 段落文本
 * @returns 合法返回原值；越界返回 clamp 后的安全值
 */
export function clampParagraphCharOffset(charOffset: number, paragraphText: string): number {
  if (charOffset < 0) {
    return 0;
  }
  if (charOffset > paragraphText.length) {
    return paragraphText.length;
  }
  return charOffset;
}