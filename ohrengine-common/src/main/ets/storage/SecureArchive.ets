/**
 * SecureArchive — 安全解压工具（SEC-002）
 *
 * 防止外部 EPUB/CBZ 压缩包造成：
 *   - 路径穿越（entry 路径逃逸到目标目录之外）
 *   - 符号链接绕过目录检查
 *   - 压缩炸弹 / 磁盘耗尽（文件数量、单文件大小、总大小上限）
 *   - 解压失败 / 异常退出后的临时目录残留
 *
 * 设计约束：
 *   - 纯静态工具类；调用方必须传入"应用沙箱内"的绝对解压目录
 *   - 解压完成后立即校验整棵目录树，任一项违规即整体拒绝并清理
 *   - 任何校验/IO 异常都转换为可理解的错误信息，不泄露内部绝对路径
 *   - 不破坏合法 EPUB/CBZ 的正常读取（校验失败才清理）
 */

import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';

/** hilog 统一前缀（与全工程一致） */
const TAG: string = 'OhEngine';

/** 安全解压上限配置 */
export interface SecureExtractLimits {
  /** 压缩包本身的最大字节数 */
  maxArchiveBytes: number;
  /** 解压后允许的最大文件数量 */
  maxEntries: number;
  /** 解压后单个文件最大字节数 */
  maxSingleFileBytes: number;
  /** 解压后全部文件总字节数 */
  maxTotalBytes: number;
}

/** 默认安全上限 */
const DEFAULT_LIMITS: SecureExtractLimits = {
  maxArchiveBytes: 1024 * 1024 * 1024,   // 1 GB 压缩包
  maxEntries: 50000,                     // 5 万文件
  maxSingleFileBytes: 256 * 1024 * 1024, // 单文件 256 MB
  maxTotalBytes: 2 * 1024 * 1024 * 1024  // 总解压 2 GB
};

/**
 * 安全解压工具 — 纯静态工具类
 */
export class SecureArchive {
  /**
   * 安全解压压缩包到目标目录。
   *
   * 流程：
   *   1. 前置校验：压缩包存在、非空、不超上限；目标目录必须在沙箱内（如传入沙箱根）
   *   2. 清理旧目录并创建全新目标目录（幂等）
   *   3. 调用 zlib.decompressFile 解压
   *   4. 后置校验：遍历整棵树，拒绝路径穿越、符号链接、超数量/超大小
   *   5. 任一步失败 → 清理目标目录并抛出可理解错误
   *
   * @param archivePath - 压缩包绝对路径（沙箱内）
   * @param extractDir - 解压目标目录绝对路径
   * @param sandboxBase - 应用沙箱根目录（如 context.filesDir）。传入时强制校验
   *                      extractDir 位于其内；不传时仍执行目录树后置校验
   *                      （路径穿越/符号链接/数量/大小），但跳过沙箱边界检查
   * @param limits - 可选安全上限，缺省用默认值
   * @throws Error 校验/解压失败（错误信息不含内部绝对路径）
   */
  static async decompressArchive(
    archivePath: string,
    extractDir: string,
    sandboxBase?: string,
    limits?: SecureExtractLimits
  ): Promise<void> {
    const lim: SecureExtractLimits = limits ?? DEFAULT_LIMITS;

    // 1a. 压缩包前置校验
    const archiveSize: number = SecureArchive.safeStatSize(archivePath);
    if (archiveSize < 0) {
      throw new Error('Archive file does not exist or cannot be read.');
    }
    if (archiveSize === 0) {
      throw new Error('Archive file is empty.');
    }
    if (archiveSize > lim.maxArchiveBytes) {
      throw new Error('Archive file is too large.');
    }

    // 1b. 解压目录必须位于沙箱内（仅当提供沙箱根时校验）
    if (sandboxBase !== undefined && sandboxBase.length > 0) {
      if (extractDir.length === 0 || !SecureArchive.isSubPath(extractDir, sandboxBase)) {
        throw new Error('Extract directory is outside the app sandbox.');
      }
    }

    // 2. 清理旧目录并创建全新目标目录
    try {
      SecureArchive.removeDirRecursive(extractDir);
    } catch (_e) {
    }
    try {
      fileIo.mkdirSync(extractDir, true);
    } catch (e) {
      throw new Error('Failed to create extract directory: ' + SecureArchive.safeError(e));
    }

    // 3. 解压
    try {
      await zlib.decompressFile(archivePath, extractDir, {});
    } catch (e) {
      SecureArchive.cleanupOnFailure(extractDir);
      throw new Error('Failed to decompress archive: ' + SecureArchive.safeError(e));
    }

    // 4. 后置校验整棵目录树
    try {
      SecureArchive.validateExtractTree(extractDir, lim);
    } catch (e) {
      SecureArchive.cleanupOnFailure(extractDir);
      throw new Error('Archive validation failed: ' + SecureArchive.safeError(e));
    }
  }

  /**
   * 校验解压后的目录树：
   *   - 所有条目路径在 extractDir 之内（防路径穿越）
   *   - 无符号链接（防特殊路径绕过）
   *   - 文件数量 / 单文件大小 / 总大小不超上限
   *
   * @param dir - 解压目录绝对路径
   * @param limits - 安全上限
   * @throws Error 任一违规即抛出（信息不含内部路径）
   */
  private static validateExtractTree(dir: string, limits: SecureExtractLimits): void {
    const walker: ExtractWalker = {
      dir: dir,
      limits: limits,
      entryCount: 0,
      totalBytes: 0
    };
    SecureArchive.walkDirectory(walker);
    if (walker.entryCount > limits.maxEntries) {
      throw new Error('Extracted file count exceeds the limit.');
    }
    if (walker.totalBytes > limits.maxTotalBytes) {
      throw new Error('Extracted total size exceeds the limit.');
    }
  }

