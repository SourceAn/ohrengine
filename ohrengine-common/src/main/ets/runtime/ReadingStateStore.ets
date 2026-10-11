/**
 * ReadingStateStore — 阅读状态持久化（Phase 1，L1 critical state）
 *
 * 载体：`<readingStateDir>/reading_state_<safeBookId>.json` 单个 JSON 文件。
 * 写入使用「临时文件 + renameSync」实现原子替换：任何时刻磁盘上要么是旧版
 * 完整文件、要么是完整新版，不会出现半写缓存（crash 安全）。
 *
 * 设计约束（与 ParseCacheManager/PageCacheManager 一致）：
 *   - 纯静态工具类（无状态）
 *   - 任何异常自行吞掉并返回安全默认值（null），绝不向上抛错
 *   - 该状态属于 L1 critical state，独立于 L2 分页缓存（layoutSignature 变化
 *     时不应丢失），因此目录独立于 page cache dir，由 ReaderHost 传入。
 */

import { fileIo } from '@kit.CoreFileKit';
import type { ReadingState } from '../types/ReadingStateTypes.ets';

/** 文件名前缀 */
const FILE_PREFIX: string = 'reading_state_';
/** 文件扩展名 */
const FILE_EXT: string = '.json';
/** 临时文件后缀（原子替换用） */
const TMP_SUFFIX: string = '.tmp';

/** bookId → 安全文件名（非字母数字转 '_'，避免路径穿越） */
function safeBookSegment(bookId: string): string {
  let out: string = '';
  for (let i: number = 0; i < bookId.length; i++) {
    const ch: string = bookId.charAt(i);
    const code: number = bookId.charCodeAt(i);
    if ((code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
      out += ch;
    } else {
      out += '_';
    }
  }
  return out;
}

export class ReadingStateStore {
  /**
   * 保存阅读状态（原子替换）。
   * @param readingStateDir 阅读状态目录（ReaderHost 传入，如 filesDir/reading_state）
   * @param bookId 稳定书 ID
   * @param state 阅读状态
   */
  static save(readingStateDir: string, bookId: string, state: ReadingState): void {
    if (readingStateDir.length === 0 || bookId.length === 0) {
      return;
    }
    // 先确保父目录存在（单级 mkdir；父缺失时逐级建），避免级联创建失败。
    const lastSlash: number = readingStateDir.lastIndexOf('/');
    if (lastSlash > 0) {
      const parent: string = readingStateDir.substring(0, lastSlash);
      try {
        fileIo.statSync(parent);
      } catch (_e) {
        try {
          fileIo.mkdirSync(parent, true);
        } catch (_e2) {
        }
      }
    }
    try {
      fileIo.statSync(readingStateDir);
    } catch (_e) {
      try {
        fileIo.mkdirSync(readingStateDir, true);
      } catch (_e2) {
        return;
      }
    }
    const finalPath: string = FILE_PREFIX + safeBookSegment(bookId) + FILE_EXT;
    const target: string = readingStateDir + '/' + finalPath;
    const tmp: string = target + TMP_SUFFIX;
    let json: string = '';
    try {
      json = JSON.stringify(state);
    } catch (_e) {
      return;
    }
    try {
      // 先删除遗留临时文件（OpenMode.CREATE 在文件已存在时会抛错）
      try {
        fileIo.unlinkSync(tmp);
      } catch (_e) {
      }
      const file: fileIo.File = fileIo.openSync(tmp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, json);
      fileIo.closeSync(file);
      // 原子替换：临时文件完整就绪后再 rename 到位
      fileIo.renameSync(tmp, target);
    } catch (_e) {
      try {
        fileIo.unlinkSync(tmp);
      } catch (_e2) {
      }
    }
  }

  /**
   * 加载阅读状态。
   * @param readingStateDir 阅读状态目录
   * @param bookId 稳定书 ID
   * @returns ReadingState | null（不存在/损坏返回 null，不抛错）
   */
  static load(readingStateDir: string, bookId: string): ReadingState | null {
    if (readingStateDir.length === 0 || bookId.length === 0) {
      return null;
    }
    const target: string = readingStateDir + '/' + FILE_PREFIX + safeBookSegment(bookId) + FILE_EXT;
    let text: string = '';
    try {
      text = fileIo.readTextSync(target);
    } catch (_e) {
      return null;
    }
    try {
      const raw: object = JSON.parse(text) as object;
      const rec: Record<string, Object> = raw as Record<string, Object>;
      const schema = rec['schemaVersion'];
      const bookIdVal = rec['bookId'];
      const state: ReadingState = {
        schemaVersion: typeof schema === 'number' ? schema : 0,
        bookId: typeof bookIdVal === 'string' ? bookIdVal : '',
        chapterId: ReadingStateStore.str(rec['chapterId']),
        anchor: {
          chapterId: ReadingStateStore.str((rec['anchor'] as Record<string, Object>)['chapterId']),
          paragraphIndex: ReadingStateStore.num((rec['anchor'] as Record<string, Object>)['paragraphIndex']),
          paragraphHash: ReadingStateStore.str((rec['anchor'] as Record<string, Object>)['paragraphHash']),
          charOffset: ReadingStateStore.num((rec['anchor'] as Record<string, Object>)['charOffset'])
        },
        visualPageIndex: ReadingStateStore.num(rec['visualPageIndex']),
        layoutSignature: ReadingStateStore.str(rec['layoutSignature']),
        lastReadTime: ReadingStateStore.num(rec['lastReadTime']),
        contentFingerprint: ReadingStateStore.str(rec['contentFingerprint'])
      };
      if (state.chapterId.length === 0 || state.anchor.chapterId.length === 0 ||
        state.anchor.paragraphHash.length === 0) {
        return null;
      }
      return state;
    } catch (_e) {
      return null;
    }
  }

  /**
   * 删除某本书的阅读状态。
   * @param readingStateDir 阅读状态目录
   * @param bookId 稳定书 ID
   */
  static remove(readingStateDir: string, bookId: string): void {
    if (readingStateDir.length === 0 || bookId.length === 0) {
      return;
    }
    try {
      fileIo.unlinkSync(readingStateDir + '/' + FILE_PREFIX + safeBookSegment(bookId) + FILE_EXT);
    } catch (_e) {
    }
  }

  private static str(v: Object | undefined): string {
    return typeof v === 'string' ? v : '';
  }

  private static num(v: Object | undefined): number {
    return typeof v === 'number' ? v : 0;
  }
}