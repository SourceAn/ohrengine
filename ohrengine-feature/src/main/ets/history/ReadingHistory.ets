import { ReadingRecord, RecordPosition, MetaUpdate } from 'ohrengine-common';
export type { ReadingRecord, RecordPosition, MetaUpdate } from 'ohrengine-common';

/**
 * 阅读历史管理器 — LRU 淘汰策略
 * 最多保留 50 本，最近阅读的排最前
 * ARCH-003: ReadingRecord/RecordPosition/MetaUpdate 纯类型已下沉到 common。
 */
export class ReadingHistoryManager {
  private static readonly MAX_HISTORY = 50;
  private history: ReadingRecord[] = [];

  /** 从 Preferences 加载 */
  load(records: ReadingRecord[]): void {
    this.history = records;
  }

  getAll(): ReadingRecord[] {
    return this.history;
  }

  /** 获取最近阅读列表（从新到旧） */
  getRecent(count: number = 20): ReadingRecord[] {
    return this.history.slice(0, count);
  }

  /** 记录阅读位置（翻页/关闭时调用） */
  recordPosition(bookId: string, position: RecordPosition): void {
    const idx: number = this.history.findIndex(r => r.bookId === bookId);
    if (idx >= 0) {
      const r: ReadingRecord = this.history[idx];
      r.chapterIndex = position.chapterIndex;
      r.charOffset = position.charOffset;
      r.progress = position.progress;
      r.lastReadAt = Date.now();
      r.openCount++;
      this.history.splice(idx, 1);
      this.history.unshift(r); // 移到最前
    } else {
      const record: ReadingRecord = {
        bookId: bookId,
        bookTitle: '',
        chapterIndex: position.chapterIndex,
        charOffset: position.charOffset,
        progress: position.progress,
        lastReadAt: Date.now(),
        totalReadingTime: 0,
        openCount: 1,
        createdAt: Date.now(),
      } as ReadingRecord;
      this.history.unshift(record);

    }
  }

  /** 获取某本书的记录（用于恢复位置） */
  getRecord(bookId: string): ReadingRecord | undefined {
    return this.history.find(r => r.bookId === bookId);
  }

  /** 删除记录 */
  remove(bookId: string): void {
    this.history = this.history.filter(r => r.bookId !== bookId);
  }

  /** 更新书籍元数据（书名/作者/封面） */
  updateMeta(bookId: string, meta: MetaUpdate): void {
    const r: ReadingRecord | undefined = this.history.find(x => x.bookId === bookId);
    if (r !== undefined) {
      if (meta.bookTitle !== undefined) {
        r.bookTitle = meta.bookTitle;
      }
      if (meta.author !== undefined) {
        r.author = meta.author;
      }
      if (meta.coverPath !== undefined) {
        r.coverPath = meta.coverPath;
      }
    }
  }
}
