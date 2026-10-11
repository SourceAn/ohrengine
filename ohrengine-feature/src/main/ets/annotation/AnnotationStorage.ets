/**
 * AnnotationStorage — 基于 HarmonyOS relationalStore (SQLite) 的标注持久化存储
 *
 * 增量保存：单条 INSERT OR REPLACE，不重写全文件。
 *
 * AnnotationPageResolver — 根据页面字符偏移范围过滤标注
 *   将标注的 locator.paragraphIndex（起始偏移）和 locator.wordIndex（结束偏移）
 *   与页面的 charRange 进行匹配，返回落在当前页的标注列表。
 */
import { relationalStore } from '@kit.ArkData';
import { Annotation, AnnotationType, Locator, createEmptyLocator } from 'ohrengine-common';

// ────────────────────────────────────────────────────────────────────────────
// AnnotationStorage
// ────────────────────────────────────────────────────────────────────────────
export class AnnotationStorage {
  private store: relationalStore.RdbStore | undefined = undefined;

  async init(context: Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: 'annotations.db',
      securityLevel: relationalStore.SecurityLevel.S1
    };
    try {
      this.store = await relationalStore.getRdbStore(context, config);
      await this.store.executeSql(
        `CREATE TABLE IF NOT EXISTS annotations (
          id TEXT PRIMARY KEY,
          bookId TEXT,
          type INTEGER,
          color TEXT,
          chapterIndex INTEGER,
          startOffset INTEGER,
          endOffset INTEGER,
          noteText TEXT,
          noteTimestamp INTEGER,
          text TEXT,
          createdAt INTEGER,
          updatedAt INTEGER,
          synchronizationVersion INTEGER DEFAULT 0,
          isVisible INTEGER DEFAULT 1
        )`
      );
    } catch (_e) {
      this.store = undefined;
    }
  }

  // ── Annotation ↔ SQLite row helpers ──

  private rowToAnnotation(row: relationalStore.ValuesBucket): Annotation {
    const r: Record<string, relationalStore.ValueType> = row;
    const chapterIdx: number = r['chapterIndex'] as number;
    const startOff: number = r['startOffset'] as number;
    const endOff: number = r['endOffset'] as number;
    const createdAtMs: number = r['createdAt'] as number;
    const updatedAtMs: number = r['updatedAt'] as number;
    const createdStr: string = new Date(createdAtMs).toISOString();
    const updatedStr: string = new Date(updatedAtMs).toISOString();
    const loc: Locator = createEmptyLocator();
    loc.chapterIndex = chapterIdx;
    loc.paragraphIndex = startOff;
    loc.wordIndex = endOff;
    return {
      id: r['id'] as string,
      type: AnnotationStorage.intToType(r['type'] as number),
      locator: loc,
      text: r['text'] as string,
      note: r['noteText'] as string,
      color: r['color'] as string,
      created: createdStr,
      modified: updatedStr,
      chapterIndex: chapterIdx,
      startCharOffset: startOff,
      endCharOffset: endOff,
      synchronizationVersion: r['synchronizationVersion'] as number,
      noteText: r['noteText'] as string,
      noteTimestamp: r['noteTimestamp'] as number,
      createdAt: createdAtMs,
      updatedAt: updatedAtMs,
      isVisible: r['isVisible'] as number
    };
  }

  private static typeToInt(t: string): number {
    if (t === 'bookmark') {
      return 0;
    } else if (t === 'highlight') {
      return 1;
    } else if (t === 'underline') {
      return 2;
    } else if (t === 'note') {
      return 3;
    }
    return 1; // default: highlight
  }

  private static intToType(v: number): AnnotationType {
    if (v === 0) {
      return AnnotationType.BOOKMARK;
    } else if (v === 1) {
      return AnnotationType.HIGHLIGHT;
    } else if (v === 2) {
      return AnnotationType.UNDERLINE;
    } else if (v === 3) {
      return AnnotationType.NOTE;
    }
    return AnnotationType.HIGHLIGHT;
  }

  /** 全量加载某本书的标注 */
  async getAll(bookId: string): Promise<Annotation[]> {
    if (this.store === undefined) {
      return [];
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates('annotations');
    predicates.equalTo('bookId', bookId);
    predicates.equalTo('isVisible', 1);
    let resultSet: relationalStore.ResultSet;
    try {
      resultSet = await this.store.query(predicates, [
        'id', 'type', 'color', 'chapterIndex', 'startOffset', 'endOffset',
        'noteText', 'noteTimestamp', 'text', 'createdAt', 'updatedAt',
        'synchronizationVersion', 'isVisible'
      ]);
    } catch (_e) {
      return [];
    }
    const annotations: Annotation[] = [];
    try {
      while (resultSet.goToNextRow()) {
        const row: relationalStore.ValuesBucket = resultSet.getRow();
        annotations.push(this.rowToAnnotation(row));
      }
    } catch (_e) {
      // 读取中断——返回已读取的部分
    }
    try {
      resultSet.close();
    } catch (_e) {
      // 忽略关闭失败
    }
    return annotations;
  }

  /** 增量保存单条（INSERT OR REPLACE，不重写全文件） */
  async save(bookId: string, ann: Annotation): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    const nowMs: number = new Date().getTime();
    const chapterIdx: number = ann.chapterIndex ?? ann.locator?.chapterIndex ?? 0;
    const startOff: number = ann.startCharOffset ?? ann.locator?.paragraphIndex ?? 0;
    const endOff: number = ann.endCharOffset ?? ann.locator?.wordIndex ?? 0;
    const noteText: string = ann.noteText ?? ann.note ?? '';
    const createdAt: number = ann.createdAt ?? nowMs;
    const updatedAt: number = ann.updatedAt ?? nowMs;
    const noteTs: number = ann.noteTimestamp ?? createdAt;
    const syncVer: number = ann.synchronizationVersion ?? 0;
    const colorVal: string = ann.color ?? '';
    const textVal: string = ann.text ?? '';
    try {
      await this.store.executeSql(
        `INSERT OR REPLACE INTO annotations
          (id, bookId, type, color, chapterIndex, startOffset, endOffset,
           noteText, noteTimestamp, text, createdAt, updatedAt,
           synchronizationVersion, isVisible)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)`,
        [
          ann.id,
          bookId,
          AnnotationStorage.typeToInt(ann.type),
          colorVal,
          chapterIdx,
          startOff,
          endOff,
          noteText,
          noteTs,
          textVal,
          createdAt,
          updatedAt,
          syncVer
        ]
      );
    } catch (_e) {
      // 单条保存失败——忽略
    }
  }

  /** 批量保存（一次性插入全部） */
  async saveAll(bookId: string, anns: Annotation[]): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    if (anns.length === 0) {
      return;
    }
    try {
      await this.store.beginTransaction();
    } catch (_e) {
      return;
    }
    try {
      for (let i: number = 0; i < anns.length; i++) {
        const ann: Annotation = anns[i];
        const nowMs: number = new Date().getTime();
        const chapterIdx: number = ann.chapterIndex ?? ann.locator?.chapterIndex ?? 0;
        const startOff: number = ann.startCharOffset ?? ann.locator?.paragraphIndex ?? 0;
        const endOff: number = ann.endCharOffset ?? ann.locator?.wordIndex ?? 0;
        const noteText: string = ann.noteText ?? ann.note ?? '';
        const createdAt: number = ann.createdAt ?? nowMs;
        const updatedAt: number = ann.updatedAt ?? nowMs;
        const noteTs: number = ann.noteTimestamp ?? createdAt;
        const syncVer: number = ann.synchronizationVersion ?? 0;
        const colorVal: string = ann.color ?? '';
        const textVal: string = ann.text ?? '';
        await this.store.executeSql(
          `INSERT OR REPLACE INTO annotations
            (id, bookId, type, color, chapterIndex, startOffset, endOffset,
             noteText, noteTimestamp, text, createdAt, updatedAt,
             synchronizationVersion, isVisible)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)`,
          [
            ann.id,
            bookId,
            AnnotationStorage.typeToInt(ann.type),
            colorVal,
            chapterIdx,
            startOff,
            endOff,
            noteText,
            noteTs,
            textVal,
            createdAt,
            updatedAt,
            syncVer
          ]
        );
      }
      await this.store.commit();
    } catch (e) {
      try {
        await this.store.rollBack();
      } catch (_e) {
        // 回滚失败——忽略
      }
    }
  }

  /** 增量删除（软删除 isVisible = 0） */
  async remove(bookId: string, annId: string): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates('annotations');
    predicates.equalTo('id', annId);
    predicates.equalTo('bookId', bookId);
    try {
      await this.store.delete(predicates);
    } catch (_e) {
      // 删除失败——忽略
    }
  }

  /** 硬删除（指定 bookId 的全部标注） */
  async removeAll(bookId: string): Promise<void> {
    if (this.store === undefined) {
      return;
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates('annotations');
    predicates.equalTo('bookId', bookId);
    try {
      await this.store.delete(predicates);
    } catch (_e) {
      // 删除失败——忽略
    }
  }
}

