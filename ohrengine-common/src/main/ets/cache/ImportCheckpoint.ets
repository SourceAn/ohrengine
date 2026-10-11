/**
 * ImportCheckpoint — 导入阶段级检查点（Phase 7）
 *
 * 仅支持 stage-level：UNZIP_DONE / PARSE_DONE / INDEX_DONE / CACHE_DONE。
 * 禁止 parser-internal checkpoint。若 PARSE_DONE 未可靠提交（文件缺失/损坏），
 * 调用方重新执行整个 PARSE stage。
 *
 * 载体：`<bookDir>/checkpoint.json`（原子替换：tmp + rename）。
 * 非 correctness source——stage 真实性最终以实际缓存文件（.parsed.json、
 * chapter_{i}.json）为准；checkpoint 仅用于跳过可重建阶段的启动记账。
 */
import { fileIo } from '@kit.CoreFileKit';

/** 导入阶段枚举 */
export enum ImportStage {
  UNZIP_DONE = 'UNZIP_DONE',
  PARSE_DONE = 'PARSE_DONE',
  INDEX_DONE = 'INDEX_DONE',
  CACHE_DONE = 'CACHE_DONE'
}

interface CheckpointFile {
  stages: string[];
  updatedAt: number;
}

export class ImportCheckpoint {
  private static readonly FILE: string = 'checkpoint.json';

  /** 标记某阶段完成（原子写） */
  static markStage(bookDir: string, stage: ImportStage): void {
    if (bookDir.length === 0) {
      return;
    }
    // HarmonyOS mkdirSync(path, true) 在目录已存在时抛 "File exists"——
    // 先 stat 确认存在性再创建，避免误 return 导致 checkpoint 永不写入（Phase 8 D3）。
    try {
      fileIo.statSync(bookDir);
    } catch (_e) {
      try {
        fileIo.mkdirSync(bookDir, true);
      } catch (_e2) {
        return;
      }
    }
    const current: string[] = ImportCheckpoint.loadStages(bookDir);
    if (current.indexOf(String(stage)) < 0) {
      current.push(String(stage));
    }
    const data: CheckpointFile = {
      stages: current,
      updatedAt: Date.now()
    };
    const target: string = bookDir + '/' + ImportCheckpoint.FILE;
    const tmp: string = target + '.tmp';
    try {
      try {
        fileIo.unlinkSync(tmp);
      } catch (_e) {
      }
      const file: fileIo.File = fileIo.openSync(tmp,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(data));
      fileIo.closeSync(file);
      fileIo.renameSync(tmp, target);
    } catch (_e) {
    }
  }

  /** 查询某阶段是否已提交 */
  static isStageDone(bookDir: string, stage: ImportStage): boolean {
    return ImportCheckpoint.loadStages(bookDir).indexOf(String(stage)) >= 0;
  }

  /** 读取全部已提交阶段（损坏/缺失 → []，不抛错） */
  static loadStages(bookDir: string): string[] {
    if (bookDir.length === 0) {
      return [];
    }
    let text: string = '';
    try {
      text = fileIo.readTextSync(bookDir + '/' + ImportCheckpoint.FILE);
    } catch (_e) {
      return [];
    }
    try {
      const raw: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const stagesVal: Object | undefined = raw['stages'];
      if (stagesVal === undefined || !Array.isArray(stagesVal)) {
        return [];
      }
      return stagesVal as string[];
    } catch (_e) {
      return [];
    }
  }
}