/**
 * ParserRegistry — Book format parser registry
 *
 * Central registry for BookParser implementations.
 * Each parser (EpubParser, TxtParser, CbzParser, etc.) registers
 * itself here. OhEngineCore uses ParserRegistry to resolve the
 * correct parser for a given file extension.
 *
 * Design:
 *   - ARCH-004：支持实例化（`new ParserRegistry()`）以隔离测试/多引擎；
 *     静态 API（register/resolve/resolveByExtension/getBook/getAll）作为
 *     过渡期兼容入口保留，新核心代码优先使用注入实例。
 *   - Keyed by BookFormat enum
 *   - resolveByExtension() maps file extension → BookFormat → BookParser
 */

import type { Book } from '../document/Book.ets';
import type { TxtLazyDocument } from '../types/TxtLazyTypes.ets';

/**
 * 从文件路径中提取扩展名（含点号，如 '.epub'）
 */
function extractExtension(filePath: string): string {
  const lastSlash = filePath.lastIndexOf('/');
  const fileName = lastSlash >= 0 ? filePath.substring(lastSlash + 1) : filePath;
  const dot = fileName.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  return fileName.substring(dot);
}

/**
 * Supported book formats.
 */
export enum BookFormat {
  EPUB = 'epub',
  TXT = 'txt',
  CBZ = 'cbz',
  PDF = 'pdf'
}

/**
 * Rendering strategy that determines how a book is displayed.
 */
export enum RenderStrategy {
  REFLOW = 'reflow',
  IMAGE = 'image',
  FIXED = 'fixed'
}

/**
 * A single chapter/section extracted from a parsed book.
 */
export interface ChapterData {
  /** Chapter title (from OPF toc or auto-generated) */
  title: string;
  /** Chapter content — HTML (EPUB) or plain text (TXT) */
  content: string;
  /** Source href relative to the container root */
  href: string;
  /**
   * Image file paths contained in this chapter (CBZ/comic formats).
   *
   * Optional — only set by image-oriented parsers. Absolute paths
   * usable directly by renderers (e.g. native CBZ image strategy).
   * Absent/undefined means the chapter carries no direct images.
   */
  imagePaths?: string[];
}

/**
 * Parsed book — the unified output of any BookParser.
 *
 * All parsers (EPUB, TXT, CBZ, PDF) produce this structure.
 * Downstream consumers (StrategyRouter implementations) read
 * from this object and do NOT access raw source files.
 */
export class ParsedBook {
  /** The original book format */
  format: BookFormat;
  /** Rendering strategy this book requires */
  strategy: RenderStrategy;
  /** Book metadata (title, author, cover, etc.) */
  book: Book | null;
  /** Chapter/section content list */
  chapters: ChapterData[];
  /** Extracted CSS text content (EPUB) or empty for TXT/CBZ */
  cssTexts: string[];
  /**
   * All image file paths of the book in reading order (CBZ/comic formats).
   *
   * Optional — only set by image-oriented parsers. Absent/undefined
   * means the book carries no direct top-level image list.
   */
  imagePaths?: string[];

  constructor(
    format: BookFormat,
    strategy: RenderStrategy,
    book: Book | null,
    chapters: ChapterData[],
    cssTexts: string[],
    imagePaths?: string[]
  ) {
    this.format = format;
    this.strategy = strategy;
    this.book = book;
    this.chapters = chapters;
    this.cssTexts = cssTexts;
    this.imagePaths = imagePaths;
  }
}

/**
 * BookParser interface — implemented by all format parsers.
 *
 * Each parser reads a source file and produces a unified ParsedBook.
 * Parsers are registered in ParserRegistry at app startup.
 */
export interface BookParser {
  /** The format this parser handles */
  readonly format: BookFormat;
  /**
   * Parse a book file and return a structured ParsedBook.
   *
   * @param filePath - Absolute path to the book file
   * @returns ParsedBook with all chapters and metadata
   */
  parse(filePath: string): Promise<ParsedBook>;
  /**
   * (可选) 打开 TXT 惰性数据源（Phase 9）：返回 null / undefined 表示不支持或
   * 不应使用 lazy 路径（引擎回退 eager parse）。
   *
   * @param filePath 源 TXT 文件
   * @param cacheDir 缓存目录（索引可持久化）
   * @param libraryDir 持久目录（导入成果；不受 cache 清理/配额/迁移影响）。缺省时行为退回现状。
   * @returns TxtLazyDocument 或 undefined
   */
  openTxtLazyDocument?(filePath: string, cacheDir: string, libraryDir?: string): Promise<TxtLazyDocument | undefined>;
}

/**
 * Renders whether a format is allowed by the enabled-format whitelist.
 * Empty whitelist means all formats allowed (default).
 */
function isAllowed(format: BookFormat, enabled: Set<BookFormat>): boolean {
  if (enabled.size === 0) {
    return true;
  }
  return enabled.has(format);
}

/**
 * ParserRegistry — singleton registry for BookParser implementations.
 *
 * Usage (at app startup):
 *   import { EpubParser } from 'ohrengine-parsers';
 *   ParserRegistry.register(new EpubParser());
 *
 *   const parser = ParserRegistry.resolve(BookFormat.EPUB);
 *   const book = await parser.parse('/path/to/book.epub');
 */
export class ParserRegistry {
  private static parsers: Map<BookFormat, BookParser> = new Map();

  // ==================== 实例化 API（ARCH-004） ====================
  // 每个实例持有独立 Map，支持测试隔离与多引擎；新核心代码优先用实例。

