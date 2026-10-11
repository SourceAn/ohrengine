/**
 * ImportService — 图书统一导入入口（导入即解析）+ 可逆导出
 *
 * 唯一对外可复用的导入入口：任何想要使用本阅读引擎的项目，都必须通过本入口
 * 导入图书，禁止各自实现「拷贝 / 解压 / 解析」。
 *
 * 核心语义：
 *   导入 == 解析。导入一步完成「接入源文件 →（EPUB/CBZ）解压 → 解析 →
 *   解析结果持久化」，因此已导入图书的再次打开均为热启动/暖启动（命中既有
 *   解析缓存/索引，跳过重新解压与解析）：
 *     - EPUB：`ParseCacheManager.saveParsedBookChunked`（parse/meta.json +
 *       parse/chapter_i.json）+ `writeFingerprint`（解压目录 .fingerprint.json）
 *     - TXT ：`BookParser.openTxtLazyDocument`（library/<bookName>/txt-index-v2.json）
 *     - CBZ ：透明透传（接入源文件 + 解压，维持现状，不提供本特性的导入/导出承诺）
 *     - PDF/未知：明确拒绝（UNSUPPORTED），不写任何半初始化产物
 *
 *   可逆导出：导入保留原始源文件（books/<name>），`exportBook` 复制其字节到
 *   导出目录（默认 filesDir/exports/），产物与源逐字节一致，供分享。
 *
 * 依赖约束：仅依赖同模块（ohrengine-common）抽象与既有工具，不依赖
 * ohrengine-ui-render / ohrengine-reader，从结构上排除依赖环。
 *
 * 布局契约（与引擎 OhEngineCore.open / ReaderHost.openAndLoad 一致）：
 *   - 源文件：filesDir/books/<name>
 *   - EPUB/CBZ 解压目录：filesDir/books/<name>_extracted
 *   - 解析缓存：filesDir/cache/books/<bookName>   （bookName = deriveBookName）
 *   - 持久目录：filesDir/library/<bookName>
 */

import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BookFormat, ParserRegistry } from '../spi/ParserRegistry.ets';
import type { BookParser, ParsedBook } from '../spi/ParserRegistry.ets';
import type { TxtLazyDocument } from '../types/TxtLazyTypes.ets';
import { ParseCacheManager } from '../cache/ParseCacheManager.ets';
import { ImportCheckpoint, ImportStage } from '../cache/ImportCheckpoint.ets';
import { BookStorage } from '../storage/BookStorage.ets';
import { SecureArchive } from '../storage/SecureArchive.ets';
import { DiskCacheQuotaManager } from '../cache/DiskCacheQuotaManager.ets';
import { ImportedBookStore } from './ImportedBookStore.ets';
import { ImportStatus, DeleteStatus } from './ImportTypes.ets';
import type { ImportRequest, ImportResult, ImportedBook, ExportArtifact,
  DeleteResult, DeleteOptions, BookAssociatedDataCleaner,
  BatchImportProgress, BatchImportResult } from './ImportTypes.ets';
import { ReadingStateStore } from '../runtime/ReadingStateStore.ets';

/** hilog 统一前缀（与全工程一致） */
const TAG: string = 'OhEngine';
/** TXT 索引文件名（与 TxtDocument 一致，用于热启动有效性判定） */
const TXT_INDEX_FILE: string = 'txt-index-v2.json';

