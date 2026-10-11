/**
 * MinimalBookshelfOHOSTest — 极简书架与彻底删除 验收测试
 *
 * 覆盖：
 *   US1 台账投影：
 *     - 导入后台账投影出预期 `ShelfItem`（标题 / 源路径 / 格式 / bookId）
 *   US2 彻底删除：
 *     - 导入 → 注册关联数据清理器 → 写入批注 + 书签 →
 *       `deleteBook` → 台账记录、源文件、library 目录、缓存目录消失；批注 / 书签被清除
 *   US4 健壮性：
 *     - 删除不存在的书 → `NOT_FOUND` 安全返回（不崩溃、台账不变）
 *     - 删除一本书 → 其他图书完好、台账保持一致
 *
 * 使用独立临时根目录（作为 filesDir 传入），测试前后清理。
 */

import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import {
  ImportService, ImportedBookStore, ImportStatus, DeleteStatus,
  AnnotationType, createEmptyLocator, ParserRegistry
} from 'ohrengine-common';
import type { ImportedBook, ImportResult, DeleteResult, Annotation, Locator } from 'ohrengine-common';
import { AnnotationStorage, BookmarkStorage } from 'ohrengine-feature';
import type { Bookmark } from 'ohrengine-feature';
import { EpubParser } from 'ohrengine-epub';
import { TxtParser } from 'ohrengine-txt-exclusive';
import { CbzParser } from 'ohrengine-cbz-exclusive';
import { PdfParser } from 'ohrengine-pdf-exclusive';
import { projectShelfItems } from '../../../main/ets/components/ShelfModel';
import type { ShelfItem } from '../../../main/ets/components/ShelfModel';
import { FeatureDataCleaner } from '../../../main/ets/deletion/FeatureDataCleaner';

const DOMAIN: number = 0x0000;
const TAG: string = 'MinimalShelfTest';
const ROOT_PREFIX: string = 'minimal_shelf_';

function log(msg: string): void {
  hilog.info(DOMAIN, TAG, '%{public}s', msg);
}

function appContext(): common.Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
}

function appFilesDir(): string {
  return appContext().filesDir;
}

function rootOf(name: string): string {
  return appFilesDir() + '/' + ROOT_PREFIX + name;
}

