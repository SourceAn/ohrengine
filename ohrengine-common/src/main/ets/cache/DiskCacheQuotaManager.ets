/**
 * DiskCacheQuotaManager — 磁盘缓存配额（Phase 6）
 *
 * 职责：管理 L0/L1/L2 磁盘缓存的全局 + per-book 配额，LRU 淘汰最久未访问的
 * 书籍缓存目录。额度基于 library scale（当前默认全局 512MB、单书 128MB 上限，
 * 可通过构造参数覆盖）。仅作用于「可重建缓存」（L2/L1 副本），不删源书。
 *
 * 约束：
 *   - 不读取文件内容，只 stat 大小/atime
 *   - 任何目录缺失/无权限静默跳过，不抛错
 *   - LRU 键 = 上次访问时间戳（atime 不可靠时用 mtime；调用方应定期 touch）
 */
import { fileIo } from '@kit.CoreFileKit';

/** per-book 配额（超过即整书缓存可淘汰） */
const DEFAULT_MANAGED_DIRS: string[] = ['cache/books', 'reading_state'];

export class DiskCacheQuotaManager {
  private readonly managedRoots: string[];
  private readonly maxGlobalBytes: number;
  private readonly maxPerBookBytes: number;

  constructor(maxGlobalBytes: number = 512 * 1024 * 1024,
    maxPerBookBytes: number = 128 * 1024 * 1024,
    managedRoots?: string[]) {
    this.maxGlobalBytes = maxGlobalBytes;
    this.maxPerBookBytes = maxPerBookBytes;
    this.managedRoots = managedRoots !== undefined ? managedRoots : DEFAULT_MANAGED_DIRS;
  }

  /**
   * 在 baseDir 下遍历托管根目录（如 cache/books、reading_state）计算
   * 全部书籍缓存目录的大小，超全局配额时按 LRU（最近访问时间最小者）淘汰。
   * @param baseDir filesDir（如 ctx.filesDir）
   */
  enforceGlobalQuota(baseDir: string): void {
    for (let i = 0; i < this.managedRoots.length; i++) {
      const root: string = baseDir + '/' + this.managedRoots[i];
      let names: string[] = [];
      try {
        names = fileIo.listFileSync(root);
      } catch (_e) {
        continue;
      }
      // 收集 (dirPath, size, accessTime)；排序后从旧到新淘汰
      const dirSizes: number[] = [];
      const dirTimes: number[] = [];
      const dirPaths: string[] = [];
      let total: number = 0;
      for (let n = 0; n < names.length; n++) {
        const dirPath: string = root + '/' + names[n];
        const size: number = DiskCacheQuotaManager.dirSize(dirPath);
        let access: number = 0;
        try {
          const stat: fileIo.Stat = fileIo.statSync(dirPath);
          access = Number(stat.atime) > 0 ? Number(stat.atime) : Number(stat.mtime);
        } catch (_e) {
          access = 0;
        }
        dirSizes.push(size);
        dirTimes.push(access);
        dirPaths.push(dirPath);
        total += size;
      }
      // 简单 LRU：按 access 升序逐个淘汰直到回到全局预算
      if (total <= this.maxGlobalBytes) {
        continue;
      }
      const order: number[] = DiskCacheQuotaManager.sortIndexes(dirTimes, dirSizes);
      for (let k = 0; k < order.length; k++) {
        if (total <= this.maxGlobalBytes) {
          break;
        }
        const idx: number = order[k];
        if (dirSizes[idx] > 0) {
          DiskCacheQuotaManager.removeDir(dirPaths[idx]);
          total -= dirSizes[idx];
          dirSizes[idx] = 0;
        }
      }
    }
  }

  /**
   * 单书配额：某书缓存目录超过 per-book 上限则整书缓存淘汰。
   * @param bookCacheDir 该书的缓存目录（如 filesDir/cache/books/<bookName>）
   * @returns 是否淘汰
   */
  enforceBookQuota(bookCacheDir: string): boolean {
    const size: number = DiskCacheQuotaManager.dirSize(bookCacheDir);
    if (size > this.maxPerBookBytes) {
      DiskCacheQuotaManager.removeDir(bookCacheDir);
      return true;
    }
    return false;
  }

  /** 记录某目录访问（touch：本实现依赖 atime，此处仅作统计扩展点） */
  touch(): void {
  }

  /** 目录大小（递归累加；缺失返回 0） */
  static dirSize(path: string): number {
    let total: number = 0;
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(path);
    } catch (_e) {
      return 0;
    }
    for (let i = 0; i < names.length; i++) {
      const child: string = path + '/' + names[i];
      let stat: fileIo.Stat;
      try {
        stat = fileIo.statSync(child);
      } catch (_e) {
        continue;
      }
      let isDir: boolean = false;
      try {
        isDir = stat.isDirectory();
      } catch (_e) {
        isDir = false;
      }
      if (isDir) {
        total += DiskCacheQuotaManager.dirSize(child);
      } else {
        total += stat.size;
      }
    }
    return total;
  }

  /** 递归删除目录（静默失败） */
  private static removeDir(path: string): void {
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(path);
    } catch (_e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const child: string = path + '/' + names[i];
      let stat: fileIo.Stat;
      try {
        stat = fileIo.statSync(child);
      } catch (_e) {
        continue;
      }
      let isDir: boolean = false;
      try {
        isDir = stat.isDirectory();
      } catch (_e) {
        isDir = false;
      }
      if (isDir) {
        DiskCacheQuotaManager.removeDir(child);
      } else {
        try {
          fileIo.unlinkSync(child);
        } catch (_e) {
        }
      }
    }
    try {
      fileIo.rmdirSync(path);
    } catch (_e) {
    }
  }

  /** 按 (access,size) 升序返回索引（最旧/最小者优先淘汰） */
  private static sortIndexes(times: number[], sizes: number[]): number[] {
    const idx: number[] = [];
    for (let i = 0; i < times.length; i++) {
      idx.push(i);
    }
    for (let i = 0; i < idx.length; i++) {
      for (let j = i + 1; j < idx.length; j++) {
        const a: number = idx[i];
        const b: number = idx[j];
        const ta: number = times[a] + sizes[a] / 1024 / 1024;
        const tb: number = times[b] + sizes[b] / 1024 / 1024;
        if (tb < ta) {
          idx[i] = b;
          idx[j] = a;
        }
      }
    }
    return idx;
  }
}