  private readonly instanceParsers: Map<BookFormat, BookParser> = new Map();

  // 可用格式白名单：空集合 = 全部可用（兼容既有行为）；非空则仅允许集合内格式
  private static enabledFormats: Set<BookFormat> = new Set();
  private readonly instanceEnabledFormats: Set<BookFormat> = new Set();

  /** 实例化一个独立的 ParserRegistry（空注册表） */
  constructor() {
  }

  /** 实例方法：注册解析器 */
  register(parser: BookParser): void {
    this.instanceParsers.set(parser.format, parser);
  }

  /** 实例方法：设置可用格式白名单（空集合 = 全部可用） */
  setEnabledFormats(formats: Set<BookFormat>): void {
    this.instanceEnabledFormats.clear();
    const arr: BookFormat[] = Array.from(formats);
    for (let i = 0; i < arr.length; i++) {
      this.instanceEnabledFormats.add(arr[i]);
    }
  }

  /** 实例方法：恢复全部格式可用 */
  enableAllFormats(): void {
    this.instanceEnabledFormats.clear();
  }

  private instanceAllowed(format: BookFormat): boolean {
    return isAllowed(format, this.instanceEnabledFormats);
  }

  /** 实例方法：按格式解析 */
  resolve(format: BookFormat): BookParser | undefined {
    return this.instanceAllowed(format) ? this.instanceParsers.get(format) : undefined;
  }

  /** 实例方法：按扩展名解析 */
  resolveByExtension(ext: string): BookParser | undefined {
    const formatMap: Record<string, BookFormat> = {
      '.epub': BookFormat.EPUB,
      '.txt': BookFormat.TXT,
      '.cbz': BookFormat.CBZ,
      '.cbr': BookFormat.CBZ,
      '.pdf': BookFormat.PDF
    };
    const format: BookFormat | undefined = formatMap[ext.toLowerCase()];
    if (format === undefined) {
      return undefined;
    }
    if (!this.instanceAllowed(format)) {
      return undefined;
    }
    return this.instanceParsers.get(format);
  }

  /** 实例方法：按文件路径解析并返回 Book 接口 */
  async getBook(filePath: string): Promise<Book | undefined> {
    const parser = this.resolveByExtension(extractExtension(filePath));
    if (parser === undefined) {
      return undefined;
    }
    const parsed = await parser.parse(filePath);
    if (parsed.book === null) {
      return undefined;
    }
    return parsed.book;
  }

  /** 实例方法：全部解析器快照 */
  getAll(): Map<BookFormat, BookParser> {
    return new Map(this.instanceParsers);
  }

  /** 实例方法：清空（测试/销毁用） */
  clear(): void {
    this.instanceParsers.clear();
  }

  // ==================== 静态兼容 API（过渡期保留） ====================

  /**
   * Register a BookParser implementation.
   *
   * @param parser - Parser instance to register
   */
  static register(parser: BookParser): void {
    ParserRegistry.parsers.set(parser.format, parser);
  }

  /** 静态 API：设置可用格式白名单（空集合 = 全部可用） */
  static setEnabledFormats(formats: Set<BookFormat>): void {
    ParserRegistry.enabledFormats.clear();
    const arr: BookFormat[] = Array.from(formats);
    for (let i = 0; i < arr.length; i++) {
      ParserRegistry.enabledFormats.add(arr[i]);
    }
  }

  /** 静态 API：恢复全部格式可用 */
  static enableAllFormats(): void {
    ParserRegistry.enabledFormats.clear();
  }

  /**
   * Resolve a parser by BookFormat.
   *
   * @param format - The book format to look up
   * @returns The registered parser, or undefined if not registered
   */
  static resolve(format: BookFormat): BookParser | undefined {
    if (!isAllowed(format, ParserRegistry.enabledFormats)) {
      return undefined;
    }
    return ParserRegistry.parsers.get(format);
  }

  /**
   * Resolve a parser by file extension.
   *
   * @param ext - File extension including the dot (e.g., '.epub', '.txt')
   * @returns The registered parser, or undefined if no parser handles this extension
   */
  static resolveByExtension(ext: string): BookParser | undefined {
    const formatMap: Record<string, BookFormat> = {
      '.epub': BookFormat.EPUB,
      '.txt': BookFormat.TXT,
      '.cbz': BookFormat.CBZ,
      '.cbr': BookFormat.CBZ,
      '.pdf': BookFormat.PDF
    };
    const format: BookFormat | undefined = formatMap[ext.toLowerCase()];
    if (format === undefined) {
      return undefined;
    }
    if (!isAllowed(format, ParserRegistry.enabledFormats)) {
      return undefined;
    }
    return ParserRegistry.parsers.get(format);
  }

  /**
   * 按文件路径解析图书，并通过 Book 接口派发（格式无关入口）。
   *
   * @param filePath - 图书文件绝对路径
   * @returns Book 接口实例；无对应解析器或产物无 Book 时返回 undefined
   */
  static async getBook(filePath: string): Promise<Book | undefined> {
    const parser = ParserRegistry.resolveByExtension(extractExtension(filePath));
    if (parser === undefined) {
      return undefined;
    }
    const parsed = await parser.parse(filePath);
    if (parsed.book === null) {
      return undefined;
    }
    return parsed.book;
  }

  /**
   * Get all registered parsers.
   */
  static getAll(): Map<BookFormat, BookParser> {
    return new Map(ParserRegistry.parsers);
  }
}