export class ImportService {
  /**
   * 唯一导入入口（幂等）。
   *
   * @param filesDir 应用沙箱根（ctx.filesDir）
   * @param request 导入请求（sourcePath 或 sourceUri 二选一）
   * @param onProgress 可选进度回调（阶段名）
   * @returns 导入结果；UNSUPPORTED 不产生任何产物，FAILED 不落为已导入
   */
  static async importBook(filesDir: string, request: ImportRequest,
    onProgress?: (stage: string) => void): Promise<ImportResult> {
    if (filesDir.length === 0) {
      return ImportService.fail('', 'filesDir 为空');
    }
    // 1) 解析来源与扩展名（在拒绝前不产生任何产物）
    const hasPath: boolean = request.sourcePath !== undefined && request.sourcePath.length > 0;
    const hasUri: boolean = request.sourceUri !== undefined && request.sourceUri.length > 0;
    if (!hasPath && !hasUri) {
      return ImportService.fail('', 'sourcePath 与 sourceUri 至少提供一个');
    }
    const inputPath: string = hasPath ? (request.sourcePath as string) : (request.sourceUri as string);
    const displayName: string = ImportService.deriveDisplayName(request, inputPath);
    const ext: string = ImportService.extOf(displayName);
    const format: BookFormat | undefined = ImportService.formatOfExt(ext);
    if (format === undefined) {
      hilog.info(0x0000, TAG, 'Import: unsupported ext=%{public}s name=%{public}s', ext, displayName);
      return {
        status: ImportStatus.UNSUPPORTED,
        bookId: '',
        error: '不支持的格式：' + (ext.length > 0 ? ext : '未知扩展名') + '（仅支持 .epub / .txt；.cbz 透传）'
      };
    }
    ImportService.report(onProgress, 'ingest');

    // 2) 接入源文件（受控保留，唯一化命名；不覆盖既有书籍数据）
    const booksDir: string = filesDir + '/books';
    ImportService.mkdirp(booksDir);
    const retained: string = ImportService.ingest(inputPath, booksDir, displayName);
    if (retained.length === 0) {
      return ImportService.fail('', '源文件不存在或无法读取：' + displayName);
    }
    const srcStat: fileIo.Stat | null = ImportService.safeStat(retained);
    if (srcStat === null) {
      return ImportService.fail('', '无法读取源文件：' + retained);
    }
    const fingerprint: string = String(srcStat.size) + ':' + String(srcStat.mtime);
    const bookId: string = ext + ':' + ImportService.baseName(retained) + ':' + String(srcStat.size);

    // 3) 幂等快速路径：台账命中且产物有效 → 热启动，不触发解压/解析
    const existing: ImportedBook | undefined = ImportedBookStore.findById(filesDir, bookId);
    const existingValid: boolean = existing !== undefined && ImportService.isRecordValid(existing);
    if (existingValid && existing !== undefined) {
      hilog.info(0x0000, TAG, 'Import: hit bookId=%{public}s (warm start, skip unzip/parse)', bookId);
      return { status: ImportStatus.ALREADY_IMPORTED, bookId: bookId, record: existing };
    }
    if (existing !== undefined) {
      hilog.info(0x0000, TAG, 'Import: miss-invalidated bookId=%{public}s (rebuild)', bookId);
    } else {
      hilog.info(0x0000, TAG, 'Import: miss bookId=%{public}s (cold import)', bookId);
    }

    // Phase 6 配额：导入前淘汰超配的可重建缓存（不删源书）
    new DiskCacheQuotaManager().enforceGlobalQuota(filesDir);

    const bookName: string = ImportService.baseName(retained);
    const cacheDir: string = BookStorage.pageCacheDirOf(filesDir, bookName);
    const libraryDir: string = BookStorage.libraryDirOf(filesDir, bookName);
    let extractDir: string = '';
    let title: string = ImportService.titleFromName(displayName);

    try {
      if (format === BookFormat.EPUB) {
        // ---- EPUB：接入 → 解压 → 解析 → 分块解析缓存落盘 + 指纹 ----
        extractDir = booksDir + '/' + bookName + '_extracted';
        ImportService.report(onProgress, 'unzip');
        await SecureArchive.decompressArchive(retained, extractDir, filesDir);
        ImportCheckpoint.markStage(extractDir, ImportStage.UNZIP_DONE);
        ParseCacheManager.writeFingerprint(extractDir, retained);
        const parser: BookParser | undefined = ParserRegistry.resolve(BookFormat.EPUB);
        if (parser === undefined) {
          throw new Error('EPUB 解析器未注册');
        }
        ImportService.report(onProgress, 'parse');
        const parsed: ParsedBook = await parser.parse(extractDir);
        title = ImportService.bookTitle(parsed, title);
        ImportService.report(onProgress, 'persist');
        ParseCacheManager.saveParsedBookChunked(cacheDir, retained, parsed);
        ImportCheckpoint.markStage(extractDir, ImportStage.PARSE_DONE);
        ImportCheckpoint.markStage(extractDir, ImportStage.CACHE_DONE);
      } else if (format === BookFormat.TXT) {
        // ---- TXT：接入 → 惰性索引构建并持久化到 library/<bookName>/ ----
        const parser: BookParser | undefined = ParserRegistry.resolve(BookFormat.TXT);
        if (parser === undefined) {
          throw new Error('TXT 解析器未注册');
        }
        ImportService.report(onProgress, 'index');
        let indexed: boolean = false;
        const lazyOpen: ((filePath: string, cacheDir2: string, libraryDir2?: string) =>
          Promise<TxtLazyDocument | undefined>) | undefined = parser.openTxtLazyDocument;
        if (lazyOpen !== undefined) {
          const doc: TxtLazyDocument | undefined = await lazyOpen(retained, cacheDir, libraryDir);
          if (doc !== undefined && doc.getVChapterCount() > 0) {
            indexed = true;
            doc.release();
          }
        }
        if (!indexed) {
          // 回退 eager 解析（与引擎 TXT 路径一致；不写 L0 分块缓存）
          const parsed: ParsedBook = await parser.parse(retained);
          title = ImportService.bookTitle(parsed, title);
        }
        ImportCheckpoint.markStage(libraryDir, ImportStage.INDEX_DONE);
      } else {
        // ---- CBZ：透传（接入源文件 + 解压，维持现状）----
        extractDir = booksDir + '/' + bookName + '_extracted';
        ImportService.report(onProgress, 'unzip');
        await SecureArchive.decompressArchive(retained, extractDir, filesDir);
        ImportCheckpoint.markStage(extractDir, ImportStage.UNZIP_DONE);
        ParseCacheManager.writeFingerprint(extractDir, retained);
      }
    } catch (e) {
      // 失败原子性：不落台账；清理可能的半成品（仅当此前无有效产物时）
      if (extractDir.length > 0 && !existingValid) {
        ImportService.removeDir(extractDir);
      }
      hilog.info(0x0000, TAG, 'Import: failed bookId=%{public}s err=%{public}s', bookId, ImportService.errText(e));
      return ImportService.fail(bookId, '导入失败：' + ImportService.errText(e));
    }

    const record: ImportedBook = {
      bookId: bookId,
      format: ext,
      title: title,
      sourcePath: retained,
      extractDir: extractDir,
      cacheDir: cacheDir,
      libraryDir: libraryDir,
      fingerprint: fingerprint,
      importedAt: Date.now()
    };
    ImportedBookStore.upsert(filesDir, record);
    ImportService.report(onProgress, 'done');
    hilog.info(0x0000, TAG, 'Import: success bookId=%{public}s format=%{public}s source=%{public}s',
      bookId, ext, retained);
    return { status: ImportStatus.SUCCESS, bookId: bookId, record: record };
  }

