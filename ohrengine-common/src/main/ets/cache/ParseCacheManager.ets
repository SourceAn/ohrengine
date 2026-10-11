/**
 * ParseCacheManager — EPUB 解析缓存（磁盘持久化）
 *
 * 以源 EPUB 文件（zip）的 size + mtime 为指纹，指纹有效时跳过重复解压与
 * 重复解析（含 App 重启后），实现"一本书只解析一次"。
 *
 * 缓存载体为解压目录内的两个 JSON 文件：
 *   - .fingerprint.json：源文件指纹（statSync 的 size/mtime，毫秒级 number）
 *   - .parsed.json：ParsedBook 的 JSON 序列化结果
 *
 * 缓存文件随解压目录的删除（removeDirRecursive）而自然消失，无需清理策略。
 *
 * 设计约束：
 *   - 纯静态工具类（无状态），全部方法同步实现（fileIo 同步 API）
 *   - 任何内部异常自行吞掉并返回安全默认值（false/null），绝不向调用方抛错
 *   - 缓存损坏/缺失自动回退全量解析流程（FR-006），损坏时删除缓存文件防止反复失败
 */

import { fileIo } from '@kit.CoreFileKit';
import { Publication, createDefaultStyleConfig, createReadingState } from '../document/Publication.ets';
import { BookFormat, RenderStrategy, ParsedBook } from '../spi/ParserRegistry.ets';
import type { ChapterData } from '../spi/ParserRegistry.ets';
import type { Book } from '../document/Book.ets';
import type { Manifest } from '../document/Manifest.ets';
import type { TocItem, ReadingState, Annotation, StyleConfig, CoverInfo, Guide } from '../document/Publication.ets';

/** hilog 统一前缀（与全工程一致） */
const TAG: string = 'OhEngine';
/** 指纹缓存文件名 */
const FINGERPRINT_FILE: string = '.fingerprint.json';
/** 解析结果缓存文件名（旧版整书单文件；新版不再写入，仅迁移用） */
const PARSED_FILE: string = '.parsed.json';
/** 分块缓存目录（Phase 8 D1；与 L2 PageCache 的 chapter_{i}.json 隔离） */
export const PARSE_CHUNK_DIR: string = 'parse';
/** 分块 metadata 文件名 */
const PARSE_META_FILE: string = 'meta.json';
/** 分块章节文件名前缀：chapter_{i}.json */
const PARSE_CHAPTER_PREFIX: string = 'chapter_';

/** 分块 metadata（Phase 8 D1）— 冷启动只反序列化此文件 + 当前所需章节
 *
 * 含：format/strategy/book/cssTexts/imagePaths + chapters 索引
 *（每章 title/href/plainTextLength = offset index）+ 保存时源指纹。
 */
export interface ParseMeta {
  format: string;
  strategy: string;
  book: object | null;
  cssTexts: string[];
  imagePaths?: string[];
  /** 章节索引（offset index）：冷启动无需读章节内容即可获得 plainTextLength */
  chapters: ParseChapterIndex[];
  /** 源文件大小/毫秒 mtime（保存时 stat；加载时与当前 stat 比对） */
  fingerprint: ParseFingerprint;
}

/** 源文件指纹（size + 毫秒 mtime） */
export interface ParseFingerprint {
  size: number;
  mtime: number;
}

/** 分块章节索引条目 */
export interface ParseChapterIndex {
  title: string;
  href: string;
  plainTextLength: number;
}

/**
 * 指纹数据：源 EPUB 文件的 size + mtime（毫秒级时间戳）
 */
interface FingerprintData {
  size: number;
  mtime: number;
}

/** 单章分块数据（Phase 8 D1） */
export interface ParseChapterChunk {
  title: string;
  href: string;
  content: string;
}

/**
 * 分块解析缓存（Phase 8 D1）— 冷启动不整本反序列化
 *
 * 载体（cacheDir 下独立子目录，与 PageCache chapter_{i}.json 无冲突）：
 *   - <cacheDir>/parse/meta.json      ：ParseMeta（含 chapters offset index）
 *   - <cacheDir>/parse/chapter_{i}.json ：单章 {title, href, content}
 *
 * 设计约束：
 *   - 纯静态工具类（无状态），全部方法同步实现（fileIo 同步 API）
 *   - 任何内部异常自行吞掉并返回安全默认值（false/null），绝不向调用方抛错
 *   - 旧版 .parsed.json 保留为迁移源（loadParsedBook 仍可用）；新版写入后删除旧文件
 */
