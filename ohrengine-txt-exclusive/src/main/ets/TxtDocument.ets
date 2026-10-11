/**
 * TxtDocument — TXT 惰性数据源（Phase 9.3 / 9.4 / 9.5）
 *
 * 职责：
 *   - 打开时：构建/加载 TxtIndexData（流式，无整文件 String）；
 *   - 阅读时：`getVChapterHtml(i)` 按 vch 字节范围随机读取 → 解码 →
 *     按与 eager 一致的（段落切分 + HTML 组装）重建 vch HTML；
 *   - `paragraphHash` / `charOffset` 语义与 eager 保持一致（9.5）；
 *   - 内存边界：TxtChunkReader 内部有界解码缓存 + pin/unpin（9.6）。
 *
 * 与引擎的对接：通过 common 的 TxtLazyDocument 接口；
 * OhEngineCore 在 TXT 分支探测 parser.openTxtLazyDocument。
 */

import { BookFormat } from 'ohrengine-common';
import { TxtLazyDocument, TxtIndexRef, TxtVChapterRef } from 'ohrengine-common';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { extractParagraphs } from 'ohrengine-common';
import { TxtIndexBuilder } from './TxtIndexBuilder.ets';
import { TxtIndexBuilderTask } from './TxtIndexBuilderTask.ets';
import { TxtIndexData } from './TxtIndexData.ets';
import type { TxtVChapterData } from './TxtIndexData.ets';
import { TxtChunkReader } from './TxtChunkReader.ets';
import { TxtParagraphSplitter } from './TxtParagraphSplitter.ets';

/**
 * 索引持久化文件名（放 cacheDir 下）。
 * Phase 24（Issue A 根因修复 #2）：v2 —— vchapter id 改为全局连续序号后，
 * 旧索引（章内序号 id，跨章撞号）必须失效重建；文件名升版使旧缓存自然废弃。
 */
const INDEX_FILE: string = 'txt-index-v2.json';
/** 原子写入中间文件（rename 前）；打开时若存在直接删除，绝不读取。 */
const INDEX_TMP_FILE: string = 'txt-index-v2.json.tmp';

export class TxtDocument implements TxtLazyDocument {
  /** 诊断：最近一次 open 的索引来源（'library'|'legacy'|'built'|'none'）。仅用于测试/日志。 */
  private static lastOpenSource: string = 'none';
  public readonly format: BookFormat = BookFormat.TXT;
  private filePath: string = '';
  private indexData: TxtIndexData | null = null;
  private reader: TxtChunkReader | null = null;
  private readonly cacheDir: string;

  private constructor(cacheDir: string) {
    this.cacheDir = cacheDir;
  }

  /**
   * 诊断：最近一次 open 的索引来源。
   * 取值：'library'（命中持久目录）| 'legacy'（命中旧 cacheDir 位置）| 'built'（重新构建）| 'none'。
   * 仅用于测试与诊断日志，不参与业务逻辑。
   */
  public static getLastOpenSource(): string {
    return TxtDocument.lastOpenSource;
  }