  /**
   * 批量导入入口（统一入口的批量能力，唯一批量路径）。
   *
   * 对 `requests` **逐本串行**处理，每本复用单本 `importBook` 语义（接入 + 解压 +
   * 解析 + 落盘 + 台账；幂等；失败原子性）。任一项 `FAILED`/`UNSUPPORTED` 时
   * **记录并继续**下一本，不抛错、不中止整批；返回逐本 `ImportResult` 与汇总计数。
   * 空列表 → 返回 `total=0` 的安全空结果。
   *
   * 本方法为批量唯一入口（FR-002）：调用方 MUST 经此入口批量导入，禁止绕过统一
   * 入口自行实现批量拷贝/解压/解析。
   *
   * @param filesDir 应用沙箱根（ctx.filesDir）
   * @param requests 单本导入请求列表（`BatchImportRequest` 即其数组）
   * @param onProgress 可选批量进度回调（每本处理前 + 单本阶段名转发）
   * @returns 逐本结果与汇总（total/succeeded/alreadyImported/unsupported/failed）
   */
  static async importBooks(filesDir: string, requests: ImportRequest[],
    onProgress?: (p: BatchImportProgress) => void): Promise<BatchImportResult> {
    const results: ImportResult[] = [];
    const total: number = requests.length;
    if (total === 0) {
      hilog.info(0x0000, TAG, 'ImportBatch: empty total=0 (safe)');
      const empty: BatchImportResult = {
        results: results, total: 0, succeeded: 0, alreadyImported: 0, unsupported: 0, failed: 0
      };
      return empty;
    }
    let succeeded: number = 0;
    let alreadyImported: number = 0;
    let unsupported: number = 0;
    let failed: number = 0;
    hilog.info(0x0000, TAG, 'ImportBatch: start total=%{public}d', total);
    for (let i = 0; i < total; i++) {
      const request: ImportRequest = requests[i];
      const requestName: string = ImportService.requestName(request);
      ImportService.reportBatch(onProgress, i, total, requestName, 'begin');
      let item: ImportResult;
      try {
        // 逐本串行复用单本语义；阶段名转发给批量进度回调
        item = await ImportService.importBook(filesDir, request, (stage: string): void => {
          ImportService.reportBatch(onProgress, i, total, requestName, stage);
        });
      } catch (e) {
        // 防御：单本实现约定不抛错；意外抛出仍按失败计入并继续（跳过失败继续）
        item = ImportService.fail('', '导入异常：' + ImportService.errText(e));
      }
      results.push(item);
      if (item.status === ImportStatus.SUCCESS) {
        succeeded++;
        hilog.info(0x0000, TAG, 'ImportBatch: success idx=%{public}d name=%{public}s bookId=%{public}s',
          i, requestName, item.bookId);
      } else if (item.status === ImportStatus.ALREADY_IMPORTED) {
        alreadyImported++;
        hilog.info(0x0000, TAG, 'ImportBatch: already idx=%{public}d name=%{public}s',
          i, requestName);
      } else if (item.status === ImportStatus.UNSUPPORTED) {
        unsupported++;
        hilog.info(0x0000, TAG, 'ImportBatch: skip-unsupported idx=%{public}d name=%{public}s err=%{public}s',
          i, requestName, item.error !== undefined ? item.error : '');
      } else {
        failed++;
        hilog.info(0x0000, TAG, 'ImportBatch: skip-failed idx=%{public}d name=%{public}s err=%{public}s',
          i, requestName, item.error !== undefined ? item.error : '');
      }
    }
    const summary: BatchImportResult = {
      results: results, total: total, succeeded: succeeded, alreadyImported: alreadyImported,
      unsupported: unsupported, failed: failed
    };
    hilog.info(0x0000, TAG,
      'ImportBatch: done total=%{public}d success=%{public}d already=%{public}d unsupported=%{public}d failed=%{public}d',
      total, succeeded, alreadyImported, unsupported, failed);
    return summary;
  }

