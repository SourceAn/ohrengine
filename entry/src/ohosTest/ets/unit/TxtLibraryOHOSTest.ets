/**
 * TxtLibraryOHOSTest — 阶段1 验收：TXT 索引迁入持久目录 library/ + 原子写入
 *
 * 只测试 TxtDocument（经由 TxtDocument.open）与路径/清理工具的行为，
 * 不改产品逻辑。使用独立的临时 filesDir 子目录与小语料，测试前后清理。
 *
 * 路径集中化：bookName = basename(sourcePath 非空 ? sourcePath : bookBasePath)，
 * cacheDir = filesDir/cache/books/<bookName>，libraryDir = filesDir/library/<bookName>。
 */
import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  BookStorage, DiskCacheQuotaManager, CacheMigration, PageCacheManager,
  PAGE_CACHE_SCHEMA_VERSION, LAYOUT_ALGORITHM_VERSION
} from 'ohrengine-common';
import { TxtDocument, TxtIndexBuilder, TxtIndexData } from 'ohrengine-txt-exclusive';

const DOMAIN: number = 0x0000;
const TAG: string = 'TXTLIB';
const FILESDIR: string = '/data/storage/el2/base/haps/entry/files';
const TR: string = FILESDIR + '/txtlib_test';
const BOOKNAME: string = 'libtest.txt';
const SRC: string = TR + '/books/' + BOOKNAME;

function log(msg: string): void {
  hilog.info(DOMAIN, TAG, '%{public}s', msg);
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

function readText(p: string): string {
  try { return fileIo.readTextSync(p); } catch (_e) { return ''; }
}

function corpus(): string {
  let s: string = '第1章 起点\n\n';
  for (let i: number = 0; i < 1500; i++) {
    s += '这是第一段测试文字，用于产生足够多的段落到达体积。编号' + i + '\n\n';
  }
  s += '第2章 继续\n\n';
  for (let i: number = 0; i < 1500; i++) {
    s += '这是第二段测试文字，继续填充内容以便索引规模接近真实。编号' + i + '\n\n';
  }
  return s;
}

function setup(): void {
  rmrf(TR);
  mkdirp(TR + '/books');
  writeText(SRC, corpus());
}

function cacheDirOf(): string { return BookStorage.pageCacheDirOf(TR, BOOKNAME); }
function libraryOf(): string { return BookStorage.libraryDirOf(TR, BOOKNAME); }
function libIndex(): string { return libraryOf() + '/txt-index-v2.json'; }
function cacheIndex(): string { return cacheDirOf() + '/txt-index-v2.json'; }

async function openSrc(lib?: string): Promise<string> {
  const doc: TxtDocument | undefined = await TxtDocument.open(SRC, cacheDirOf(), lib);
  return doc === undefined ? 'undefined' : TxtDocument.getLastOpenSource();
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); });
}