  /**
   * 打开 TXT lazy 文档：
   * 1) 优先读持久目录 libraryDir 下的索引（指纹 size+mtime 有效则直接复用）；
   * 2) 未命中再读旧位置 cacheDir（命中则原子迁移到 libraryDir，旧文件保持不动）；
   * 3) 仍未命中则流式构建并原子写入（有 libraryDir 只写 libraryDir，否则退回写 cacheDir）。
   *
   * @param libraryDir 可选。缺省/空字符串时行为退回现状（使用 cacheDir）。
   */
  public static async open(filePath: string, cacheDir: string, libraryDir?: string): Promise<TxtDocument | undefined> {
    const doc: TxtDocument = new TxtDocument(cacheDir);
    doc.filePath = filePath;
    const lib: string = libraryDir !== undefined ? libraryDir : '';
    // 写入目录：有 libraryDir 只写 library；否则退回现状写 cacheDir。
    const writeDir: string = lib.length > 0 ? lib : cacheDir;
    // 打开前清理遗留 .tmp（只删不读）
    TxtDocument.removeTmp(writeDir);

    // 1) 优先读持久目录 library
    if (lib.length > 0) {
      const inLib: TxtIndexData | null = TxtDocument.tryLoadDiskIndex(filePath, lib);
      if (inLib !== null) {
        doc.indexData = inLib;
        doc.reader = new TxtChunkReader(filePath, inLib.encoding);
        TxtDocument.lastOpenSource = 'library';
        hilog.info(0x0000, 'OhEngine', 'TXT-LAZY index-source=%{public}s libraryDirEmpty=%{public}d', TxtDocument.lastOpenSource, lib.length === 0 ? 1 : 0);
        return doc;
      }
    }
    // 2) 兼容旧位置 cacheDir（命中则迁移到 library，旧文件保持不动）
    if (cacheDir.length > 0) {
      const legacy: TxtIndexData | null = TxtDocument.tryLoadDiskIndex(filePath, cacheDir);
      if (legacy !== null) {
        doc.indexData = legacy;
        doc.reader = new TxtChunkReader(filePath, legacy.encoding);
        if (lib.length > 0) {
          TxtDocument.saveDiskIndex(filePath, lib, legacy);
        }
        TxtDocument.lastOpenSource = 'legacy';
        hilog.info(0x0000, 'OhEngine', 'TXT-LAZY index-source=%{public}s libraryDirEmpty=%{public}d', TxtDocument.lastOpenSource, lib.length === 0 ? 1 : 0);
        return doc;
      }
    }
    // 3) 流式构建（P0-A: 走 TaskPool，200MB 首建不冻结 UI；worker 异常自动回退主线程）
    const built: TxtIndexData | null = await TxtIndexBuilderTask.buildInTaskPool(filePath);
    if (built === null) {
      hilog.error(0x0000, 'OhEngine', 'TXT-LAZY index-build-failed path=%{public}s', filePath);
      TxtDocument.lastOpenSource = 'none';
      hilog.info(0x0000, 'OhEngine', 'TXT-LAZY index-source=%{public}s libraryDirEmpty=%{public}d', TxtDocument.lastOpenSource, lib.length === 0 ? 1 : 0);
      return undefined;
    }
    doc.indexData = built;
    doc.reader = new TxtChunkReader(filePath, built.encoding);
    TxtDocument.saveDiskIndex(filePath, writeDir, built);
    TxtDocument.lastOpenSource = 'built';
    hilog.info(0x0000, 'OhEngine', 'TXT-LAZY index-source=%{public}s libraryDirEmpty=%{public}d', TxtDocument.lastOpenSource, lib.length === 0 ? 1 : 0);
    return doc;
  }

  private static tryLoadDiskIndex(filePath: string, cacheDir: string): TxtIndexData | null {
    if (cacheDir.length === 0) {
      return null;
    }
    try {
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      const jsonPath: string = cacheDir + '/' + INDEX_FILE;
      const text: string = fileIo.readTextSync(jsonPath);
      const idx: TxtIndexData | null = TxtIndexData.fromJson(text);
      if (idx === null) {
        return null;
      }
      if (idx.fileSize !== stat.size || idx.mtime !== stat.mtime) {
        return null;
      }
      return idx;
    } catch (_e) {
      return null;
    }
  }

  /** 删除目录下遗留的 .tmp（只删不读）。 */
  private static removeTmp(dir: string): void {
    if (dir.length === 0) {
      return;
    }
    try { fileIo.unlinkSync(dir + '/' + INDEX_TMP_FILE); } catch (_e) { }
  }

