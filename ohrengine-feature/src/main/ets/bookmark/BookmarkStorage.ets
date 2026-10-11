/**
 * BookmarkStorage — 基于 HarmonyOS Preferences 的书签持久化存储
 *
 * 所有书签按 bookId 分组，存储为 JSON 字符串。
 *
 * 使用方式：
 *   const storage = new BookmarkStorage();
 *   await storage.init(context);
 *   await storage.save('book-001', myBookmark);
 *   const all = await storage.getAll('book-001');
 */
import { preferences } from '@kit.ArkData';
import { Bookmark } from './Bookmark.ets';

export class BookmarkStorage {
  private store: preferences.Preferences | undefined = undefined;

  /**
   * 初始化 Preferences 实例
   */
  async init(context: Context): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, 'bookmarks_preferences');
    } catch (_e) {
      this.store = undefined;
    }
  }

  /**
   * 保存一个书签（新增或覆盖已有 id）
   */
  async save(bookId: string, bookmark: Bookmark): Promise<void> {
    const all: Bookmark[] = await this.getAll(bookId);
    const idx: number = this.indexOf(all, bookmark.id);
    if (idx >= 0) {
      all[idx] = bookmark;
    } else {
      all.push(bookmark);
    }
    await this.persist(bookId, all);
  }

  /**
   * 删除指定书签
   */
  async remove(bookId: string, bookmarkId: string): Promise<void> {
    const all: Bookmark[] = await this.getAll(bookId);
    const filtered: Bookmark[] = [];
    for (let i: number = 0; i < all.length; i++) {
      if (all[i].id !== bookmarkId) {
        filtered.push(all[i]);
      }
    }
    await this.persist(bookId, filtered);
  }

  /**
   * 删除某本书的全部书签（硬删除该书的 preferences 键）
   *
   * 供彻底删除（ImportService.deleteBook）经关联数据清理钩子调用。
   */
  async removeAll(bookId: string): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    const key: string = this.getKey(bookId);
    try {
      await this.store.delete(key);
      await this.store.flush();
    } catch (_e) {
      // 删除失败——忽略（由调用方按需感知）
    }
  }

  /**
   * 获取某本书的全部书签
   */
  async getAll(bookId: string): Promise<Bookmark[]> {
    if (this.store === undefined) {
      return [];
    }
    const key: string = this.getKey(bookId);
    let raw: preferences.ValueType = '[]';
    try {
      raw = await this.store.get(key, '[]');
    } catch (_e) {
      return [];
    }
    const json: string = raw as string;
    if (json === undefined || json === '') {
      return [];
    }
    try {
      return JSON.parse(json) as Bookmark[];
    } catch (_e) {
      return [];
    }
  }

  /**
   * 持久化写入（内部方法）
   */
  private async persist(bookId: string, bookmarks: Bookmark[]): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    const key: string = this.getKey(bookId);
    try {
      await this.store.put(key, JSON.stringify(bookmarks));
      await this.store.flush();
    } catch (_e) {
      // 持久化失败——忽略（等待下次保存重试）
    }
  }

  /**
   * 返回 bookmarks 中的 id 索引，未找到返回 -1
   */
  private indexOf(bookmarks: Bookmark[], id: string): number {
    for (let i: number = 0; i < bookmarks.length; i++) {
      if (bookmarks[i].id === id) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 生成 preferences 的 key：bookmarks_{bookId}
   */
  private getKey(bookId: string): string {
    return 'bookmarks_' + bookId;
  }
}