export default function txtLibraryTest() {
  describe('TxtLibraryTest', () => {

    it('T1_persistence_against_cache_cleaners', 0, async () => {
      setup();
      const cache: string = cacheDirOf();
      const lib: string = libraryOf();
      // 首次构建 → 写入 library
      let src1: string = await openSrc(lib);
      const libCkpt0: boolean = exists(libIndex());
      log('T1 first expected=built actual=' + src1 + ' libIndex=' + (libCkpt0 ? 1 : 0));
      expect(src1).assertEqual('built');
      expect(libCkpt0).assertTrue();

      // a) PageCacheManager.invalidate(cacheDir)
      mkdirp(cache);
      writeText(cache + '/meta.json', '{"version":1}');
      writeText(cache + '/chapter_0.json', '{}');
      writeText(cache + '/pgcount.json', '{}');
      PageCacheManager.invalidate(cache);
      const a: string = await openSrc(lib);
      log('T1a after invalidate source=' + a + ' libIndex=' + (exists(libIndex()) ? 1 : 0));
      expect(a).assertEqual('library');
      expect(exists(libIndex())).assertTrue();

      // b) clearStalePageCache（meta.version < current）
      rmrf(cache);
      mkdirp(cache);
      writeText(cache + '/meta.json', '{"version":' + (PageCacheManager.getCacheVersion() - 1) + '}');
      const clearedB: boolean = CacheMigration.clearStalePageCache(cache, PageCacheManager.getCacheVersion());
      const b: string = await openSrc(lib);
      log('T1b cleared=' + (clearedB ? 1 : 0) + ' cacheExists=' + (exists(cache) ? 1 : 0) +
        ' libIndex=' + (exists(libIndex()) ? 1 : 0) + ' source=' + b);
      expect(clearedB).assertTrue();
      expect(exists(cache)).assertFalse();
      expect(exists(libIndex())).assertTrue();
      expect(b).assertEqual('library');

      // c) clearIncompatibleSchema（schemaVersion 不一致）
      rmrf(cache);
      mkdirp(cache);
      writeText(cache + '/meta.json', '{"schemaVersion":999,"layoutAlgorithmVersion":1}');
      const clearedC: boolean = CacheMigration.clearIncompatibleSchema(cache,
        PAGE_CACHE_SCHEMA_VERSION, LAYOUT_ALGORITHM_VERSION);
      const c: string = await openSrc(lib);
      log('T1c cleared=' + (clearedC ? 1 : 0) + ' cacheExists=' + (exists(cache) ? 1 : 0) +
        ' libIndex=' + (exists(libIndex()) ? 1 : 0) + ' source=' + c);
      expect(clearedC).assertTrue();
      expect(exists(cache)).assertFalse();
      expect(exists(libIndex())).assertTrue();
      expect(c).assertEqual('library');

      // d) DiskCacheQuotaManager.enforceGlobalQuota（cache/books 超预算 → 淘汰整本 cacheDir）
      rmrf(cache);
      mkdirp(cache);
      const big: fileIo.File = fileIo.openSync(cache + '/big.bin',
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const chunk: Uint8Array = new Uint8Array(1024 * 1024);
      fileIo.writeSync(big.fd, chunk.buffer);
      fileIo.writeSync(big.fd, chunk.buffer);
      fileIo.closeSync(big);
      const quota: DiskCacheQuotaManager = new DiskCacheQuotaManager(1024 * 1024, 1024 * 1024);
      quota.enforceGlobalQuota(TR);
      const d: string = await openSrc(lib);
      log('T1d cacheExists=' + (exists(cache) ? 1 : 0) + ' libIndex=' + (exists(libIndex()) ? 1 : 0) + ' source=' + d);
      expect(exists(cache)).assertFalse();
      expect(exists(libIndex())).assertTrue();
      expect(d).assertEqual('library');
      expect(true).assertTrue();
    });

    it('T2_legacy_migration', 0, async () => {
      setup();
      const cache: string = cacheDirOf();
      const lib: string = libraryOf();
      // 用旧位置生成一份合法索引（libraryDir='' → 写 cacheDir）
      const built: string = await openSrc('');
      log('T2 legacy-build source=' + built + ' cacheIndex=' + (exists(cacheIndex()) ? 1 : 0));
      expect(built).assertEqual('built');
      expect(exists(cacheIndex())).assertTrue();
      const legacyContentBefore: string = readText(cacheIndex());
      // library 为空 → 首次 open 应命中 legacy 并迁移
      const first: string = await openSrc(lib);
      const legStill: boolean = exists(cacheIndex());
      const legSame: boolean = readText(cacheIndex()) === legacyContentBefore;
      log('T2 first source=' + first + ' libIndex=' + (exists(libIndex()) ? 1 : 0) +
        ' legacyStill=' + (legStill ? 1 : 0) + ' legacyUnchanged=' + (legSame ? 1 : 0));
      expect(first).assertEqual('legacy');
      expect(exists(libIndex())).assertTrue();
      expect(legStill).assertTrue();
      expect(legSame).assertTrue();
      // 删除旧位置后第二次 open → library
      try { fileIo.unlinkSync(cacheIndex()); } catch (_e) { }
      const second: string = await openSrc(lib);
      log('T2 second source=' + second);
      expect(second).assertEqual('library');
    });

    it('T3_invalidation_size_and_mtime', 0, async () => {
      setup();
      const lib: string = libraryOf();
      const first: string = await openSrc(lib);
      log('T3 first source=' + first);
      expect(first).assertEqual('built');
      // size 变化：追加内容
      const more: fileIo.File = fileIo.openSync(SRC, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.APPEND);
      fileIo.writeSync(more.fd, '\n\n第3章 追加\n\n追加内容使文件变大。\n');
      fileIo.closeSync(more);
      const afterSize: string = await openSrc(lib);
      log('T3 after-size source=' + afterSize + ' mtime=' + fileIo.statSync(SRC).mtime);
      expect(afterSize).assertEqual('built');
      // 仅 mtime 变化（内容与大小不变）
      const same: string = readText(SRC);
      await sleep(1100);
      writeText(SRC, same);
      const afterMtime: string = await openSrc(lib);
      log('T3 after-mtime source=' + afterMtime);
      expect(afterMtime).assertEqual('built');
      expect(true).assertTrue();
    });

    it('T4_atomicity_and_corruption', 0, async () => {
      setup();
      const lib: string = libraryOf();
      const s0: string = await openSrc(lib);
      expect(s0).assertEqual('built');
      // a) 保存后无 .tmp 残留
      const tmpA: boolean = exists(lib + '/txt-index-v2.json.tmp');
      log('T4a tmpAfterSave=' + (tmpA ? 1 : 0));
      expect(tmpA).assertFalse();

      // b) library 写入截断 JSON → open 回退 built 并以正确内容覆盖
      writeText(libIndex(), '{"version":1,"fileSize":');
      const sB: string = await openSrc(lib);
      const repaired: TxtIndexData | null = TxtIndexData.fromJson(readText(libIndex()));
      log('T4b source=' + sB + ' repaired=' + (repaired !== null ? 1 : 0));
      expect(sB).assertEqual('built');
      expect(repaired !== null).assertTrue();

      // c) 遗留 .tmp → 不读取，保存后不残留
      writeText(lib + '/txt-index-v2.json.tmp', 'GARBAGE-NOT-JSON');
      const sC: string = await openSrc(lib);
      const tmpC: boolean = exists(lib + '/txt-index-v2.json.tmp');
      log('T4c source=' + sC + ' tmpAfter=' + (tmpC ? 1 : 0));
      expect(sC).assertEqual('library');
      expect(tmpC).assertFalse();

      // d) 读回校验：索引 fileSize/mtime 与源文件 stat 一致
      const st = fileIo.statSync(SRC);
      const idx: TxtIndexData | null = TxtIndexData.fromJson(readText(libIndex()));
      const okD: boolean = idx !== null && idx.fileSize === st.size && idx.mtime === st.mtime;
      log('T4d idxFileSize=' + (idx !== null ? idx.fileSize : -1) + ' statSize=' + st.size +
        ' idxMtime=' + (idx !== null ? idx.mtime : -1) + ' statMtime=' + st.mtime + ' ok=' + (okD ? 1 : 0));
      expect(okD).assertTrue();
      expect(true).assertTrue();
    });

    it('T5_path_centralization', 0, () => {
      // bookName 推导：TXT / EPUB / CBZ
      const txtName: string = BookStorage.deriveBookName('', '/x/books/a.txt');
      const epubName: string = BookStorage.deriveBookName('/x/books/a.epub', '/x/books/a.epub_extracted');
      const cbzName: string = BookStorage.deriveBookName('', '/x/books/a.cbz_extracted');
      const pc: string = BookStorage.pageCacheDirOf('/f', 'a.txt');
      const lb: string = BookStorage.libraryDirOf('/f', 'a.txt');
      log('T5 txt=' + txtName + ' epub=' + epubName + ' cbz=' + cbzName + ' pc=' + pc + ' lb=' + lb);
      expect(txtName).assertEqual('a.txt');
      expect(epubName).assertEqual('a.epub');
      expect(cbzName).assertEqual('a.cbz_extracted');
      expect(pc).assertEqual('/f/cache/books/a.txt');
      expect(lb).assertEqual('/f/library/a.txt');

      // library 不受配额影响（托管目录不含 library 的行为证明）
      rmrf(TR);
      mkdirp(TR + '/cache/books');
      mkdirp(TR + '/library/biglib');
      const f: fileIo.File = fileIo.openSync(TR + '/library/biglib/big.bin',
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const c2: Uint8Array = new Uint8Array(1024 * 1024);
      fileIo.writeSync(f.fd, c2.buffer);
      fileIo.writeSync(f.fd, c2.buffer);
      fileIo.closeSync(f);
      const q: DiskCacheQuotaManager = new DiskCacheQuotaManager(1024 * 1024, 1024 * 1024);
      q.enforceGlobalQuota(TR);
      const libSurvives: boolean = exists(TR + '/library/biglib/big.bin');
      log('T5 librarySurvivesQuota=' + (libSurvives ? 1 : 0));
      expect(libSurvives).assertTrue();
      rmrf(TR);
      expect(true).assertTrue();
    });

    it('G1_golden_write', 0, async () => {
      const outDir: string = FILESDIR + '/golden2';
      rmrf(outDir);
      mkdirp(outDir);
      const files: string[] = ['bench_txt_m.txt', 'bench_txt_l.txt'];
      for (let i: number = 0; i < files.length; i++) {
        const name: string = files[i];
        const idx: TxtIndexData | null = await TxtIndexBuilder.build(FILESDIR + '/books/' + name);
        if (idx === null) { log('G1 ' + name + ' NULL'); continue; }
        const json: string = idx.toJson();
        writeText(outDir + '/' + name + '.golden.json', json);
        log('G1 ' + name + ' jsonLen=' + json.length);
      }
      expect(true).assertTrue();
    });
  });
}
