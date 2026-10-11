/**
 * ReadingHistoryTypes — 阅读历史纯数据类型与端口（ARCH-003）
 *
 * 将 feature 中阅读历史的纯数据结构与最小端口下沉到 common，
 * 使 ui-render 的 PageManager 排版核心依赖端口而非 feature 业务类，
 * 解除 ui-render → feature 的耦合。
 */

/** 阅读记录（单本） */
export interface ReadingRecord {
  bookId: string;
  bookTitle: string;
  author?: string;
  coverPath?: string;
  chapterIndex: number;
  charOffset: number;
  progress: number;          // 0.0 ~ 1.0
  lastReadAt: number;
  totalReadingTime: number;  // 累计阅读时长（秒）
  openCount: number;
  createdAt: number;
}

/** 记录位置所需参数 */
export interface RecordPosition {
  chapterIndex: number;
  charOffset: number;
  progress: number;
}

/** 更新元数据的可选字段 */
export interface MetaUpdate {
  bookTitle?: string;
  author?: string;
  coverPath?: string;
}

/**
 * 阅读历史存储端口——ui-render 排版核心仅依赖此最小接口，
 * 实现（feature 的 ReadingHistoryManager）由 Runtime 装配注入。
 */
export interface IReadingHistoryStore {
  recordPosition(bookId: string, pos: RecordPosition): void;
  updateMeta(bookId: string, meta: MetaUpdate): void;
  getRecord(bookId: string): ReadingRecord | undefined;
}
