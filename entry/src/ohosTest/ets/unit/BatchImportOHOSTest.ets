/**
 * BatchImportOHOSTest — 书架批量导入（多选一次导入多本）验收测试
 *
 * 覆盖：
 *   US1 多选批量导入：一次传入 N≥2（EPUB/TXT），台账含全部、批次逐本串行。
 *   US2 进度与汇总：`BatchImportProgress` 按本触发；`BatchImportResult` 汇总计数正确。
 *   US3 跳过失败继续：混合批次（不支持 + 有效）→ 有效项全部导入、不支持/失败计入汇总、批次继续。
 *   US4 幂等去重：批次含已导入项 / 同一文件重复选中 → `alreadyImported` 正确、无冲突副本。
 *
 * 使用独立的临时根目录（作为 filesDir 传入批量入口），测试前后清理。
 */

import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { ImportService, ImportedBookStore, ImportStatus, ParserRegistry } from 'ohrengine-common';
import type {
  ImportedBook, ImportResult, ImportRequest, BatchImportResult, BatchImportProgress
} from 'ohrengine-common';
import { EpubParser } from 'ohrengine-epub';
import { TxtParser } from 'ohrengine-txt-exclusive';
import { CbzParser } from 'ohrengine-cbz-exclusive';
import { PdfParser } from 'ohrengine-pdf-exclusive';

const DOMAIN: number = 0x0000;
const TAG: string = 'BatchImportTest';
const ROOT_PREFIX: string = 'batch_import_test_';

function log(msg: string): void {
  hilog.info(DOMAIN, TAG, '%{public}s', msg);
}

function appFilesDir(): string {
  const appCtx: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
  return appCtx.filesDir;
}

function rootOf(name: string): string {
  return appFilesDir() + '/' + ROOT_PREFIX + name;
}

function exists(p: string): boolean {
  try { fileIo.statSync(p); return true; } catch (_e) { return false; }
}

function rmrf(dir: string): void {
  let names: string[] = [];
  try { names = fileIo.listFileSync(dir); } catch (_e) { return; }
  for (let i: number = 0; i < names.length; i++) {
    const p: string = dir + '/' + names[i];
    let isDir: boolean = false;
    try { isDir = fileIo.statSync(p).isDirectory(); } catch (_e) { continue; }
    if (isDir) { rmrf(p); } else { try { fileIo.unlinkSync(p); } catch (_e) { } }
  }
  try { fileIo.rmdirSync(dir); } catch (_e) { }
}

function mkdirp(dir: string): void {
  try { fileIo.mkdirSync(dir, true); } catch (_e) { }
}

