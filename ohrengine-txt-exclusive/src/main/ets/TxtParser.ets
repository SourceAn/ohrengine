/**
 * TxtParser — Plain text book parser
 *
 * 解析 `.txt` 书籍文件为统一 ParsedBook：
 *
 *   1. 编码自动检测（TxtEncodingDetector）：BOM / UTF-8 校验 /
 *      GB18030 回退，解决中文 GBK 文件乱码；
 *   2. 智能章节检测（TxtChapterDetector）：识别「第X章」等标题行，
 *      生成真实目录语义；命中过少时回退旧的空行分段（"Page N"）；
 *   3. 段落结构化（TxtParagraphSplitter）：正文还原为 <p> 段落 HTML，
 *      含硬换行解包与实体转义。
 *
 * 大文件策略（ENG-004）：
 *   - 小文件（≤ SMALL_FILE_THRESHOLD）同步读取全量字节后解码；
 *   - 大文件分块异步读取 + 流式 TextDecoder（stream:true）解码，
 *     首块读入后即做编码检测，分块边界不破坏多字节字符。
 */

import { BookParser, BookFormat, ParsedBook, RenderStrategy,
  ChapterData, Book, Publication, TocItem, createLinkWithTitle } from 'ohrengine-common';
import type { TxtLazyDocument } from 'ohrengine-common';
import { TxtEncodingDetector } from './TxtEncodingDetector.ets';
import { TxtChapterDetector, TxtChapterBlock } from './TxtChapterDetector.ets';
import { TxtParagraphSplitter } from './TxtParagraphSplitter.ets';
import { TxtDocument } from './TxtDocument.ets';
import { TxtLazyConfig } from './TxtLazyConfig.ets';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class TxtParser implements BookParser {
  public readonly format: BookFormat = BookFormat.TXT;

  /** 小文件阈值：≤ 该字节数走同步简单路径（保持旧实现行为与精确语义） */
  private static readonly SMALL_FILE_THRESHOLD: number = 5 * 1024 * 1024;
  /** 大文件分块读取大小 */
  private static readonly CHUNK_SIZE: number = 256 * 1024;

  /**
   * Parse a plain text book file.
   *
   * @param filePath - Absolute path to the .txt file
   * @returns ParsedBook with structured chapters (<p> paragraph HTML)
   */
  public async parse(filePath: string): Promise<ParsedBook> {
    const fileSize: number = TxtParser.safeFileSize(filePath);
    const content: string = fileSize > TxtParser.SMALL_FILE_THRESHOLD
      ? await this.readTextFileChunked(filePath, fileSize)
      : this.readTextFileSync(filePath);
    const chapters: ChapterData[] =
      TxtParser.buildChapters(TxtParser.normalizeNewlines(content));

    return new ParsedBook(
      BookFormat.TXT,
      RenderStrategy.REFLOW,
      null,
      chapters,
      []
    );
  }

  /**
   * getBook — Book 接口工厂方法（格式无关入口）
   *
   * 解析 TXT 并返回 Book 接口实例。
   * TXT 无原生元数据，故构造最小 Publication：
   * 标题取文件名，章节映射为 readingOrder 与 toc。
   *
   * @param filePath - Absolute path to the .txt file
   * @returns Book 接口实例
   */
  public async getBook(filePath: string): Promise<Book> {
    const parsed: ParsedBook = await this.parse(filePath);
    const publication: Publication = new Publication(this.titleFromPath(filePath));
    for (let i = 0; i < parsed.chapters.length; i++) {
      const chapter: ChapterData = parsed.chapters[i];
      publication.manifest.readingOrder.push(
        createLinkWithTitle(chapter.href, 'text/plain', chapter.title));
      const item: TocItem = { title: chapter.title, href: chapter.href };
      publication.toc.push(item);
    }
    return publication;
  }

  /**
   * openTxtLazyDocument — Phase 9：打开 TXT 惰性数据源。
   *
   * @param filePath 源 TXT 文件
   * @param cacheDir 缓存目录（索引持久化）
   * @param libraryDir 持久目录（导入成果；不受 cache 清理/配额/迁移影响）。缺省时退回现状。
   * @returns 惰性文档；开关关闭/构建失败时返回 undefined（引擎回退 eager parse）
   */
  public async openTxtLazyDocument(filePath: string, cacheDir: string, libraryDir?: string): Promise<TxtLazyDocument | undefined> {
    if (!TxtLazyConfig.isEnabled()) {
      hilog.warn(0x0000, 'OhEngine', 'TXT-LAZY disabled-by-config');
      return undefined;
    }
    const doc: TxtDocument | undefined = await TxtDocument.open(filePath, cacheDir, libraryDir);
    hilog.info(0x0000, 'OhEngine', 'TXT-LAZY openLazy called path=%{public}s cache=%{public}s lib=%{public}s doc=%{public}d',
      filePath, cacheDir, libraryDir !== undefined ? libraryDir : '', doc === undefined ? 0 : 1);
    return doc;
  }

  // ==================== 章节构建 ====================

  /**
   * 归一化全文 → 章节列表。
   *
   * 优先使用智能章节检测；未命中足够标题时回退空行分段（旧行为，
   * 标题为 "Page N"），保证无章节结构的纯文本仍可正常阅读。
   */
  private static buildChapters(normalizedText: string): ChapterData[] {
    const chapters: ChapterData[] = [];
    const detected: TxtChapterBlock[] | undefined =
      TxtChapterDetector.detect(normalizedText);

    if (detected !== undefined) {
      for (let i = 0; i < detected.length; i++) {
        const block: TxtChapterBlock = detected[i];
        chapters.push({
          title: block.title.length > 0 ? block.title : '第' + (i + 1) + '章',
          content: TxtParagraphSplitter.toHtml(TxtParagraphSplitter.split(block.body)),
          href: 'chapter-' + (i + 1)
        });
      }
      return chapters;
    }

    // 回退：按空行分段（保持旧实现语义）
    const blocks: string[] = TxtParagraphSplitter.split(normalizedText);
    const paragraphsPerPage: number = 40;
    let pageIndex: number = 0;
    while (pageIndex * paragraphsPerPage < blocks.length) {
      const start: number = pageIndex * paragraphsPerPage;
      const end: number = Math.min(start + paragraphsPerPage, blocks.length);
      const pageParts: string[] = [];
      for (let i = start; i < end; i++) {
        pageParts.push(blocks[i]);
      }
      chapters.push({
        title: 'Page ' + (pageIndex + 1),
        content: TxtParagraphSplitter.toHtml(pageParts),
        href: 'page-' + (pageIndex + 1)
      });
      pageIndex++;
    }
    return chapters;
  }

  private static normalizeNewlines(text: string): string {
    return text
      .replace(new RegExp('\\r\\n', 'g'), '\n')
      .replace(new RegExp('\\r', 'g'), '\n');
  }

  /**
   * 从文件路径提取书名（去掉目录与扩展名）。
   */
  private titleFromPath(filePath: string): string {
    const lastSlash: number = filePath.lastIndexOf('/');
    const fileName: string = lastSlash >= 0 ? filePath.substring(lastSlash + 1) : filePath;
    const dot: number = fileName.lastIndexOf('.');
    if (dot > 0) {
      return fileName.substring(0, dot);
    }
    return fileName;
  }

  // ==================== 文件读取与解码 ====================

  /**
   * Synchronously read a text file into a string.
   * 仅用于小文件；编码自动检测（BOM/UTF-8/GB18030）。
   */
  private readTextFileSync(filePath: string): string {
    let file: fileIo.File;
    try {
      file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
    } catch (e) {
      throw new Error('TxtParser.readTextFileSync: open failed: ' + (e instanceof Error ? e.message : String(e)));
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      const bufSize: number = stat.size;
      const buf: ArrayBuffer = new ArrayBuffer(bufSize);
      const readLen: number = fileIo.readSync(file.fd, buf, { offset: 0, length: bufSize });
      const bytes: Uint8Array = new Uint8Array(buf.slice(0, readLen));
      return TxtParser.decodeBytes(bytes);
    } catch (e) {
      throw new Error('TxtParser.readTextFileSync: read failed: ' + (e instanceof Error ? e.message : String(e)));
    } finally {
      try {
        fileIo.closeSync(file);
      } catch (_e) {
        // 忽略关闭失败
      }
    }
  }

  /**
   * 分块异步读取大文本文件并流式解码为字符串（ENG-004）。
   *
   * - 首块读入后立即做编码检测，后续按同一编码流式解码；
   * - decodeToString 使用 { stream: true }，分块边界上的不完整
   *   多字节序列由解码器内部缓存，下次调用时继续处理；
   * - 最后以空输入 + stream:false flush 结尾，确保尾部字节被解码。
   *
   * @param filePath - 文件绝对路径
   * @param fileSize - 文件字节数（调用方已 stat）
   */
  private async readTextFileChunked(filePath: string, fileSize: number): Promise<string> {
    let file: fileIo.File;
    try {
      file = await fileIo.open(filePath, fileIo.OpenMode.READ_ONLY);
    } catch (e) {
      throw new Error('TxtParser.readTextFileChunked: open failed: ' + (e instanceof Error ? e.message : String(e)));
    }
    try {
      const chunkBuf: ArrayBuffer = new ArrayBuffer(TxtParser.CHUNK_SIZE);
      const parts: string[] = [];
      let textDecoder: util.TextDecoder | undefined = undefined;
      let consumed: number = 0;
      while (consumed < fileSize) {
        let bytesRead: number;
        try {
          bytesRead = await fileIo.read(file.fd, chunkBuf);
        } catch (e) {
          throw new Error('TxtParser.readTextFileChunked: read failed: ' + (e instanceof Error ? e.message : String(e)));
        }
        if (bytesRead <= 0) {
          break; // 已到文件尾（防御：stat 与实际读取不一致）
        }
        const chunk: Uint8Array = new Uint8Array(chunkBuf.slice(0, bytesRead));
        if (textDecoder === undefined) {
          textDecoder = util.TextDecoder.create(
            TxtEncodingDetector.detect(chunk));
        }
        parts.push(textDecoder.decodeToString(chunk, { stream: true }));
        consumed += bytesRead;
      }
      if (textDecoder === undefined) {
        return '';
      }
      // flush 末尾缓冲的不完整序列
      parts.push(textDecoder.decodeToString(new Uint8Array(0), { stream: false }));
      return parts.join('');
    } finally {
      try {
        fileIo.closeSync(file);
      } catch (_e) {
        // 忽略关闭失败
      }
    }
  }

  /**
   * 按检测到的编码解码字节为字符串。
   */
  private static decodeBytes(bytes: Uint8Array): string {
    const encodingName: string = TxtEncodingDetector.detect(bytes);
    const textDecoder: util.TextDecoder = util.TextDecoder.create(encodingName);
    return textDecoder.decodeToString(bytes);
  }

  /**
   * 安全获取文件大小；stat 失败返回 -1（parse 回退同步路径，其内部会抛可理解错误）。
   */
  private static safeFileSize(filePath: string): number {
    try {
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      return stat.size;
    } catch (_e) {
      return -1;
    }
  }
}