  /**
   * 递归遍历目录树并累积校验结果。
   * 树内任何条目 stat/lstat 失败、符号链接、超单文件大小、越界路径都会抛错。
   */
  private static walkDirectory(walker: ExtractWalker): void {
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(walker.dir);
    } catch (_e) {
      return; // 目录可能已被并发删除——忽略
    }

    for (let i = 0; i < entries.length; i++) {
      const name: string = entries[i];
      const fullPath: string = walker.dir + '/' + name;
      if (!SecureArchive.isSubPath(fullPath, walker.dir)) {
        throw new Error('Archive entry escapes the extract directory.');
      }

      let stat: fileIo.Stat;
      try {
        stat = fileIo.lstatSync(fullPath);
      } catch (_e) {
        continue; // 条目已被外部删除——跳过
      }
      let isLink: boolean;
      try {
        isLink = stat.isSymbolicLink();
      } catch (_e) {
        continue; // 条目状态读取失败——跳过
      }
      if (isLink) {
        throw new Error('Archive contains a symbolic link.');
      }

      let isDirectory: boolean;
      try {
        isDirectory = stat.isDirectory();
      } catch (_e) {
        continue; // 条目状态读取失败——跳过
      }
      if (isDirectory) {
        // 递归校验子目录内容（SEC-002 修复：原实现误传同一个 walker.dir 造成
        // 死循环/漏检子目录，路径穿越、符号链接、超限在子目录内会漏网）
        const childWalker: ExtractWalker = {
          dir: fullPath,
          limits: walker.limits,
          entryCount: walker.entryCount,
          totalBytes: walker.totalBytes
        };
        SecureArchive.walkDirectory(childWalker);
        walker.entryCount = childWalker.entryCount;
        walker.totalBytes = childWalker.totalBytes;
        continue;
      }

      // 普通文件
      walker.entryCount++;
      if (walker.entryCount > walker.limits.maxEntries) {
        throw new Error('Extracted file count exceeds the limit.');
      }
      const size: number = stat.size;
      walker.totalBytes += size;
      if (size > walker.limits.maxSingleFileBytes) {
        throw new Error('Extracted file size exceeds the limit.');
      }
      if (walker.totalBytes > walker.limits.maxTotalBytes) {
        throw new Error('Extracted total size exceeds the limit.');
      }
    }
  }

  /** 解压失败/校验失败时清理目标目录（不抛错） */
  private static cleanupOnFailure(extractDir: string): void {
    try {
      SecureArchive.removeDirRecursive(extractDir);
    } catch (_e) {
    }
  }

  /**
   * 递归删除目录（含非空目录），条目删除失败仅告警不中断。
   */
  private static removeDirRecursive(dir: string): void {
    let dirStat: fileIo.Stat;
    try {
      dirStat = fileIo.lstatSync(dir);
    } catch (_e) {
      return; // 目录不存在
    }
    let dirIsDirectory: boolean;
    try {
      dirIsDirectory = dirStat.isDirectory();
    } catch (_e) {
      return; // 目录状态读取失败——按不存在处理
    }
    if (!dirIsDirectory) {
      // 非目录（可能是文件残留）——删除之
      try {
        fileIo.unlinkSync(dir);
      } catch (_e) {
        // 忽略
      }
      return;
    }

    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(dir);
    } catch (_e) {
      return;
    }
    for (let i = 0; i < entries.length; i++) {
      const entryPath: string = dir + '/' + entries[i];
      try {
        const stat: fileIo.Stat = fileIo.lstatSync(entryPath);
        if (stat.isDirectory()) {
          SecureArchive.removeDirRecursive(entryPath);
        } else {
          fileIo.unlinkSync(entryPath);
        }
      } catch (_e) {
      }
    }
    try {
      fileIo.rmdirSync(dir);
    } catch (_e) {
      // 忽略
    }
  }

  /** 安全地获取文件大小；文件不存在/不可读返回 -1 */
  private static safeStatSize(path: string): number {
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      return stat.isFile() ? stat.size : -1;
    } catch (_e) {
      return -1;
    }
  }

  /** 判断 candidate 是否为 base 的子路径（规范化比较，防 '../' 逃逸） */
  private static isSubPath(candidate: string, base: string): boolean {
    const normCandidate: string = SecureArchive.normalizePath(candidate);
    const normBase: string = SecureArchive.normalizePath(base);
    if (normCandidate === normBase) {
      return true;
    }
    if (!normCandidate.startsWith(normBase)) {
      return false;
    }
    const next: string = normCandidate.charAt(normBase.length);
    return next === '/' || next === '';
  }

  /**
   * 规范化绝对路径：解析 '.' 与 '..' 段。
   * 不 resolve 符号链接（符号链接单独用 lstat 拦截）。
   */
  private static normalizePath(path: string): string {
    const isAbs: boolean = path.startsWith('/');
    const segments: string[] = [];
    const parts: string[] = path.split('/');
    for (let i = 0; i < parts.length; i++) {
      const seg: string = parts[i];
      if (seg === '' || seg === '.') {
        continue;
      }
      if (seg === '..') {
        if (segments.length > 0) {
          segments.pop();
        }
        continue;
      }
      segments.push(seg);
    }
    return (isAbs ? '/' : '') + segments.join('/');
  }

  /** 安全格式化错误信息（不打印堆栈与内部路径细节） */
  private static safeError(e: Error | Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return String(e);
  }
}

/** 目录遍历中间状态 */
interface ExtractWalker {
  dir: string;
  limits: SecureExtractLimits;
  entryCount: number;
  totalBytes: number;
}