  /**
   * 同步查询台账（不触发解析）：供宿主/书架判定「是否已导入/热启动」并获取路径。
   * 台账命中且指纹有效（含解析产物有效性）才返回；否则返回 undefined。
   */
  static resolve(filesDir: string, sourcePath: string): ImportedBook | undefined {
    if (filesDir.length === 0 || sourcePath.length === 0) {
      return undefined;
    }
    let rec: ImportedBook | undefined = ImportedBookStore.findBySource(filesDir, sourcePath);
    if (rec === undefined) {
      const stat: fileIo.Stat | null = ImportService.safeStat(sourcePath);
      if (stat === null) {
        return undefined;
      }
      const ext: string = ImportService.extOf(sourcePath);
      const bookId: string = ext + ':' + ImportService.baseName(sourcePath) + ':' + String(stat.size);
      rec = ImportedBookStore.findById(filesDir, bookId);
    }
    if (rec === undefined) {
      return undefined;
    }
    if (!ImportService.isRecordValid(rec)) {
      return undefined;
    }
    return rec;
  }

  /**
   * 可逆导出：将已导入图书还原为原始格式（EPUB/TXT），产物与源逐字节一致。
   *
   * @param filesDir 应用沙箱根
   * @param bookId 台账中该书的稳定标识
   * @param destDir 导出目录（缺省 filesDir/exports/）
   * @returns 导出产物（path/fileName/format/size）
   * @throws Error 记录缺失 / 格式不支持 / 源文件缺失 / 写入失败
   */
  static async exportBook(filesDir: string, bookId: string, destDir?: string): Promise<ExportArtifact> {
    const rec: ImportedBook | undefined = ImportedBookStore.findById(filesDir, bookId);
    if (rec === undefined) {
      throw new Error('未找到导入记录：' + bookId);
    }
    if (rec.format !== '.epub' && rec.format !== '.txt') {
      throw new Error('该格式不支持导出：' + rec.format);
    }
    if (!ImportService.exists(rec.sourcePath)) {
      throw new Error('原始源文件不存在，无法导出：' + ImportService.baseName(rec.sourcePath));
    }
    const srcStat: fileIo.Stat | null = ImportService.safeStat(rec.sourcePath);
    if (srcStat === null) {
      throw new Error('无法读取原始源文件：' + ImportService.baseName(rec.sourcePath));
    }
    const outDir: string = (destDir !== undefined && destDir.length > 0) ? destDir : filesDir + '/exports';
    ImportService.mkdirp(outDir);
    const dest: string = ImportService.uniquePath(outDir, ImportService.baseName(rec.sourcePath));
    if (!ImportService.copyFile(rec.sourcePath, dest)) {
      throw new Error('导出写入失败');
    }
    const outStat: fileIo.Stat | null = ImportService.safeStat(dest);
    const artifact: ExportArtifact = {
      path: dest,
      fileName: ImportService.baseName(dest),
      format: rec.format,
      size: outStat !== null ? outStat.size : srcStat.size
    };
    hilog.info(0x0000, TAG, 'Import: export bookId=%{public}s -> %{public}s bytes=%{public}d',
      bookId, dest, artifact.size);
    return artifact;
  }