// ────────────────────────────────────────────────────────────────────────────
// AnnotationPageResolver
// ────────────────────────────────────────────────────────────────────────────
export class AnnotationPageResolver {
  /**
   * 筛选落在指定页面字符区间的标注列表
   *
   * @param pageStart - 页面对应的全局字符起始偏移
   * @param pageEnd - 页面对应的全局字符结束偏移
   * @param annotations - 全书标注列表
   * @returns 落在该页的标注数组
   */
  public static getAnnotationsForPage(
    pageStart: number,
    pageEnd: number,
    annotations: Annotation[]
  ): Annotation[] {
    const result: Annotation[] = [];
    for (let i: number = 0; i < annotations.length; i++) {
      const ann: Annotation = annotations[i];
      const annStart: number = ann.startCharOffset ?? ann.locator.paragraphIndex ?? 0;
      const annEnd: number = ann.endCharOffset ?? ann.locator.wordIndex ?? annStart;
      // 检查区间是否重叠
      if (annStart < pageEnd && annEnd > pageStart) {
        result.push(ann);
      }
    }
    return result;
  }

  /**
   * 返回标注在本章内的字符偏移
   */
  public static getAnnotationLocalOffsets(
    annotation: Annotation
  ): AnnotationLocalOffsets {
    const startOff: number = annotation.startCharOffset ?? annotation.locator.paragraphIndex ?? 0;
    const endOff: number = annotation.endCharOffset ?? annotation.locator.wordIndex ?? startOff;
    return new AnnotationLocalOffsets(startOff, endOff);
  }
}

export class AnnotationLocalOffsets {
  readonly startCharOffset: number;
  readonly endCharOffset: number;
  constructor(start: number, end: number) {
    this.startCharOffset = start;
    this.endCharOffset = end;
  }
}