export class ParseCacheManager {
  /** 分块 metadata 是否有效（meta 存在 + 结构完整 + 源指纹匹配） */
  static isChunkedValid(cacheDir: string, sourcePath: string): boolean {
    if (sourcePath.length === 0) {
      return false;
    }
    const meta: ParseMeta | null = ParseCacheManager.readParseMeta(cacheDir);
    if (meta === null) {
      return false;
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(sourcePath);
      return meta.fingerprint.size === stat.size && meta.fingerprint.mtime === stat.mtime;
    } catch (_e) {
      return false;
    }
  }

  /**
   * 读取分块 metadata（仅反序列化元数据 + 章节索引；不读章节内容）。
   */
  static loadParseMeta(cacheDir: string): ParseMeta | null {
    return ParseCacheManager.readParseMeta(cacheDir);
  }

  /**
   * 读取单章分块（title/href/content）。
   */
  static loadParseChapter(cacheDir: string, chapterIndex: number): ParseChapterChunk | null {
    const path: string = cacheDir + '/' + PARSE_CHUNK_DIR + '/' +
      PARSE_CHAPTER_PREFIX + chapterIndex + '.json';
    let text: string = '';
    try {
      text = fileIo.readTextSync(path);
    } catch (_e) {
      return null;
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const title: Object | undefined = raw['title'];
      const href: Object | undefined = raw['href'];
      const content: Object | undefined = raw['content'];
      if (typeof title !== 'string' || typeof href !== 'string' || typeof content !== 'string') {
        return null;
      }
      const chunk: ParseChapterChunk = { title: title, href: href, content: content };
      return chunk;
    } catch (_e) {
      return null;
    }
  }

  /**
   * 写入分块解析缓存（Phase 8 D1）：metadata + 每章独立文件。
   * 同时删除旧版整书 .parsed.json（迁移语义：新版格式权威）。
   *
   * @param cacheDir 缓存目录
   * @param sourcePath 源文件（写入 meta.fingerprint）
   * @param book 解析产物（整书对象仅存在于写盘路径；读盘路径按需加载）
   */
  static saveParsedBookChunked(cacheDir: string, sourcePath: string, book: ParsedBook): void {
    if (book.format !== BookFormat.EPUB) {
      // 分块格式仅用于 EPUB（TXT 无需 L0 持久化）
      ParseCacheManager.saveParsedBook(cacheDir, book);
      return;
    }
    const chunkDir: string = cacheDir + '/' + PARSE_CHUNK_DIR;
    // HarmonyOS mkdirSync(path, true) 对「双级父目录缺失」仍可能抛错——
    // 逐级创建：先确保 cacheDir，再建 chunkDir。
    try {
      fileIo.statSync(cacheDir);
    } catch (_e) {
      try {
        fileIo.mkdirSync(cacheDir, true);
      } catch (_e2) {
      }
    }
    try {
      fileIo.statSync(chunkDir);
    } catch (_e) {
      try {
        fileIo.mkdirSync(chunkDir, true);
      } catch (_e2) {
        return;
      }
    }
    let stat: fileIo.Stat | null = null;
    try {
      stat = fileIo.statSync(sourcePath);
    } catch (_e) {
      stat = null;
    }
    const chapters: ParseChapterIndex[] = [];
    // 章节文件逐个写（失败单个跳过，meta 只记录实际写入成功的章）
    for (let i = 0; i < book.chapters.length; i++) {
      const ch: ChapterData = book.chapters[i];
      try {
        const chunk: ParseChapterChunk = {
          title: ch.title,
          href: ch.href,
          content: ch.content
        };
        const path: string = chunkDir + '/' + PARSE_CHAPTER_PREFIX + i + '.json';
        try {
          fileIo.unlinkSync(path);
        } catch (_e2) {
        }
        const file: fileIo.File = fileIo.openSync(path,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, JSON.stringify(chunk));
        fileIo.closeSync(file);
      } catch (_e3) {
      }
      chapters.push({
        title: ch.title,
        href: ch.href,
        plainTextLength: ParseCacheManager.plainTextLengthOf(ch.content)
      });
    }
    const meta: ParseMeta = {
      format: book.format,
      strategy: book.strategy,
      book: book.book !== null ? book.book : null,
      cssTexts: book.cssTexts,
      imagePaths: book.imagePaths,
      chapters: chapters,
      fingerprint: stat !== null ? { size: stat.size, mtime: stat.mtime } : { size: 0, mtime: 0 }
    };
    try {
      const metaPath: string = chunkDir + '/' + PARSE_META_FILE;
      try {
        fileIo.unlinkSync(metaPath);
      } catch (_e2) {
      }
      const f: fileIo.File = fileIo.openSync(metaPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, JSON.stringify(meta));
      fileIo.closeSync(f);
    } catch (_e3) {
    }
    // 迁移：删除旧版整书文件（新格式权威）
    try {
      fileIo.unlinkSync(cacheDir + '/' + PARSED_FILE);
    } catch (_e4) {
    }
  }