  // ==================== 彻底删除（唯一删除入口）====================

  /** 已注册的跨模块关联数据清理钩子（应用层在启动时注册） */
  private static cleaners: BookAssociatedDataCleaner[] = [];

  /**
   * 注册跨模块关联数据清理钩子（应用层在启动时调用）。
   * 钩子用于清理共享层不可直接访问的模块数据（批注 SQLite、书签 Preferences 等）。
   */
  static registerAssociatedDataCleaner(cleaner: BookAssociatedDataCleaner): void {
    if (cleaner === undefined) {
      return;
    }
    ImportService.cleaners.push(cleaner);
  }

  /** 清空已注册的清理钩子（测试/销毁用） */
  static clearAssociatedDataCleaners(): void {
    ImportService.cleaners = [];
  }

  /**
   * 彻底删除（唯一删除入口，幂等）。
   *
   * 顺序（避免幽灵条目）：
   *   ① 读取台账记录 → ② 先移除台账并回读校验（失败 FAILED）
   *   → ③ 清理核心产物（源文件 / 解压目录 / 缓存目录 / library 目录 / 阅读进度）
   *   → ④ 调用已注册清理钩子（批注 / 书签）。
   * 核心清理或钩子失败计入 `failedItems`，状态为 `PARTIAL`（台账已移除，书架不残留）。
   * 台账未命中 → `NOT_FOUND`（安全返回，不抛错）。全程 `Import:`/`OhEngine` 前缀日志。
   *
   * @param filesDir 应用沙箱根（ctx.filesDir）
   * @param bookId 台账中该书的稳定标识
   * @param opts 删除选项（阅读进度目录）
   */
  static async deleteBook(filesDir: string, bookId: string, opts?: DeleteOptions): Promise<DeleteResult> {
    const cleaned: string[] = [];
    const failed: string[] = [];
    if (filesDir.length === 0 || bookId.length === 0) {
      hilog.warn(0x0000, TAG, 'Delete: invalid-args bookId=%{public}s', bookId);
      return { status: DeleteStatus.FAILED, bookId: bookId, title: '', cleanedItems: cleaned, failedItems: failed };
    }
    // ① 读取台账记录
    const record: ImportedBook | undefined = ImportedBookStore.findById(filesDir, bookId);
    if (record === undefined) {
      hilog.info(0x0000, TAG, 'Delete: not-found bookId=%{public}s (safe)', bookId);
      return { status: DeleteStatus.NOT_FOUND, bookId: bookId, title: '', cleanedItems: cleaned, failedItems: failed };
    }
    const title: string = record.title;
    // ② 先移除台账记录并回读校验（书架以台账为准，先移除可避免幽灵条目）
    ImportedBookStore.remove(filesDir, bookId);
    if (ImportedBookStore.findById(filesDir, bookId) !== undefined) {
      hilog.warn(0x0000, TAG, 'Delete: ledger-remove-failed bookId=%{public}s', bookId);
      failed.push('ledger');
      return { status: DeleteStatus.FAILED, bookId: bookId, title: title, cleanedItems: cleaned, failedItems: failed };
    }
    cleaned.push('ledger');
    // ③ 清理核心产物（源文件、解压目录、缓存目录、library 目录）
    ImportService.purgeItem(filesDir, record.sourcePath, 'source', cleaned, failed);
    ImportService.purgeItem(filesDir, record.extractDir, 'extract', cleaned, failed);
    ImportService.purgeItem(filesDir, record.cacheDir, 'cache', cleaned, failed);
    ImportService.purgeItem(filesDir, record.libraryDir, 'library', cleaned, failed);
    // 阅读进度（键为 record.title；非空 identifier 场景可能不完全命中，已知限制见 plan D3）
    const rsDir: string = (opts !== undefined && opts.readingStateDir !== undefined && opts.readingStateDir.length > 0)
      ? opts.readingStateDir : (filesDir + '/reading_state');
    try {
      ReadingStateStore.remove(rsDir, title);
      cleaned.push('readingState');
    } catch (e) {
      failed.push('readingState');
      hilog.warn(0x0000, TAG, 'Delete: readingState-failed bookId=%{public}s err=%{public}s',
        bookId, ImportService.errText(e));
    }
    // ④ 调用已注册的关联数据清理钩子（批注 / 书签等）
    for (let i = 0; i < ImportService.cleaners.length; i++) {
      const cleaner: BookAssociatedDataCleaner = ImportService.cleaners[i];
      try {
        await cleaner.clean(filesDir, record);
        cleaned.push('associated');
      } catch (e) {
        failed.push('associated');
        hilog.warn(0x0000, TAG, 'Delete: cleaner-failed bookId=%{public}s err=%{public}s',
          bookId, ImportService.errText(e));
      }
    }
    const status: DeleteStatus = failed.length > 0 ? DeleteStatus.PARTIAL : DeleteStatus.DELETED;
    hilog.info(0x0000, TAG, 'Delete: %{public}s bookId=%{public}s title=%{public}s cleaned=%{public}d failed=%{public}d',
      status, bookId, title, cleaned.length, failed.length);
    return { status: status, bookId: bookId, title: title, cleanedItems: cleaned, failedItems: failed };
  }

