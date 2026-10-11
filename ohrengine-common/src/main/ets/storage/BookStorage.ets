/**
 * BookStorage — 书目相关路径推导（集中化，纯函数）
 *
 * 目录约定（均相对 ctx.filesDir）：
 *   - `cache/books/<bookName>/` ：**可丢弃、可重建**的派生缓存
 *     （L0/L2 分页缓存、旧版 TXT 索引等）。
 *   - `library/<bookName>/`     ：**导入成果**（TXT 索引的正式存放位置）。
 *
 * 不变量（IMPORTANT）：
 *   `library/` 下的内容永远不得纳入任何配额淘汰（DiskCacheQuotaManager）、
 *   版本迁移（CacheMigration）或任何“清缓存 / 清空”逻辑；它只随
 *   “导入 / 删除书籍”变化。`cache/` 下的内容始终允许被整体删除并按需重建。
 *
 * bookName 推导必须与 ReaderHost.openAndLoad 既有规则完全一致：
 *   `basename( sourcePath.length > 0 ? sourcePath : bookBasePath )`
 */
export class BookStorage {
  /**
   * 推导 bookName：取 `sourcePath`（非空时）或 `bookBasePath` 的 basename。
   */
  static deriveBookName(sourcePath: string, bookBasePath: string): string {
    const basis: string = sourcePath.length > 0 ? sourcePath : bookBasePath;
    const slash: number = basis.lastIndexOf('/');
    return slash >= 0 ? basis.substring(slash + 1) : basis;
  }

  /** 可丢弃缓存目录：`filesDir/cache/books/<bookName>` */
  static pageCacheDirOf(filesDir: string, bookName: string): string {
    return filesDir + '/cache/books/' + bookName;
  }

  /** 持久目录（导入成果）：`filesDir/library/<bookName>` */
  static libraryDirOf(filesDir: string, bookName: string): string {
    return filesDir + '/library/' + bookName;
  }
}