  /**
   * 原子写入索引到 dir（libraryDir，或退回的 cacheDir）：
   * mkdir → 写 .tmp → fsync → renameSync 覆盖 → 读回校验（fileSize/mtime 与源文件 stat 一致）。
   * 失败仅 hilog.warn 并返回 false，不阻断阅读。
   */
  private static saveDiskIndex(filePath: string, dir: string, idx: TxtIndexData): boolean {
    if (dir.length === 0) {
      return false;
    }
    let stat: fileIo.Stat;
    try {
      stat = fileIo.statSync(filePath);
    } catch (_e) {
      hilog.warn(0x0000, 'OhEngine', 'TXT-LAZY save-index-failed stat path=%{public}s', filePath);
      return false;
    }
    idx.fileSize = stat.size;
    idx.mtime = stat.mtime;
    const json: string = idx.toJson();
    const target: string = dir + '/' + INDEX_FILE;
    const tmp: string = dir + '/' + INDEX_TMP_FILE;
    try {
      try { fileIo.mkdirSync(dir, true); } catch (_e) { }
      try { fileIo.unlinkSync(tmp); } catch (_e) { }
      const outFile: fileIo.File = fileIo.openSync(tmp,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(outFile.fd, json);
        try { fileIo.fsyncSync(outFile.fd); } catch (_e) { }
      } finally {
        try { fileIo.closeSync(outFile); } catch (_e) { }
      }
      fileIo.renameSync(tmp, target);
    } catch (e) {
      hilog.warn(0x0000, 'OhEngine', 'TXT-LAZY save-index-failed dir=%{public}s err=%{public}s', dir, String(e));
      try { fileIo.unlinkSync(tmp); } catch (_e) { }
      return false;
    }
    // 读回校验：必须可解析，且 fileSize/mtime 与刚才的源文件 stat 一致
    try {
      const back: TxtIndexData | null = TxtIndexData.fromJson(fileIo.readTextSync(target));
      if (back === null) {
        hilog.warn(0x0000, 'OhEngine', 'TXT-LAZY save-index-verify-null dir=%{public}s', dir);
        return false;
      }
      if (back.fileSize !== stat.size || back.mtime !== stat.mtime) {
        hilog.warn(0x0000, 'OhEngine', 'TXT-LAZY save-index-verify-mismatch dir=%{public}s', dir);
        return false;
      }
    } catch (e) {
      hilog.warn(0x0000, 'OhEngine', 'TXT-LAZY save-index-verify-failed dir=%{public}s err=%{public}s', dir, String(e));
      return false;
    }
    return true;
  }

  // ==================== TxtLazyDocument ====================

  get index(): TxtIndexRef {
    return TxtDocument.toIndexRef(this.indexData);
  }

  getVChapterCount(): number {
    return this.indexData === null ? 0 : this.indexData.vchapters.length;
  }

  getVChapterTitle(index: number): string {
    if (this.indexData === null || index < 0 || index >= this.indexData.vchapters.length) {
      return '';
    }
    return this.indexData.vchapters[index].title;
  }

  getVChapterRange(index: number): TxtVChapterRef | undefined {
    if (this.indexData === null || index < 0 || index >= this.indexData.vchapters.length) {
      return undefined;
    }
    const v: TxtVChapterData = this.indexData.vchapters[index];
    return {
      id: v.id,
      oldChapterIndex: v.oldChapterIndex,
      title: v.title,
      byteStart: v.byteStart,
      byteEnd: v.byteEnd,
      charStart: v.charStart,
      charEnd: v.charEnd,
      paraStart: v.paraStart,
      paraEnd: v.paraEnd,
      plainTextLength: v.plainTextLength
    };
  }

  getVChapterHtml(index: number): string | undefined {
    if (this.indexData === null || this.reader === null ||
      index < 0 || index >= this.indexData.vchapters.length) {
      return undefined;
    }
    const v: TxtVChapterData = this.indexData.vchapters[index];
    const raw: string | undefined =
      this.reader.readRange(v.byteStart, v.byteEnd);
    if (raw === undefined) {
      return undefined;
    }
    return TxtDocument.rebuildVchHtml(raw);
  }

  getPlainTextLength(index: number): number {
    if (this.indexData === null || index < 0 || index >= this.indexData.vchapters.length) {
      return 0;
    }
    return this.indexData.vchapters[index].plainTextLength;
  }