  /** 清理单个产物路径（不存在视为已清理；删除后校验存在性以判定失败） */
  private static purgeItem(filesDir: string, path: string, label: string,
    cleaned: string[], failed: string[]): void {
    if (path.length === 0) {
      cleaned.push(label);
      return;
    }
    // 保护性：拒绝删除沙箱根及共享容器目录本身（避免误删台账/所有书）
    if (ImportService.isProtectedPath(filesDir, path)) {
      hilog.warn(0x0000, TAG, 'Delete: skip-protected label=%{public}s path=%{public}s', label, path);
      cleaned.push(label);
      return;
    }
    if (ImportService.safeStat(path) === null) {
      // 已被外部删除 → 安全视为已清理
      cleaned.push(label);
      return;
    }
    ImportService.removeDir(path);
    if (ImportService.exists(path)) {
      failed.push(label);
      hilog.warn(0x0000, TAG, 'Delete: purge-failed label=%{public}s path=%{public}s', label, path);
    } else {
      cleaned.push(label);
    }
  }

  /** 保护性判定：拒绝删除沙箱根与共享容器目录本身 */
  private static isProtectedPath(filesDir: string, path: string): boolean {
    if (path === filesDir) {
      return true;
    }
    return path === filesDir + '/books' || path === filesDir + '/cache' ||
      path === filesDir + '/cache/books' || path === filesDir + '/library';
  }

  // ==================== 台账有效性 ====================

  /** 台账记录是否仍然有效（源存在 + 指纹匹配 + 解析产物有效） */
  private static isRecordValid(rec: ImportedBook): boolean {
    const stat: fileIo.Stat | null = ImportService.safeStat(rec.sourcePath);
    if (stat === null) {
      return false;
    }
    const fp: string = String(stat.size) + ':' + String(stat.mtime);
    if (fp !== rec.fingerprint) {
      return false;
    }
    if (rec.format === '.epub') {
      return ParseCacheManager.isChunkedValid(rec.cacheDir, rec.sourcePath);
    }
    if (rec.format === '.txt') {
      return ImportService.exists(rec.libraryDir + '/' + TXT_INDEX_FILE);
    }
    if (rec.format === '.cbz' || rec.format === '.cbr') {
      return ImportService.exists(rec.extractDir);
    }
    return false;
  }

  // ==================== 源接入 ====================

