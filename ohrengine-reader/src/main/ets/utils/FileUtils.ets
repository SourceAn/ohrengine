/**
 * FileUtils — 通用文件工具
 *
 * 提供沙箱目录递归清理等工具函数。
 * 说明：SDK 23 无 rmSync，rmdirSync 仅能删除空目录，
 * 因此通过 listFileSync + statSync + unlinkSync/rmdirSync 手动递归删除。
 */

import { fileIo } from '@kit.CoreFileKit';

/**
 * 递归删除目录（含非空目录）。
 * - 目录不存在时静默返回
 * - 单个条目删除失败仅静默跳过，不中断整体清理
 *
 * @param dir 应用沙箱内目录绝对路径
 */
export function removeDirRecursive(dir: string): void {
  let dirStat: fileIo.Stat;
  try {
    dirStat = fileIo.statSync(dir);
  } catch (_e) {
    return; // 目录不存在，无需清理
  }
  try {
    if (!dirStat.isDirectory()) {
      return;
    }
  } catch (_e) {
    return;
  }

  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(dir);
  } catch (_e) {
    return;
  }
  for (const entry of entries) {
    let entryStat: fileIo.Stat;
    try {
      entryStat = fileIo.statSync(entry);
    } catch (_e) {
      continue; // 条目已被外部删除，跳过
    }
    try {
      if (entryStat.isDirectory()) {
        removeDirRecursive(entry);
      } else {
        try {
          fileIo.unlinkSync(entry);
        } catch (e) {
        }
      }
    } catch (e) {
    }
  }

  try {
    fileIo.rmdirSync(dir);
  } catch (e) {
  }
}
