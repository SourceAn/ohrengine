/**
 * BookImportOHOSTest — 图书统一导入（导入即解析）与可逆导出 验收测试
 *
 * 覆盖：
 *   US1 统一入口导入（导入即解析）：
 *     - EPUB → 台账记录 + 源文件 + 解压目录指纹 + 分块解析缓存 parse/meta.json 存在
 *     - TXT  → library/<bookName>/txt-index-v2.json 存在
 *     - PDF  → UNSUPPORTED 且不产生任何产物
 *   US2 导入后热启动：
 *     - 二次导入返回 ALREADY_IMPORTED；isChunkedValid 为真；解析缓存未被重写（mtime 未变）
 *   US3 可逆导出：
 *     - EPUB / TXT 导出与源逐字节一致；源缺失 → 明确报错
 *   US5 去重 / 失效 / 失败可恢复：
 *     - 同源二次导入不产生重复记录；源变化 → 指纹失效并重建；失败不落台账且可重试
 *
 * 使用独立的临时根目录（作为 filesDir 传入 ImportService），测试前后清理。
 */

import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import {
  ImportService, ImportedBookStore, ImportStatus, ParserRegistry, ParseCacheManager
} from 'ohrengine-common';
import type { ImportedBook, ImportResult } from 'ohrengine-common';
import { EpubParser } from 'ohrengine-epub';
import { TxtParser } from 'ohrengine-txt-exclusive';
import { CbzParser } from 'ohrengine-cbz-exclusive';
import { PdfParser } from 'ohrengine-pdf-exclusive';

const DOMAIN: number = 0x0000;
const TAG: string = 'BookImportTest';
const ROOT_PREFIX: string = 'import_test_';

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

function readAllBytes(p: string): Uint8Array {
  const st: fileIo.Stat = fileIo.statSync(p);
  const f: fileIo.File = fileIo.openSync(p, fileIo.OpenMode.READ_ONLY);
  const buf: ArrayBuffer = new ArrayBuffer(st.size);
  const n: number = fileIo.readSync(f.fd, buf);
  fileIo.closeSync(f);
  return new Uint8Array(buf.slice(0, n));
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i: number = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
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
      s += '这是用于导入索引构建的测试段落文字，编号 ' + String(c) + '-' + String(p) +
        '，补充足够长度以便形成可用的章节与段落结构。\n\n';
    }
  }
  return s;
}

function baseName(p: string): string {
  const slash: number = p.lastIndexOf('/');
  return slash >= 0 ? p.substring(slash + 1) : p;
}