  /**
   * 接入源文件到 books/ 目录（受控保留）。
   * - 已在 books/ 内：直接复用（幂等，不重复拷贝）
   * - 否则：同名同大小已保留 → 复用（避免歧义副本）；否则唯一化命名后拷贝
   *
   * @returns 保留后的源文件路径；失败返回空串
   */
  private static ingest(inputPath: string, booksDir: string, displayName: string): string {
    if (ImportService.isUnder(inputPath, booksDir)) {
      return inputPath;
    }
    const candidate: string = booksDir + '/' + displayName;
    const cStat: fileIo.Stat | null = ImportService.safeStat(candidate);
    const iStat: fileIo.Stat | null = ImportService.safeStat(inputPath);
    if (iStat === null) {
      return '';
    }
    if (cStat !== null && cStat.size === iStat.size) {
      return candidate;
    }
    const dest: string = ImportService.uniquePath(booksDir, displayName);
    if (!ImportService.copyFile(inputPath, dest)) {
      return '';
    }
    return dest;
  }

  // ==================== 命名 / 路径工具 ====================

  /** 推导展示名（displayName > 路径/URI basename > formatHint） */
  private static deriveDisplayName(request: ImportRequest, inputPath: string): string {
    if (request.displayName !== undefined && request.displayName.length > 0) {
      return request.displayName;
    }
    let name: string = '';
    if (request.sourcePath !== undefined && request.sourcePath.length > 0) {
      name = ImportService.baseName(request.sourcePath);
    } else if (request.sourceUri !== undefined && request.sourceUri.length > 0) {
      name = ImportService.decodeName(ImportService.baseName(request.sourceUri));
    }
    // 无扩展名时用 formatHint 补齐
    if (ImportService.extOf(name).length === 0 &&
      request.formatHint !== undefined && request.formatHint.length > 0) {
      const hint: string = request.formatHint.startsWith('.') ? request.formatHint : '.' + request.formatHint;
      name = name + hint;
    }
    if (name.length > 0) {
      return name;
    }
    return ImportService.baseName(inputPath);
  }

  /** 批量进度展示名（displayName > 路径/URI basename；仅展示，不产生副作用） */
  private static requestName(request: ImportRequest): string {
    if (request.displayName !== undefined && request.displayName.length > 0) {
      return request.displayName;
    }
    if (request.sourcePath !== undefined && request.sourcePath.length > 0) {
      return ImportService.baseName(request.sourcePath);
    }
    if (request.sourceUri !== undefined && request.sourceUri.length > 0) {
      return ImportService.decodeName(ImportService.baseName(request.sourceUri));
    }
    return '';
  }

