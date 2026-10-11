/**
 * ImportedBookStore — 导入台账（Phase: 图书统一导入）
 *
 * 以单个 JSON 文件 `filesDir/library/import-index.json` 记录每本已导入图书的
 * `ImportedBook`，用于：
 *   - 热启动判定（台账命中 + 指纹有效 → 跳过解压/解析）
 *   - 可逆导出定位（经 bookId 定位保留的原始源文件）
 *   - 去重与幂等（同源不产生歧义记录）
 *
 * 设计约束：
 *   - 纯静态工具类（无状态），全部方法同步实现（fileIo 同步 API）
 *   - 原子写（tmp + rename）；任何异常自行吞掉，绝不向调用方抛错
 *   - 损坏/缺失静默回退为空台账，不阻断流程
 *   - upsert 保证「一个保留源文件 = 一条记录」：同 bookId 或同 sourcePath 覆盖
 */

import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ImportedBook, ImportIndexFile, IMPORT_INDEX_VERSION } from './ImportTypes.ets';

/** hilog 统一前缀（与全工程一致） */
const TAG: string = 'OhEngine';

export class ImportedBookStore {
  private static readonly DIR: string = 'library';
  private static readonly FILE: string = 'import-index.json';
  private static readonly TMP: string = 'import-index.json.tmp';

  /** 台账文件绝对路径 */
  private static indexPath(filesDir: string): string {
    return filesDir + '/' + ImportedBookStore.DIR + '/' + ImportedBookStore.FILE;
  }

  /** 读取全部台账记录（缺失/损坏 → []，不抛错） */
  static load(filesDir: string): ImportedBook[] {
    if (filesDir.length === 0) {
      return [];
    }
    let text: string = '';
    try {
      text = fileIo.readTextSync(ImportedBookStore.indexPath(filesDir));
    } catch (_e) {
      return [];
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const booksVal: Object | undefined = raw['books'];
      if (booksVal === undefined || !Array.isArray(booksVal)) {
        return [];
      }
      const rawBooks: Object[] = booksVal as Object[];
      const out: ImportedBook[] = [];
      for (let i = 0; i < rawBooks.length; i++) {
        const rec: ImportedBook | null = ImportedBookStore.decode(rawBooks[i]);
        if (rec !== null) {
          out.push(rec);
        }
      }
      return out;
    } catch (_e) {
      return [];
    }
  }

  /** 反序列化单条记录（结构不完整返回 null） */
  private static decode(item: Object): ImportedBook | null {
    try {
      const r: Record<string, Object> = item as Record<string, Object>;
      const bookId: Object | undefined = r['bookId'];
      const format: Object | undefined = r['format'];
      const title: Object | undefined = r['title'];
      const sourcePath: Object | undefined = r['sourcePath'];
      const extractDir: Object | undefined = r['extractDir'];
      const cacheDir: Object | undefined = r['cacheDir'];
      const libraryDir: Object | undefined = r['libraryDir'];
      const fingerprint: Object | undefined = r['fingerprint'];
      const importedAt: Object | undefined = r['importedAt'];
      if (typeof bookId !== 'string' || typeof format !== 'string' || typeof title !== 'string' ||
        typeof sourcePath !== 'string' || typeof extractDir !== 'string' ||
        typeof cacheDir !== 'string' || typeof libraryDir !== 'string' ||
        typeof fingerprint !== 'string' || typeof importedAt !== 'number') {
        return null;
      }
      const rec: ImportedBook = {
        bookId: bookId,
        format: format,
        title: title,
        sourcePath: sourcePath,
        extractDir: extractDir,
        cacheDir: cacheDir,
        libraryDir: libraryDir,
        fingerprint: fingerprint,
        importedAt: importedAt
      };
      return rec;
    } catch (_e) {
      return null;
    }
  }

  /**
   * 写入/更新一条记录（原子写）。
   * 同 bookId（同一本书重建）或同 sourcePath（同一保留源文件）的旧记录会被覆盖，
   * 保证一个保留源文件只有一条台账记录。
   */
  static upsert(filesDir: string, record: ImportedBook): void {
    const books: ImportedBook[] = ImportedBookStore.load(filesDir);
    const kept: ImportedBook[] = [];
    for (let i = 0; i < books.length; i++) {
      const b: ImportedBook = books[i];
      if (b.bookId === record.bookId || b.sourcePath === record.sourcePath) {
        continue;
      }
      kept.push(b);
    }
    kept.push(record);
    ImportedBookStore.write(filesDir, kept);
  }

  /** 按 bookId 查询 */
  static findById(filesDir: string, bookId: string): ImportedBook | undefined {
    const books: ImportedBook[] = ImportedBookStore.load(filesDir);
    for (let i = 0; i < books.length; i++) {
      if (books[i].bookId === bookId) {
        return books[i];
      }
    }
    return undefined;
  }

  /** 按保留源文件路径查询 */
  static findBySource(filesDir: string, sourcePath: string): ImportedBook | undefined {
    const books: ImportedBook[] = ImportedBookStore.load(filesDir);
    for (let i = 0; i < books.length; i++) {
      if (books[i].sourcePath === sourcePath) {
        return books[i];
      }
    }
    return undefined;
  }

  /** 删除一条记录（原子写） */
  static remove(filesDir: string, bookId: string): void {
    const books: ImportedBook[] = ImportedBookStore.load(filesDir);
    const kept: ImportedBook[] = [];
    for (let i = 0; i < books.length; i++) {
      if (books[i].bookId !== bookId) {
        kept.push(books[i]);
      }
    }
    ImportedBookStore.write(filesDir, kept);
  }

  /** 原子写入台账（tmp + rename；失败静默） */
  private static write(filesDir: string, books: ImportedBook[]): void {
    const dir: string = filesDir + '/' + ImportedBookStore.DIR;
    try {
      fileIo.statSync(dir);
    } catch (_e) {
      try {
        fileIo.mkdirSync(dir, true);
      } catch (_e2) {
        return;
      }
    }
    const payload: ImportIndexFile = {
      version: IMPORT_INDEX_VERSION,
      books: books,
      updatedAt: Date.now()
    };
    const target: string = ImportedBookStore.indexPath(filesDir);
    const tmp: string = dir + '/' + ImportedBookStore.TMP;
    try {
      try {
        fileIo.unlinkSync(tmp);
      } catch (_e) {
      }
      const file: fileIo.File = fileIo.openSync(tmp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(payload));
      fileIo.closeSync(file);
      fileIo.renameSync(tmp, target);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'Import: ledger-write-failed err=%{public}s', String(e));
      try {
        fileIo.unlinkSync(tmp);
      } catch (_e2) {
      }
    }
  }
}