  /**
   * 估算章节文本长度（与 plainText stripped 一致的近似：裸标签剥离 + 空白压缩）。
   * 用于 offset index；精确值在 engine 侧按 extractPlainText 计算，此处为
   * chunked 元数据的长度索引，误差不影响读路径正确性（仅进度估算）。
   */
  private static plainTextLengthOf(html: string): number {
    let text: string = html;
    text = text.replace(/<[^>]*>/g, '');
    text = text.replace(/\s+/g, ' ').trim();
    return text.length;
  }

  /**
   * 读取并校验分块 metadata（缺失/损坏返回 null，不抛错）。
   */
  private static readParseMeta(cacheDir: string): ParseMeta | null {
    const path: string = cacheDir + '/' + PARSE_CHUNK_DIR + '/' + PARSE_META_FILE;
    let text: string = '';
    try {
      text = fileIo.readTextSync(path);
    } catch (_e) {
      return null;
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const format: Object | undefined = raw['format'];
      const strategy: Object | undefined = raw['strategy'];
      const chaptersVal: Object | undefined = raw['chapters'];
      if (typeof format !== 'string' || typeof strategy !== 'string' ||
        chaptersVal === undefined || !Array.isArray(chaptersVal)) {
        return null;
      }
      const chaptersRaw: Object[] = chaptersVal as Object[];
      const chapters: ParseChapterIndex[] = [];
      for (let i = 0; i < chaptersRaw.length; i++) {
        const c: Record<string, Object> = chaptersRaw[i] as Record<string, Object>;
        const title: Object | undefined = c['title'];
        const href: Object | undefined = c['href'];
        const len: Object | undefined = c['plainTextLength'];
        if (typeof title !== 'string' || typeof href !== 'string' || typeof len !== 'number') {
          return null;
        }
        chapters.push({ title: title, href: href, plainTextLength: len });
      }
      let book: object | null = raw['book'] as object | null;
      if (raw['book'] === undefined || raw['book'] === null) {
        book = null;
      }
      const cssTexts: string[] = [];
      const cssVal: Object | undefined = raw['cssTexts'];
      if (cssVal !== undefined && Array.isArray(cssVal)) {
        const cssRaw: Object[] = cssVal as Object[];
        for (let i = 0; i < cssRaw.length; i++) {
          if (typeof cssRaw[i] === 'string') {
            cssTexts.push(cssRaw[i] as string);
          }
        }
      }
      let imagePaths: string[] | undefined = undefined;
      const ipVal: Object | undefined = raw['imagePaths'];
      if (ipVal !== undefined && Array.isArray(ipVal)) {
        imagePaths = ipVal as string[];
      }
      const fpRaw: Record<string, Object> = raw['fingerprint'] as Record<string, Object>;
      const size: Object | undefined = fpRaw !== undefined ? fpRaw['size'] : undefined;
      const mtime: Object | undefined = fpRaw !== undefined ? fpRaw['mtime'] : undefined;
      const meta: ParseMeta = {
        format: format,
        strategy: strategy,
        book: book,
        cssTexts: cssTexts,
        imagePaths: imagePaths,
        chapters: chapters,
        fingerprint: {
          size: typeof size === 'number' ? size : 0,
          mtime: typeof mtime === 'number' ? mtime : 0
        } as ParseFingerprint
      };
      return meta;
    } catch (_e) {
      return null;
    }
  }

