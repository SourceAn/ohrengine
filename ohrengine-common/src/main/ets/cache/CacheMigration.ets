/**
 * CacheMigration — 缓存迁移决策（Phase 7）
 *
 * 职责：在 open 时检查 old cache version / schemaVersion / fingerprint /
 * layoutAlgorithmVersion，决定迁移策略：
 *   - L0（ParseCache）：版本字面无独立字段；由 ParseCacheManager 的
 *     fingerprint/结构损坏校验驱动，尽量迁移（结构未变直接复用）。
 *   - L1（ReadingState）：schemaVersion 不匹配 → 无效化；否则保留 anchor。
 *   - L2（PageCache）：PageCacheManager.isCacheValid 已校验六元组；结构变化大时
 *     由 writeMeta 以新版本重写。本模块提供显式迁移入口（clear 受影响缓存）。
 *
 * 失败策略：删除受影响缓存 → 重建；禁止无限 retry（单次 remove，下次 open 自然重建）。
 * 不阻塞 global startup：迁移成本=一次目录删除或一次文件删除，同步可接受。
 */
import { fileIo } from '@kit.CoreFileKit';

export class CacheMigration {
  /**
   * 校验并清除旧结构 L2 分页缓存（meta version 落后于 current 时整目录删除）。
   * @param cacheDir L2 缓存目录
   * @param currentVersion 当前 PAGE_CACHE_VERSION
   * @returns 是否执行了删除
   */
  static clearStalePageCache(cacheDir: string, currentVersion: number): boolean {
    if (cacheDir.length === 0) {
      return false;
    }
    let text: string = '';
    try {
      text = fileIo.readTextSync(cacheDir + '/meta.json');
    } catch (_e) {
      return false;
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const version: Object | undefined = raw['version'];
      if (typeof version === 'number' && version < currentVersion) {
        CacheMigration.removeDir(cacheDir);
        return true;
      }
    } catch (_e) {
      return false;
    }
    return false;
  }

  /**
   * 校验 L2 meta 的 schemaVersion / layoutAlgorithmVersion 是否与当前一致；
   * 不一致时删除整目录返回 true（下次 open write-through 重建）。
   */
  static clearIncompatibleSchema(cacheDir: string, schemaVersion: number,
    algorithmVersion: number): boolean {
    if (cacheDir.length === 0) {
      return false;
    }
    let text: string = '';
    try {
      text = fileIo.readTextSync(cacheDir + '/meta.json');
    } catch (_e) {
      return false;
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const schema: Object | undefined = raw['schemaVersion'];
      const algo: Object | undefined = raw['layoutAlgorithmVersion'];
      if ((typeof schema === 'number' && schema !== schemaVersion) ||
        (typeof algo === 'number' && algo !== algorithmVersion)) {
        CacheMigration.removeDir(cacheDir);
        return true;
      }
    } catch (_e) {
      return false;
    }
    return false;
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
        CacheMigration.removeDir(child);
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
}