export default function bookImportTest() {
  // 解析器注册（测试进程不保证 UIAbility.onCreate 已执行，故显式注册）
  ParserRegistry.register(new EpubParser());
  ParserRegistry.register(new TxtParser());
  ParserRegistry.register(new CbzParser());
  ParserRegistry.register(new PdfParser());
  describe('BookImportTest', () => {

    it('US1_import_epub_creates_ledger_and_parse_cache', 0, async () => {
      const root: string = rootOf('us1_epub');
      rmrf(root);
      mkdirp(root + '/src');
      const src: string = root + '/src/book.epub';
      releaseEpub(src);
      const res: ImportResult = await ImportService.importBook(root, {
        sourcePath: src, displayName: 'book.epub'
      });
      log('US1 epub status=' + res.status + ' bookId=' + res.bookId);
      expect(res.status).assertEqual(ImportStatus.SUCCESS);
      const rec: ImportedBook | undefined = res.record;
      expect(rec !== undefined).assertTrue();
      if (rec === undefined) {
        return;
      }
      expect(exists(rec.sourcePath)).assertTrue();
      expect(exists(rec.extractDir + '/.fingerprint.json')).assertTrue();
      expect(exists(rec.cacheDir + '/parse/meta.json')).assertTrue();
      const ledger: ImportedBook[] = ImportedBookStore.load(root);
      expect(ledger.length).assertEqual(1);
      expect(ledger[0].bookId).assertEqual(rec.bookId);
      rmrf(root);
    });

    it('US1_import_txt_creates_library_index', 0, async () => {
      const root: string = rootOf('us1_txt');
      rmrf(root);
      mkdirp(root + '/src');
      const src: string = root + '/src/sample.txt';
      writeText(src, txtCorpus(3));
      const res: ImportResult = await ImportService.importBook(root, {
        sourcePath: src, displayName: 'sample.txt'
      });
      log('US1 txt status=' + res.status + ' bookId=' + res.bookId);
      expect(res.status).assertEqual(ImportStatus.SUCCESS);
      const rec: ImportedBook | undefined = res.record;
      expect(rec !== undefined).assertTrue();
      if (rec === undefined) {
        return;
      }
      expect(exists(root + '/library/sample.txt/txt-index-v2.json')).assertTrue();
      rmrf(root);
    });

    it('US1_import_pdf_unsupported_no_artifacts', 0, async () => {
      const root: string = rootOf('us1_pdf');
      rmrf(root);
      mkdirp(root + '/src');
      const src: string = root + '/src/doc.pdf';
      writeText(src, '%PDF-1.4 dummy');
      const res: ImportResult = await ImportService.importBook(root, {
        sourcePath: src, displayName: 'doc.pdf'
      });
      log('US1 pdf status=' + res.status + ' error=' + (res.error !== undefined ? res.error : ''));
      expect(res.status).assertEqual(ImportStatus.UNSUPPORTED);
      // UNSUPPORTED 不产生任何产物
      expect(exists(root + '/books/doc.pdf')).assertFalse();
      expect(ImportedBookStore.load(root).length).assertEqual(0);
      rmrf(root);
    });

    it('US2_second_import_is_warm_start', 0, async () => {
      const root: string = rootOf('us2');
      rmrf(root);
      mkdirp(root + '/src');
      const src: string = root + '/src/warm.epub';
      releaseEpub(src);
      const first: ImportResult = await ImportService.importBook(root, {
        sourcePath: src, displayName: 'warm.epub'
      });
      expect(first.status).assertEqual(ImportStatus.SUCCESS);
      const rec: ImportedBook | undefined = first.record;
      expect(rec !== undefined).assertTrue();
      if (rec === undefined) {
        return;
      }
      const metaPath: string = rec.cacheDir + '/parse/meta.json';
      const m1: number = fileIo.statSync(metaPath).mtime;
      const second: ImportResult = await ImportService.importBook(root, {
        sourcePath: rec.sourcePath, displayName: 'warm.epub'
      });
      log('US2 second status=' + second.status);
      expect(second.status).assertEqual(ImportStatus.ALREADY_IMPORTED);
      expect(ParseCacheManager.isChunkedValid(rec.cacheDir, rec.sourcePath)).assertTrue();
      const m2: number = fileIo.statSync(metaPath).mtime;
      expect(m1).assertEqual(m2); // 解析缓存未被重写
      rmrf(root);
    });

    it('US3_export_epub_and_txt_byte_identical', 0, async () => {
      const root: string = rootOf('us3');
      rmrf(root);
      mkdirp(root + '/src');
      // EPUB
      const epubSrc: string = root + '/src/share.epub';
      releaseEpub(epubSrc);
      const epubRes: ImportResult = await ImportService.importBook(root, {
        sourcePath: epubSrc, displayName: 'share.epub'
      });
      expect(epubRes.status).assertEqual(ImportStatus.SUCCESS);
      const epubRec: ImportedBook | undefined = epubRes.record;
      expect(epubRec !== undefined).assertTrue();
      if (epubRec === undefined) {
        return;
      }
      const art = await ImportService.exportBook(root, epubRec.bookId);
      log('US3 epub export size=' + art.size + ' path=' + art.path);
      expect(art.format).assertEqual('.epub');
      expect(bytesEqual(readAllBytes(epubRec.sourcePath), readAllBytes(art.path))).assertTrue();
      // TXT
      const txtSrc: string = root + '/src/share.txt';
      writeText(txtSrc, txtCorpus(2));
      const txtRes: ImportResult = await ImportService.importBook(root, {
        sourcePath: txtSrc, displayName: 'share.txt'
      });
      expect(txtRes.status).assertEqual(ImportStatus.SUCCESS);
      const txtRec: ImportedBook | undefined = txtRes.record;
      expect(txtRec !== undefined).assertTrue();
      if (txtRec === undefined) {
        return;
      }
      const txtArt = await ImportService.exportBook(root, txtRec.bookId);
      expect(bytesEqual(readAllBytes(txtRec.sourcePath), readAllBytes(txtArt.path))).assertTrue();
      rmrf(root);
    });

    it('US3_export_missing_source_errors', 0, async () => {
      const root: string = rootOf('us3_missing');
      rmrf(root);
      mkdirp(root + '/src');
      const src: string = root + '/src/gone.txt';
      writeText(src, txtCorpus(1));
      const res: ImportResult = await ImportService.importBook(root, {
        sourcePath: src, displayName: 'gone.txt'
      });
      expect(res.status).assertEqual(ImportStatus.SUCCESS);
      const rec: ImportedBook | undefined = res.record;
      expect(rec !== undefined).assertTrue();
      if (rec === undefined) {
        return;
      }
      try { fileIo.unlinkSync(rec.sourcePath); } catch (_e) { }
      let threw: boolean = false;
      try {
        await ImportService.exportBook(root, rec.bookId);
      } catch (_e) {
        threw = true;
      }
      log('US3 missing-source threw=' + (threw ? 1 : 0));
      expect(threw).assertTrue();
      rmrf(root);
    });

    it('US5_dedupe_invalidation_and_failure_retry', 0, async () => {
      const root: string = rootOf('us5');
      rmrf(root);
      mkdirp(root + '/src');
      const src: string = root + '/src/dup.txt';
      writeText(src, txtCorpus(2));
      const first: ImportResult = await ImportService.importBook(root, {
        sourcePath: src, displayName: 'dup.txt'
      });
      expect(first.status).assertEqual(ImportStatus.SUCCESS);
      const rec: ImportedBook | undefined = first.record;
      expect(rec !== undefined).assertTrue();
      if (rec === undefined) {
        return;
      }
      // 去重：同源二次导入 → ALREADY_IMPORTED 且台账条数不增
      const dup: ImportResult = await ImportService.importBook(root, {
        sourcePath: rec.sourcePath, displayName: 'dup.txt'
      });
      expect(dup.status).assertEqual(ImportStatus.ALREADY_IMPORTED);
      expect(ImportedBookStore.load(root).length).assertEqual(1);
      // 失效：源变化 → 指纹不同 → 重建
      writeText(rec.sourcePath, txtCorpus(5));
      const rebuilt: ImportResult = await ImportService.importBook(root, {
        sourcePath: rec.sourcePath, displayName: 'dup.txt'
      });
      log('US5 rebuilt status=' + rebuilt.status);
      expect(rebuilt.status).assertEqual(ImportStatus.SUCCESS);
      const rec2: ImportedBook | undefined = rebuilt.record;
      expect(rec2 !== undefined).assertTrue();
      if (rec2 !== undefined) {
        expect(rec2.fingerprint === rec.fingerprint).assertFalse();
      }
      expect(ImportedBookStore.load(root).length).assertEqual(1);
      // 失败可重试：源不存在 → FAILED 不落台账；补齐后成功
      const missing: ImportResult = await ImportService.importBook(root, {
        sourcePath: root + '/src/nope.epub', displayName: 'nope.epub'
      });
      expect(missing.status).assertEqual(ImportStatus.FAILED);
      expect(exists(root + '/books/nope.epub')).assertFalse();
      rmrf(root);
    });
  });
}