  getOldChapterToVchapterStart(): number[] {
    if (this.indexData === null) {
      return [];
    }
    const out: number[] = [];
    for (let i = 0; i < this.indexData.oldChapters.length; i++) {
      out.push(this.indexData.oldChapters[i].vchStart);
    }
    return out;
  }

  getOldChapterVchapterCounts(): number[] {
    if (this.indexData === null) {
      return [];
    }
    const out: number[] = [];
    for (let i = 0; i < this.indexData.oldChapters.length; i++) {
      out.push(this.indexData.oldChapters[i].vchCount);
    }
    return out;
  }

  resolveChapter(chapterId: string): number {
    if (this.indexData === null) {
      return -1;
    }
    if (chapterId.startsWith('vchapter_')) {
      const n: number = parseInt(chapterId.substring(9), 10);
      return n >= 0 && n < this.indexData.vchapters.length ? n : -1;
    }
    // 旧 chapter-N / page-N → 映射到该旧章首个 vch
    const prefix: string = chapterId.startsWith('chapter-') ? 'chapter-' : 'page-';
    const num: number = parseInt(chapterId.substring(prefix.length), 10);
    if (!isNaN(num) && num >= 1) {
      const oldIdx: number = num - 1;
      if (oldIdx < this.indexData.oldChapters.length) {
        return this.indexData.oldChapters[oldIdx].vchStart;
      }
    }
    return -1;
  }

  release(): void {
    if (this.reader !== null) {
      this.reader.close();
      this.reader = null;
    }
  }

  trimCache(center: number, keepRadius: number): void {
    if (this.indexData === null || this.reader === null) {
      return;
    }
    this.reader.purgeUnreferenced();
  }

  stats(): string {
    if (this.indexData === null || this.reader === null) {
      return 'txt-lazy:no-index';
    }
    return 'vchs=' + this.indexData.vchapters.length +
      ' oldChapters=' + this.indexData.oldChapters.length +
      ' encoding=' + this.indexData.encoding +
      ' cache=' + this.reader.cacheEntries();
  }

  // ==================== 内部辅助 ====================

  private static toIndexRef(idx: TxtIndexData | null): TxtIndexRef {
    if (idx === null) {
      return {
        version: 0, fileSize: 0, encoding: 'utf-8', newlineMode: '',
        contentFingerprint: '', chunkSize: 0, chunkCount: 0,
        oldChapterCount: 0, vchapterCount: 0, totalPlainTextLength: 0
      };
    }
    return {
      version: idx.version,
      fileSize: idx.fileSize,
      encoding: idx.encoding,
      newlineMode: idx.newlineMode,
      contentFingerprint: String(idx.fileSize) + ':' + String(idx.mtime),
      chunkSize: idx.chunkSize,
      chunkCount: idx.chunks.length,
      oldChapterCount: idx.oldChapters.length,
      vchapterCount: idx.vchapters.length,
      totalPlainTextLength: idx.totalPlainTextLength
    };
  }

  /**
   * 从 vch 字节范围解码得到的原始文本，重建与 eager 完全一致的 vch HTML。
   *
   * eager 推导链（TxtParser + expandTxtToVChapters）：
   *   split(body) → toHtml（escape + <p> 包裹 + '\n' 连接）
   *   → extractParagraphs（去标签/反转义/折叠空白/trim/去空行）
   *   → texts = '<p>'+para+'</p>' → buildVChapters 用 '' 连接 texts[paraStart..paraEnd]
   *
   * 本方法按同一链条处理 vch 的字节范围文本，结果逐字符一致。
   */
  public static rebuildVchHtml(rawText: string): string {
    const normalized: string = rawText
      .replace(new RegExp('\\r\\n', 'g'), '\n')
      .replace(new RegExp('\\r', 'g'), '\n');
    const rawParas: string[] = TxtParagraphSplitter.split(normalized);
    const contentHtml: string = TxtParagraphSplitter.toHtml(rawParas);
    const collapsed: string[] = extractParagraphs(contentHtml);
    let out: string = '';
    for (let i = 0; i < collapsed.length; i++) {
      out += '<p>' + collapsed[i] + '</p>';
    }
    return out;
  }
}