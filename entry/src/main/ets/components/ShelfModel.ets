/**
 * ShelfModel — 书架列表投影模型（极简书架）
 *
 * 将导入台账记录（`ImportedBook[]`）投影为书架展示项（`ShelfItem[]`），
 * 供 `MinimalBookshelf` 纯文字列表渲染与打开。纯函数、无副作用（可独立测试）。
 *
 * 设计依据（plan D4）：书架数据以导入台账为准，展示标题缺省回退
 * `basename(sourcePath)`；点按打开使用 `sourcePath`。
 */

import type { ImportedBook } from 'ohrengine-common';

/** 书架条目（UI 投影） */
export interface ShelfItem {
  /** 台账稳定标识（删除定位用） */
  bookId: string;
  /** 展示标题（缺省回退 basename(sourcePath)） */
  title: string;
  /** 源格式：'.epub' | '.txt' | '.cbz' | '.cbr' */
  format: string;
  /** 保留源文件路径（打开用） */
  sourcePath: string;
}

/** 取路径 basename（回退标题用） */
function baseName(path: string): string {
  const slash: number = path.lastIndexOf('/');
  return slash >= 0 ? path.substring(slash + 1) : path;
}

/**
 * records → ShelfItem[]（展示标题，缺省回退 `basename(sourcePath)`）。
 * 保持台账原始顺序，不重排。
 */
export function projectShelfItems(records: ImportedBook[]): ShelfItem[] {
  const items: ShelfItem[] = [];
  for (let i: number = 0; i < records.length; i++) {
    const rec: ImportedBook = records[i];
    const fallback: string = baseName(rec.sourcePath);
    const title: string = rec.title.length > 0 ? rec.title : fallback;
    items.push({
      bookId: rec.bookId,
      title: title,
      format: rec.format,
      sourcePath: rec.sourcePath
    });
  }
  return items;
}