function writeText(p: string, s: string): void {
  try { fileIo.unlinkSync(p); } catch (_e) { }
  const f: fileIo.File = fileIo.openSync(p,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(f.fd, s);
  fileIo.closeSync(f);
}

function writeBytes(p: string, bytes: Uint8Array): void {
  try { fileIo.unlinkSync(p); } catch (_e) { }
  const f: fileIo.File = fileIo.openSync(p,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(f.fd, bytes.buffer as ArrayBuffer);
  fileIo.closeSync(f);
}

/** 从 entry 模块 rawfile 释放真实 EPUB 夹具 */
function releaseEpub(destPath: string): number {
  const appCtx: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
  const entryCtx: common.Context = appCtx.createModuleContext('entry');
  const data: Uint8Array = entryCtx.resourceManager.getRawFileContentSync('test.epub');
  writeBytes(destPath, data);
  return data.length;
}

function txtCorpus(chapters: number): string {
  let s: string = '';
  for (let c: number = 1; c <= chapters; c++) {
    s += '第' + String(c) + '章 测试章节\n\n';
    for (let p: number = 0; p < 60; p++) {
      s += '这是用于批量导入索引构建的测试段落文字，编号 ' + String(c) + '-' + String(p) +
        '，补充足够长度以便形成可用的章节与段落结构。\n\n';
    }
  }
  return s;
}

/** 按路径列表构造单本请求列表（批量请求即其数组） */
function reqsFrom(paths: string[]): ImportRequest[] {
  const out: ImportRequest[] = [];
  for (let i: number = 0; i < paths.length; i++) {
    const r: ImportRequest = { sourcePath: paths[i] };
    out.push(r);
  }
  return out;
}

/** 台账是否含指定 bookId */
function ledgerHas(ledger: ImportedBook[], bookId: string): boolean {
  for (let i: number = 0; i < ledger.length; i++) {
    if (ledger[i].bookId === bookId) {
      return true;
    }
  }
  return false;
}

export default function batchImportTest() {
  // 解析器注册（测试进程不保证 UIAbility.onCreate 已执行，故显式注册）
  ParserRegistry.register(new EpubParser());
  ParserRegistry.register(new TxtParser());
  ParserRegistry.register(new CbzParser());
  ParserRegistry.register(new PdfParser());

  describe('BatchImportTest', () => {

    it('US1_batch_import_multiple_books_into_ledger', 0, async () => {
      const root: string = rootOf('us1');
      rmrf(root);
      mkdirp(root + '/src');
      const ep1: string = root + '/src/a.epub';
      const ep2: string = root + '/src/b.epub';
      const tx: string = root + '/src/sample.txt';
      releaseEpub(ep1);
      releaseEpub(ep2);
      writeText(tx, txtCorpus(2));
      const res: BatchImportResult = await ImportService.importBooks(root, reqsFrom([ep1, ep2, tx]));
      log('US1 total=' + res.total + ' success=' + res.succeeded + ' failed=' + res.failed);
      expect(res.total).assertEqual(3);
      expect(res.succeeded).assertEqual(3);
      expect(res.failed).assertEqual(0);
      expect(res.results.length).assertEqual(3);
      const ledger: ImportedBook[] = ImportedBookStore.load(root);
      expect(ledger.length).assertEqual(3);
      // 逐本结果均有台账记录，且台账含全部
      for (let i: number = 0; i < res.results.length; i++) {
        const r: ImportResult = res.results[i];
        expect(r.status).assertEqual(ImportStatus.SUCCESS);
        expect(ledgerHas(ledger, r.bookId)).assertTrue();
      }
      rmrf(root);
    });

    it('US2_progress_and_summary_counts', 0, async () => {
      const root: string = rootOf('us2');
      rmrf(root);
      mkdirp(root + '/src');
      const ep: string = root + '/src/ok.epub';
      const tx: string = root + '/src/ok.txt';
      const pdf: string = root + '/src/no.pdf';
      const missing: string = root + '/src/missing.txt';
      releaseEpub(ep);
      writeText(tx, txtCorpus(1));
      writeText(pdf, '%PDF-1.4 dummy');
      // missing.txt 不创建 → FAILED
      const seenIndexes: number[] = [];
      let lastTotal: number = -1;
      const res: BatchImportResult = await ImportService.importBooks(root,
        reqsFrom([ep, tx, pdf, missing]),
        (p: BatchImportProgress): void => {
          seenIndexes.push(p.index);
          lastTotal = p.total;
        });
      log('US2 success=' + res.succeeded + ' unsupported=' + res.unsupported +
        ' failed=' + res.failed + ' already=' + res.alreadyImported);
      expect(res.total).assertEqual(4);
      expect(res.succeeded).assertEqual(2);
      expect(res.unsupported).assertEqual(1);
      expect(res.failed).assertEqual(1);
      expect(res.alreadyImported).assertEqual(0);
      // 进度回调按本触发（含 index 0/1/2/3 与 total=4）
      expect(seenIndexes.length > 0).assertTrue();
      expect(lastTotal).assertEqual(4);
      rmrf(root);
    });

    it('US3_skip_unsupported_and_continue', 0, async () => {
      const root: string = rootOf('us3');
      rmrf(root);
      mkdirp(root + '/src');
      const pdf: string = root + '/src/bad.pdf';
      const ep1: string = root + '/src/x.epub';
      const ep2: string = root + '/src/y.epub';
      writeText(pdf, '%PDF-1.4 dummy');
      releaseEpub(ep1);
      releaseEpub(ep2);
      // 不支持项放在首位：验证不中止整批（后续 EPUB 仍被导入）
      const res: BatchImportResult = await ImportService.importBooks(root, reqsFrom([pdf, ep1, ep2]));
      log('US3 total=' + res.total + ' success=' + res.succeeded + ' unsupported=' + res.unsupported);
      expect(res.total).assertEqual(3);
      expect(res.results.length).assertEqual(3);
      expect(res.results[0].status).assertEqual(ImportStatus.UNSUPPORTED);
      expect(res.unsupported).assertEqual(1);
      expect(res.succeeded).assertEqual(2);
      // 有效项确实落台账（批次未中止）
      const ledger: ImportedBook[] = ImportedBookStore.load(root);
      expect(ledger.length).assertEqual(2);
      // 不支持项不产生任何产物
      expect(exists(root + '/books/bad.pdf')).assertFalse();
      rmrf(root);
    });

    it('US4_idempotent_dedupe_within_batch', 0, async () => {
      const root: string = rootOf('us4');
      rmrf(root);
      mkdirp(root + '/src');
      const tx: string = root + '/src/dup.txt';
      writeText(tx, txtCorpus(2));
      // 首本先单独导入 → 台账已有
      const first: ImportResult = await ImportService.importBook(root, {
        sourcePath: tx, displayName: 'dup.txt'
      });
      expect(first.status).assertEqual(ImportStatus.SUCCESS);
      const known: string = first.bookId;
      expect(ledgerHas(ImportedBookStore.load(root), known)).assertTrue();
      // 批次：含已导入项 + 同一文件重复选中两次
      const res: BatchImportResult = await ImportService.importBooks(root, reqsFrom([tx, tx, tx]));
      log('US4 already=' + res.alreadyImported + ' success=' + res.succeeded +
        ' ledger=' + ImportedBookStore.load(root).length);
      expect(res.total).assertEqual(3);
      expect(res.alreadyImported).assertEqual(3);
      expect(res.succeeded).assertEqual(0);
      // 无冲突副本：台账仍为 1 条，源文件仅一份
      expect(ImportedBookStore.load(root).length).assertEqual(1);
      expect(exists(root + '/books/dup.txt')).assertTrue();
      expect(exists(root + '/books/dup_1.txt')).assertFalse();
      rmrf(root);
    });
  });
}