  /** 取 basename */
  private static baseName(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  /** URI 文件名解码（中文按 ASCII 编码需还原） */
  private static decodeName(seg: string): string {
    try {
      return decodeURIComponent(seg);
    } catch (_e) {
      return seg;
    }
  }

  /** 小写扩展名（含点号）；无扩展名返回空串 */
  private static extOf(name: string): string {
    const slash: number = name.lastIndexOf('/');
    const file: string = slash >= 0 ? name.substring(slash + 1) : name;
    const dot: number = file.lastIndexOf('.');
    return dot >= 0 ? file.substring(dot).toLowerCase() : '';
  }

  /** 扩展名 → BookFormat（支持集合；PDF/未知返回 undefined） */
  private static formatOfExt(ext: string): BookFormat | undefined {
    if (ext === '.epub') {
      return BookFormat.EPUB;
    }
    if (ext === '.txt') {
      return BookFormat.TXT;
    }
    if (ext === '.cbz' || ext === '.cbr') {
      return BookFormat.CBZ;
    }
    return undefined;
  }

  /** 文件名（去扩展名）作为标题回退 */
  private static titleFromName(name: string): string {
    const dot: number = name.lastIndexOf('.');
    const base: string = dot > 0 ? name.substring(0, dot) : name;
    return base.length > 0 ? base : name;
  }

  /** 解析元数据标题（缺省回退） */
  private static bookTitle(parsed: ParsedBook, fallback: string): string {
    if (parsed.book !== null) {
      try {
        const t: string = parsed.book.getMetadata().title;
        if (t.length > 0) {
          return t;
        }
      } catch (_e) {
      }
    }
    return fallback;
  }

  /** 目标已存在时生成不冲突名（name_1.ext / name_2.ext ...） */
  private static uniquePath(dir: string, fileName: string): string {
    const dot: number = fileName.lastIndexOf('.');
    const base: string = dot > 0 ? fileName.substring(0, dot) : fileName;
    const ext: string = dot > 0 ? fileName.substring(dot) : '';
    let candidate: string = dir + '/' + fileName;
    let n: number = 1;
    while (ImportService.exists(candidate)) {
      candidate = dir + '/' + base + '_' + String(n) + ext;
      n++;
    }
    return candidate;
  }

  private static isUnder(path: string, dir: string): boolean {
    return path === dir || path.startsWith(dir + '/');
  }

  // ==================== 文件 IO ====================

  private static report(onProgress: ((stage: string) => void) | undefined, stage: string): void {
    if (onProgress !== undefined) {
      onProgress(stage);
    }
  }

  /** 批量进度回调（每本一次：进入该项 + 单本阶段名转发） */
  private static reportBatch(onProgress: ((p: BatchImportProgress) => void) | undefined,
    index: number, total: number, name: string, stage: string): void {
    if (onProgress !== undefined) {
      const p: BatchImportProgress = { index: index, total: total, name: name, stage: stage };
      onProgress(p);
    }
  }

  private static fail(bookId: string, error: string): ImportResult {
    hilog.info(0x0000, TAG, 'Import: fail err=%{public}s', error);
    return { status: ImportStatus.FAILED, bookId: bookId, error: error };
  }

  private static errText(e: Error | Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return String(e);
  }

  private static safeStat(path: string): fileIo.Stat | null {
    try {
      return fileIo.statSync(path);
    } catch (_e) {
      return null;
    }
  }

  private static exists(path: string): boolean {
    try {
      fileIo.statSync(path);
      return true;
    } catch (_e) {
      return false;
    }
  }

  private static mkdirp(dir: string): void {
    try {
      fileIo.statSync(dir);
    } catch (_e) {
      try {
        fileIo.mkdirSync(dir, true);
      } catch (_e2) {
      }
    }
  }

  /** 流式拷贝（分块读，避免大文件一次性载入内存）；逐字节保留 */
  private static copyFile(src: string, dest: string): boolean {
    let srcFile: fileIo.File | null = null;
    let dstFile: fileIo.File | null = null;
    try {
      srcFile = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
      try {
        fileIo.unlinkSync(dest);
      } catch (_e) {
      }
      dstFile = fileIo.openSync(dest,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      const buf: ArrayBuffer = new ArrayBuffer(256 * 1024);
      while (true) {
        const readLen: number = fileIo.readSync(srcFile.fd, buf);
        if (readLen <= 0) {
          break;
        }
        fileIo.writeSync(dstFile.fd, buf.slice(0, readLen));
        if (readLen < buf.byteLength) {
          break;
        }
      }
      fileIo.closeSync(dstFile);
      dstFile = null;
      fileIo.closeSync(srcFile);
      srcFile = null;
      return true;
    } catch (_e) {
      if (dstFile !== null) {
        try {
          fileIo.closeSync(dstFile);
        } catch (_e2) {
        }
      }
      if (srcFile !== null) {
        try {
          fileIo.closeSync(srcFile);
        } catch (_e3) {
        }
      }
      return false;
    }
  }

  /** 递归删除目录（失败静默，仅用于失败清理） */
  private static removeDir(dir: string): void {
    const stat: fileIo.Stat | null = ImportService.safeStat(dir);
    if (stat === null) {
      return;
    }
    let isDir: boolean = false;
    try {
      isDir = stat.isDirectory();
    } catch (_e) {
      return;
    }
    if (!isDir) {
      try {
        fileIo.unlinkSync(dir);
      } catch (_e) {
      }
      return;
    }
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(dir);
    } catch (_e) {
      return;
    }
    for (let i = 0; i < entries.length; i++) {
      const child: string = dir + '/' + entries[i];
      const cStat: fileIo.Stat | null = ImportService.safeStat(child);
      if (cStat === null) {
        continue;
      }
      let childIsDir: boolean = false;
      try {
        childIsDir = cStat.isDirectory();
      } catch (_e) {
        continue;
      }
      if (childIsDir) {
        ImportService.removeDir(child);
      } else {
        try {
          fileIo.unlinkSync(child);
        } catch (_e) {
        }
      }
    }
    try {
      fileIo.rmdirSync(dir);
    } catch (_e) {
    }
  }
}
