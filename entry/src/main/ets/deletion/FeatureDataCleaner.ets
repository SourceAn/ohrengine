/**
 * FeatureDataCleaner — 应用层关联数据清理器（跨模块）
 *
 * 共享层（ohrengine-common）不可反向依赖功能模块（ohrengine-feature），因此批注
 * （SQLite `annotations.db`）与书签（Preferences `bookmarks_preferences`）的清理
 * 由本应用层实现，并经 `ImportService.registerAssociatedDataCleaner` 注入；
 * `ImportService.deleteBook` 在移除台账并清理核心产物后统一调用，满足 FR-006
 * （唯一删除入口，禁止各调用方分散清理）。
 *
 * 键位说明（plan D3）：批注 / 书签在引擎侧以「书标题」为键
 * （`pub.getMetadata().title`），与导入台账 `record.title` 一致（导入时由解析
 * 元数据标题写入）。因此以 `record.title` 作为关联键清理（缺省回退 sourcePath）。
 */

import { AnnotationStorage, BookmarkStorage } from 'ohrengine-feature';
import type { BookAssociatedDataCleaner, ImportedBook } from 'ohrengine-common';

export class FeatureDataCleaner implements BookAssociatedDataCleaner {
  private context: Context;
  private annStorage: AnnotationStorage | undefined = undefined;
  private bmStorage: BookmarkStorage | undefined = undefined;

  constructor(context: Context) {
    this.context = context;
  }

  /** 清理该书全部批注（SQLite）与书签（Preferences）；惰性 init，复用模块存储实现 */
  async clean(filesDir: string, record: ImportedBook): Promise<void> {
    const key: string = record.title.length > 0 ? record.title : record.sourcePath;
    const ann: AnnotationStorage = await this.ensureAnnotationStorage();
    await ann.removeAll(key);
    const bm: BookmarkStorage = await this.ensureBookmarkStorage();
    await bm.removeAll(key);
  }

  private async ensureAnnotationStorage(): Promise<AnnotationStorage> {
    if (this.annStorage === undefined) {
      const s: AnnotationStorage = new AnnotationStorage();
      await s.init(this.context);
      this.annStorage = s;
    }
    return this.annStorage;
  }

  private async ensureBookmarkStorage(): Promise<BookmarkStorage> {
    if (this.bmStorage === undefined) {
      const s: BookmarkStorage = new BookmarkStorage();
      await s.init(this.context);
      this.bmStorage = s;
    }
    return this.bmStorage;
  }
}
