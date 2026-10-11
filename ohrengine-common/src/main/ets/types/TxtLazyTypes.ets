/**
 * TxtLazyTypes — TXT Lazy 数据源的类型契约（Phase 9）
 *
 * 目的：让引擎（ohrengine-ui-render）只依赖 common 抽象，
 * 由 format 专属模块（ohrengine-txt-exclusive 的 TxtDocument）实现细节。
 *
 * 数据流：
 *   TxtParser.parse() 仍保留（回退/小文件）；当需要 lazy 打开时，
 *   OhEngineCore 调用 parser.openTxtLazyDocument(filePath, cacheDir)，
 *   得到 TxtLazyDocument，通过 provider 按需提供 vchapter HTML，
 *   不再整本 eager parse。
 */

import type { BookFormat } from '../spi/ParserRegistry.ets';

/**
 * TXT vchapter 描述（字节范围 + 元数据）。
 *
 * 字段语义：
 *   - id: 'vchapter_XXXXX'（与 expandTxtToVChapters 的 id 规则一致，序数连续）
 *   - oldChapterIndex: 该 vch 所属旧章（TxtChapterDetector 章节）索引
 *   - byteStart/byteEnd: 源文件字节范围（开/闭区间约定：含 start，不含 end）
 *   - charStart/charEnd: 旧章内 plain text 的 UTF-16 字符偏移（累计，抽取段落长度）
 *   - paraStart/paraEnd: 该 vch 在旧章段落列表中的起止段落下标（含起，含止）
 *   - plainTextLength: extractPlainText(该 vch html).length（与 eager 路径一致）
 */
export interface TxtVChapterRef {
  id: string;
  oldChapterIndex: number;
  title: string;
  byteStart: number;
  byteEnd: number;
  charStart: number;
  charEnd: number;
  paraStart: number;
  paraEnd: number;
  plainTextLength: number;
}

/**
 * 旧章（第X章 / Page N）的字节范围（索引定位用）。
 */
export interface TxtOldChapterRef {
  index: number;
  title: string;
  byteStart: number;
  byteEnd: number;
  /** 该旧章首个 vch 的全局序（与 expandTxtToVChapters 的 vchapter index 一致） */
  vchStart: number;
  /** 该旧章 vch 数量 */
  vchCount: number;
}

/**
 * TXT 轻量索引（Phase 9.1）：
 * 只记录「如何找到数据」，不保存正文。
 */
export interface TxtIndexRef {
  /** 索引格式版本 */
  version: number;
  /** 源文件字节数 */
  fileSize: number;
  /** 编码（'utf-8' | 'utf-16le' | 'utf-16be' | 'gb18030'） */
  encoding: string;
  /** 换行模式（'lf' | 'crlf' | 'cr' | 'mixed'） */
  newlineMode: string;
  /** 内容指纹（size:mtime，与 getContentFingerprint 口径一致） */
  contentFingerprint: string;
  /** 目标 chunk 字节数（索引粒度） */
  chunkSize: number;
  /** chunk 数（按需读取的最小定位单元） */
  chunkCount: number;
  /** 旧章数 */
  oldChapterCount: number;
  /** vchapter 总数（== 引擎侧 chapter 数） */
  vchapterCount: number;
  /** 全书记录的 plain text 长度（进度条用） */
  totalPlainTextLength: number;
}

/**
 * TXT Lazy 文档（引擎消费接口；实现：TxtDocument）
 */
export interface TxtLazyDocument {
  /** 格式标识 */
  readonly format: BookFormat;
  /** 索引摘要 */
  readonly index: TxtIndexRef;
  /** vchapter 数（引擎侧 chapter 数） */
  getVChapterCount(): number;
  /** 某 vch 的标题 */
  getVChapterTitle(index: number): string;
  /** 某 vch 的字节范围 */
  getVChapterRange(index: number): TxtVChapterRef | undefined;
  /** 提供某 vch 的 HTML（惰性：读取字节范围 → 解码 → 段落切分 → HTML） */
  getVChapterHtml(index: number): string | undefined;
  /** isolate 某 vch 的 plain text 长度（避免全量 extractPlainText） */
  getPlainTextLength(index: number): number;
  /** 旧章 → 首 vch 全局序（migration：旧 chapter-N / page-N 锚点） */
  getOldChapterToVchapterStart(): number[];
  /** 旧章 → vch 数量 */
  getOldChapterVchapterCounts(): number[];
  /** 解析某 chapterId（vchapter_XXXXX / chapter-N / page-N）→ 引擎 chapter 索引 */
  resolveChapter(chapterId: string): number;
  /** 释放资源（关闭 fd / 清缓存），销毁时调用 */
  release(): void;
  /** 清理内存：淘汰距 center 超过 keepRadius 的已解码缓存（9.6） */
  trimCache(center: number, keepRadius: number): void;
  /** 统计字符串（benchmark / 观测） */
  stats(): string;
}