  /**
   * 读取并校验指纹：statSync(sourcePath) 的 size/mtime 与缓存指纹逐项相等
   *
   * @param cacheDir - 解压目录绝对路径
   * @param sourcePath - 源 EPUB 文件绝对路径
   * @returns 指纹有效返回 true；无指纹/读失败/不相等返回 false（不抛错）
   */
  static isFingerprintValid(cacheDir: string, sourcePath: string): boolean {
    try {
      const stat: fileIo.Stat = fileIo.statSync(sourcePath);
      const cached: FingerprintData | null = ParseCacheManager.readFingerprint(cacheDir);
      if (cached === null) {
        return false;
      }
      return cached.size === stat.size && cached.mtime === stat.mtime;
    } catch (_e) {
      return false;
    }
  }

  /**
   * 写指纹文件（解压成功后调用，记录源文件的 size/mtime）
   *
   * @param cacheDir - 解压目录绝对路径
   * @param sourcePath - 源 EPUB 文件绝对路径
   */
  static writeFingerprint(cacheDir: string, sourcePath: string): void {
    try {
      const stat: fileIo.Stat = fileIo.statSync(sourcePath);
      const data: FingerprintData = { size: stat.size, mtime: stat.mtime };
      const text: string = JSON.stringify(data);
      const path: string = cacheDir + '/' + FINGERPRINT_FILE;
      // 同 saveParsedBook：先删后写，避免 CREATE 撞已存在文件报 "File exists"。
      try {
        fileIo.unlinkSync(path);
      } catch (_e) {
        // 文件不存在——首次写入路径
      }
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (_e) {
    }
  }

  /**
   * 读解析缓存：文件存在、JSON 可解析、结构完整 → 重建 ParsedBook 返回；否则返回 null
   *
   * 重建策略：`new Publication('')` + 逐字段覆盖（字段缺失回退构造默认值，
   * 见 rehydratePublication）。枚举反序列化后 cast 回 enum 类型。
   * 结构不完整或解析异常时删除损坏缓存文件并返回 null（回退全量解析）。
   *
   * @param cacheDir - 解压目录绝对路径
   * @returns 重建的 ParsedBook；无缓存/损坏返回 null（不抛错）
   */
  static loadParsedBook(cacheDir: string): ParsedBook | null {
    const path: string = cacheDir + '/' + PARSED_FILE;
    let text: string = '';
    try {
      text = fileIo.readTextSync(path);
    } catch (_e) {
      // .parsed.json 不存在（首次打开/指纹不匹配目录被重建）——正常回退路径
      return null;
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const format: BookFormat = raw['format'] as BookFormat;
      const strategy: RenderStrategy = raw['strategy'] as RenderStrategy;
      const chaptersRaw: Object | undefined = raw['chapters'];
      const cssTextsRaw: Object | undefined = raw['cssTexts'];
      if (format === undefined || strategy === undefined ||
        chaptersRaw === undefined || cssTextsRaw === undefined) {
        ParseCacheManager.invalidateCache(cacheDir);
        return null;
      }
      if (!Array.isArray(chaptersRaw) || !Array.isArray(cssTextsRaw)) {
        ParseCacheManager.invalidateCache(cacheDir);
        return null;
      }
      const chapters: ChapterData[] = chaptersRaw as ChapterData[];
      const cssTexts: string[] = cssTextsRaw as string[];
      const imagePathsVal: Object | undefined = raw['imagePaths'];
      let imagePaths: string[] | undefined = undefined;
      if (imagePathsVal !== undefined && Array.isArray(imagePathsVal)) {
        imagePaths = imagePathsVal as string[];
      }
      const bookRaw: Object | undefined = raw['book'];
      let book: Book | null = null;
      if (bookRaw !== undefined && bookRaw !== null) {
        const rehydrated: Publication | null =
          ParseCacheManager.rehydratePublication(bookRaw as Record<string, Object>);
        if (rehydrated === null) {
          ParseCacheManager.invalidateCache(cacheDir);
          return null;
        }
        book = rehydrated;
      }
      const parsed: ParsedBook = new ParsedBook(format, strategy, book, chapters, cssTexts, imagePaths);
      return parsed;
    } catch (_e) {
      ParseCacheManager.invalidateCache(cacheDir);
      return null;
    }
  }

  /**
   * 写解析缓存（parse 成功后调用）：ParsedBook 的 JSON 序列化
   *
   * ParsedBook/Publication 的字段均为 JSON 可序列化数据（方法与 getter 位于
   * prototype，不入 JSON、不受影响）；BookFormat/RenderStrategy 为字符串 enum，
   * 序列化后为 string，反序列化时 cast 回 enum 即可。
   *
   * @param cacheDir - 解压目录绝对路径
   * @param book - 解析产物
   */
  static saveParsedBook(cacheDir: string, book: ParsedBook): void {
    try {
      const text: string = JSON.stringify(book);
      const path: string = cacheDir + '/' + PARSED_FILE;
      // HarmonyOS OpenMode.CREATE 在文件已存在时报 "File exists"，
      // 先删后写保证重复保存（reflow/重复打开）时幂等覆盖。
      try {
        fileIo.unlinkSync(path);
      } catch (_e) {
        // 文件不存在——首次写入路径
      }
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (_e) {
    }
  }

  /**
   * 删除损坏/失效的缓存文件（回退全量流程时调用；文件不存在时静默忽略）
   *
   * @param cacheDir - 解压目录绝对路径
   */
  static invalidateCache(cacheDir: string): void {
    try {
      fileIo.unlinkSync(cacheDir + '/' + PARSED_FILE);
    } catch (_e) {
      // 文件不存在或删除失败——忽略
    }
    try {
      fileIo.unlinkSync(cacheDir + '/' + FINGERPRINT_FILE);
    } catch (_e) {
      // 文件不存在或删除失败——忽略
    }
  }

  /**
   * 读取指纹文件并校验结构（size/mtime 均为 number）
   *
   * @param cacheDir - 解压目录绝对路径
   * @returns 有效指纹；文件缺失/JSON 损坏/结构不完整返回 null（不抛错）
   */
  private static readFingerprint(cacheDir: string): FingerprintData | null {
    const path: string = cacheDir + '/' + FINGERPRINT_FILE;
    let text: string = '';
    try {
      text = fileIo.readTextSync(path);
    } catch (_e) {
      return null;
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const sizeVal: Object | undefined = raw['size'];
      const mtimeVal: Object | undefined = raw['mtime'];
      if (typeof sizeVal !== 'number' || typeof mtimeVal !== 'number') {
        return null;
      }
      const data: FingerprintData = { size: sizeVal, mtime: mtimeVal };
      return data;
    } catch (_e) {
      return null;
    }
  }

  /**
   * 从 chunked meta 的 book（object）重建 Publication（公开，供 engine 使用）。
   * 缺失/损坏返回 null。
   */
  static rehydrateBook(data: object | null): Publication | null {
    if (data === null) {
      return null;
    }
    return ParseCacheManager.rehydratePublication(data as Record<string, Object>);
  }

  /**
   * 从 JSON 数据重建 Publication：`new Publication('')` 后逐字段覆盖
   *
   * ArkTS 限制 Object.assign（arkts-limited-stdlib），故采用逐字段重建；
   * 字段缺失时回退构造默认值。manifest 为必填字段，缺失视为结构不完整。
   *
   * @param data - .parsed.json 中的 book 对象
   * @returns 重建的 Publication；结构不完整/重建失败返回 null（不抛错）
   */
  private static rehydratePublication(data: Record<string, Object>): Publication | null {
    try {
      const manifestVal: Object | undefined = data['manifest'];
      if (manifestVal === undefined) {
        return null;
      }
      const pub: Publication = new Publication('');
      pub.manifest = manifestVal as Manifest;
      pub.styleConfig = (data['styleConfig'] as StyleConfig) ?? createDefaultStyleConfig();
      pub.readingState = (data['readingState'] as ReadingState) ?? createReadingState();
      pub.annotations = (data['annotations'] as Annotation[]) ?? [];
      pub.isEncrypted = (data['isEncrypted'] as boolean) ?? false;
      pub.encryptionProfile = data['encryptionProfile'] as string | undefined;
      pub.toc = (data['toc'] as TocItem[]) ?? [];
      pub.cover = data['cover'] as CoverInfo | undefined;
      pub.guide = data['guide'] as Guide | undefined;
      pub.pageProgressionDirection = (data['pageProgressionDirection'] as string) ?? 'ltr';
      pub.layout = (data['layout'] as string) ?? 'reflowable';
      return pub;
    } catch (_e) {
      return null;
    }
  }
}