function uniqueTag(name: string): string {
  return name + '_' + String(Date.now());
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

function txtCorpus(chapters: number): string {
  let s: string = '';
  for (let c: number = 1; c <= chapters; c++) {
    s += '第' + String(c) + '章 测试章节\n\n';
    for (let p: number = 0; p < 40; p++) {
      s += '用于书架投影与彻底删除测试的段落文字，编号 ' + String(c) + '-' + String(p) +
        '，补充足够长度以形成可用的章节与段落结构。\n\n';
    }
  }
  return s;
}

function makeAnnotation(id: string): Annotation {
  const loc: Locator = createEmptyLocator();
  loc.chapterIndex = 0;
  loc.paragraphIndex = 1;
  loc.wordIndex = 4;
  const ann: Annotation = {
    id: id,
    type: AnnotationType.HIGHLIGHT,
    locator: loc,
    text: '测试批注文本',
    note: undefined,
    color: '#FFEE00',
    created: new Date().toISOString(),
    modified: undefined,
    chapterIndex: 0,
    startCharOffset: 1,
    endCharOffset: 4,
    synchronizationVersion: 0,
    noteText: undefined,
    noteTimestamp: undefined,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    isVisible: 1
  };
  return ann;
}

function makeBookmark(id: string): Bookmark {
  const bm: Bookmark = {
    id: id,
    chapterIndex: 0,
    charOffset: 10,
    createdAt: Date.now(),
    type: 'bookmark'
  };
  return bm;
}

export default function minimalBookshelfTest() {
  // 解析器注册（测试进程不保证 UIAbility.onCreate 已执行，故显式注册）
  ParserRegistry.register(new EpubParser());
  ParserRegistry.register(new TxtParser());
  ParserRegistry.register(new CbzParser());
  ParserRegistry.register(new PdfParser());

  describe('MinimalBookshelfTest', () => {

    // ---------- US1：台账投影 ----------
    it('US1_project_ledger_to_shelf_items', 0, async () => {
      const root: string = rootOf('us1');
      rmrf(root);
      mkdirp(root + '/src');
      const src: string = root + '/src/shelf_sample.txt';
      writeText(src, txtCorpus(2));
      const res: ImportResult = await ImportService.importBook(root, {
        sourcePath: src, displayName: 'shelf_sample.txt'
      });
      expect(res.status).assertEqual(ImportStatus.SUCCESS);
      const rec: ImportedBook | undefined = res.record;
      expect(rec !== undefined).assertTrue();
      if (rec === undefined) {
        return;
      }
      const items: ShelfItem[] = projectShelfItems(ImportedBookStore.load(root));
      log('US1 items=' + items.length);
      expect(items.length).assertEqual(1);
      expect(items[0].bookId).assertEqual(rec.bookId);
      expect(items[0].sourcePath).assertEqual(rec.sourcePath);
      expect(items[0].format).assertEqual(rec.format);
      // 展示标题：优先解析标题（TXT 无元数据 → 回退文件名去扩展名）；非空
      expect(items[0].title.length > 0).assertTrue();
      rmrf(root);
    });

    // ---------- US2：彻底删除（含跨模块批注/书签清理） ----------
    it('US2_delete_removes_ledger_artifacts_and_associations', 0, async () => {
      const root: string = rootOf('us2');
      rmrf(root);
      mkdirp(root + '/src');
      const tag: string = uniqueTag('us2book');
      const src: string = root + '/src/' + tag + '.txt';
      writeText(src, txtCorpus(2));
      const res: ImportResult = await ImportService.importBook(root, {
        sourcePath: src, displayName: tag + '.txt'
      });
      expect(res.status).assertEqual(ImportStatus.SUCCESS);
      const rec: ImportedBook | undefined = res.record;
      expect(rec !== undefined).assertTrue();
      if (rec === undefined) {
        return;
      }
      // 关联数据（以台账 record.title 为键，与引擎元数据标题一致）
      const annStorage: AnnotationStorage = new AnnotationStorage();
      await annStorage.init(appContext());
      const bmStorage: BookmarkStorage = new BookmarkStorage();
      await bmStorage.init(appContext());
      await annStorage.save(rec.title, makeAnnotation('ann-' + tag));
      await bmStorage.save(rec.title, makeBookmark('bm-' + tag));
      expect((await annStorage.getAll(rec.title)).length).assertEqual(1);
      expect((await bmStorage.getAll(rec.title)).length).assertEqual(1);
      // 注册应用层清理器（批注/书签）
      ImportService.clearAssociatedDataCleaners();
      ImportService.registerAssociatedDataCleaner(new FeatureDataCleaner(appContext()));
      // 彻底删除
      const del: DeleteResult = await ImportService.deleteBook(root, rec.bookId, {
        readingStateDir: root + '/reading_state'
      });
      log('US2 delete status=' + del.status + ' cleaned=' + del.cleanedItems.join('/') +
        ' failed=' + del.failedItems.join('/'));
      expect(del.status).assertEqual(DeleteStatus.DELETED);
      expect(ImportedBookStore.load(root).length).assertEqual(0);
      expect(exists(rec.sourcePath)).assertFalse();
      expect(exists(rec.libraryDir)).assertFalse();
      expect(exists(rec.cacheDir)).assertFalse();
      // 批注 / 书签被清除
      expect((await annStorage.getAll(rec.title)).length).assertEqual(0);
      expect((await bmStorage.getAll(rec.title)).length).assertEqual(0);
      ImportService.clearAssociatedDataCleaners();
      rmrf(root);
    });

    // ---------- US4：删除不存在的书 → NOT_FOUND 安全 ----------
    it('US4_delete_not_found_is_safe', 0, async () => {
      const root: string = rootOf('us4_missing');
      rmrf(root);
      mkdirp(root + '/src');
      const src: string = root + '/src/keep.txt';
      writeText(src, txtCorpus(1));
      const res: ImportResult = await ImportService.importBook(root, {
        sourcePath: src, displayName: 'keep.txt'
      });
      expect(res.status).assertEqual(ImportStatus.SUCCESS);
      const before: number = ImportedBookStore.load(root).length;
      const del: DeleteResult = await ImportService.deleteBook(root, '.txt:does-not-exist:0');
      log('US4 not-found status=' + del.status);
      expect(del.status).assertEqual(DeleteStatus.NOT_FOUND);
      // 台账不受影响
      expect(ImportedBookStore.load(root).length).assertEqual(before);
      rmrf(root);
    });

    // ---------- US4：删除一本不影响其他图书 ----------
    it('US4_delete_one_keeps_others_intact', 0, async () => {
      const root: string = rootOf('us4_isolation');
      rmrf(root);
      mkdirp(root + '/src');
      const a: string = root + '/src/' + uniqueTag('iso_a') + '.txt';
      const b: string = root + '/src/' + uniqueTag('iso_b') + '.txt';
      writeText(a, txtCorpus(2));
      writeText(b, txtCorpus(2));
      const ra: ImportResult = await ImportService.importBook(root, { sourcePath: a });
      const rb: ImportResult = await ImportService.importBook(root, { sourcePath: b });
      expect(ra.status).assertEqual(ImportStatus.SUCCESS);
      expect(rb.status).assertEqual(ImportStatus.SUCCESS);
      const recA: ImportedBook | undefined = ra.record;
      const recB: ImportedBook | undefined = rb.record;
      expect(recA !== undefined && recB !== undefined).assertTrue();
      if (recA === undefined || recB === undefined) {
        return;
      }
      expect(ImportedBookStore.load(root).length).assertEqual(2);
      const del: DeleteResult = await ImportService.deleteBook(root, recA.bookId);
      log('US4 isolation status=' + del.status);
      // 台账仅剩 B，且 B 的源文件完好
      const remaining: ImportedBook[] = ImportedBookStore.load(root);
      expect(remaining.length).assertEqual(1);
      expect(remaining[0].bookId).assertEqual(recB.bookId);
      expect(exists(recB.sourcePath)).assertTrue();
      expect(exists(recA.sourcePath)).assertFalse();
      rmrf(root);
    });
  });
}
