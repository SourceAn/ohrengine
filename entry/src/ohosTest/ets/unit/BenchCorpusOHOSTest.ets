/**
 * BenchCorpusOHOSTest — 标准 Bench 语料注入（设备内生成 / 释放）
 *
 * 为什么需要它：无 root 的设备（DevEco 模拟器 / 零售真机）上，主机 hdc 无法写入应用沙箱
 * （filesDir 为 0700 且属主是应用 uid，`hdc smode` 在非 debug 版不可用），而阅读器只从
 * `<filesDir>/books` 读取书籍。因此语料的唯一可靠注入通道 = 应用同 bundle 的 ohosTest 进程。
 *
 * 语料与 `tests/bench/corpus.json` 对应：
 *   - TXT 各档：设备内程序化生成（精确字节数，可复现）
 *   - EPUB / CBZ(小) / PDF / demo：从 entry 模块 rawfile 释放（零新增仓库体积）
 *   - cbz-l：设备内合成真实规模漫画（200 页 × 1.5 MB ≈ 300 MB 解压量，zlib.zipFile 打包），
 *            用于量化「ZIP 类每次打开全量解压」的代价；中间产物测完即删，不占用户存储。
 *
 * 运行:
 *   hdc shell aa test -b com.example.ohrengine -m entry_test \
 *     -s unittest OpenHarmonyTestRunner -s class BenchCorpusTest -s timeout 900000
 *
 * 输出埋点（hilog tag=BenchCorpus）:
 *   BENCH_CORPUS id=<id> file=<name> bytes=<n> ms=<ms>
 *   BENCH_CORPUS_CBZ_GEN pages=<n> unpacked=<n> zip=<n>
 *   BENCH_CORPUS_DONE dir=<path> count=<n> totalBytes=<n> ms=<ms>
 */
import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';

const TAG: string = 'BenchCorpus';
const DOMAIN: number = 0x0000;
const BOOKS_SUBDIR: string = '/books';

interface CorpusSpec {
  id: string;
  file: string;
  kind: string;       // 'txt-gen' | 'rawfile' | 'cbz-gen'
  bytes: number;      // txt-gen: 目标字节数；其余 0
  raw: string;        // 源 rawfile 名
  pages?: number;     // cbz-gen: 页数
  pageBytes?: number; // cbz-gen: 每页字节数
}

const CORPUS: CorpusSpec[] = [
  { id: 'txt-s', file: 'bench_txt_s.txt', kind: 'txt-gen', bytes: 262144, raw: '' },
  { id: 'txt-m', file: 'bench_txt_m.txt', kind: 'txt-gen', bytes: 2097152, raw: '' },
  { id: 'txt-l', file: 'bench_txt_l.txt', kind: 'txt-gen', bytes: 7774272, raw: '' },
  { id: 'txt-xl', file: 'bench_txt_xl.txt', kind: 'txt-gen', bytes: 52428800, raw: '' },
  { id: 'epub-s', file: 'bench_epub_s.epub', kind: 'rawfile', bytes: 0, raw: 'test.epub' },
  { id: 'cbz', file: 'bench_cbz.cbz', kind: 'rawfile', bytes: 0, raw: 'test.cbz' },
  { id: 'cbz-l', file: 'bench_cbz_l.cbz', kind: 'cbz-gen', bytes: 0, raw: 'shared_text_page.png', pages: 200, pageBytes: 1572864 },
  { id: 'pdf', file: 'bench_pdf.pdf', kind: 'rawfile', bytes: 0, raw: '微舆.pdf' },
  { id: 'demo', file: 'bench_demo.txt', kind: 'rawfile', bytes: 0, raw: 'demo.txt' }
];

/** 递归删除目录（失败静默） */
function removeRecursive(dir: string): void {
  let entries: string[] = [];
  try { entries = fileIo.listFileSync(dir); } catch (_e) { return; }
  for (let i = 0; i < entries.length; i++) {
    const p: string = dir + '/' + entries[i];
    try {
      const st: fileIo.Stat = fileIo.statSync(p);
      if (st.isDirectory()) { removeRecursive(p); } else { fileIo.unlinkSync(p); }
    } catch (_e) { }
  }
  try { fileIo.rmdirSync(dir); } catch (_e) { }
}

function writeBytes(path: string, bytes: Uint8Array): void {
  const f: fileIo.File = fileIo.openSync(path,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(f.fd, bytes.buffer as ArrayBuffer);
  fileIo.closeSync(f);
}

/** 把 base 循环填充到 targetBytes（合成「大页」；首字节保持合法 PNG 头，首帧可解码） */
function fillTo(base: Uint8Array, targetBytes: number): Uint8Array {
  if (targetBytes <= base.length) { return base; }
  const out: Uint8Array = new Uint8Array(targetBytes);
  let off: number = 0;
  while (off < targetBytes) {
    const n: number = Math.min(base.length, targetBytes - off);
    out.set(base.subarray(0, n), off);
    off += n;
  }
  return out;
}

/** 固定段落模板（长度 > 900 字符，保证每章多页）；内容确定性，便于横向对比 */
function makeParagraph(seed: number): string {
  let s: string = '第' + String((seed % 89) + 1) + '段　' +
    '这是用于阅读引擎性能基准测试的中文段落，包含全角标点、半角数字 12345 与 latin token。';
  while (s.length < 900) {
    s = s + '补足文字补足内容以形成长段落。';
  }
  return s;
}

/** 程序化生成 TXT：按字节数写满（确定性、可复现） */
function genTxtBook(path: string, bytes: number): number {
  const enc: util.TextEncoder = new util.TextEncoder();
  const f: fileIo.File = fileIo.openSync(path,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  let written: number = 0;
  let chapter: number = 0;
  while (written < bytes) {
    chapter++;
    let block: string = '第' + String(chapter) + '章　基准测试章节标题\n\n';
    for (let p = 0; p < 12; p++) {
      block = block + makeParagraph(chapter * 12 + p) + '\n\n';
    }
    fileIo.writeSync(f.fd, block);
    written += enc.encodeInto(block).length;
  }
  fileIo.closeSync(f);
  return written;
}

/** 从 entry 模块 rawfile 释放到目标路径 */
function copyRawFile(entryCtx: common.Context, raw: string, path: string): number {
  const data: Uint8Array = entryCtx.resourceManager.getRawFileContentSync(raw);
  writeBytes(path, data);
  return data.length;
}

/**
 * 设备内合成大 CBZ：rawfile 取一张合法 PNG → 复制为 N 页（每页填充到 pageBytes）
 * → zlib.zipFile 打包 → 清理中间目录（不占用户存储）。
 */
async function genLargeCbz(entryCtx: common.Context, raw: string, target: string,
  pages: number, pageBytes: number): Promise<number> {
  const base: Uint8Array = entryCtx.resourceManager.getRawFileContentSync(raw);
  const work: string = target + '.work';
  removeRecursive(work);
  try { fileIo.mkdirSync(work, true); } catch (_e) { }
  let total: number = 0;
  for (let i = 1; i <= pages; i++) {
    const name: string = 'page' + String(i).padStart(3, '0') + '.png';
    const bytes: Uint8Array = i === 1 ? base : fillTo(base, pageBytes);
    writeBytes(work + '/' + name, bytes);
    total += bytes.length;
  }
  // zlib.zipFile 自 API 9 起废弃且要求 .zip 扩展名（传 .cbz 会被静默忽略）→ compressFile + 改名
  const zipPath: string = target + '.zip';
  try { fileIo.unlinkSync(zipPath); } catch (_e) { }
  await zlib.compressFile(work, zipPath, {});
  try { fileIo.copyFileSync(zipPath, target); } catch (_e) { }
  try { fileIo.unlinkSync(zipPath); } catch (_e) { }
  const size: number = fileIo.statSync(target).size;
  removeRecursive(work);
  hilog.info(DOMAIN, TAG, 'BENCH_CORPUS_CBZ_GEN pages=%{public}d unpacked=%{public}d zip=%{public}d',
    pages, total, size);
  return size;
}

/** 目录可写性探针（mkdirSync 对「已存在目录」会抛错，不能作为可用判据） */
function probeWritable(dir: string): boolean {
  const probe: string = dir + '/.bench_probe';
  try {
    const f: fileIo.File = fileIo.openSync(probe,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, 'x');
    fileIo.closeSync(f);
    fileIo.unlinkSync(probe);
    return true;
  } catch (_e) {
    return false;
  }
}

export default function benchCorpusTest() {
  describe('BenchCorpusTest', () => {

    it('inject_corpus_into_reader_books_dir', 0, async () => {
      const appCtx: common.Context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext();
      const entryCtx: common.Context = appCtx.createModuleContext('entry');
      // 阅读器读写的是 UIAbilityContext.filesDir = <el2 base>/haps/entry/files。
      // 测试进程里 createModuleContext('entry').filesDir 在本环境返回应用级
      // <el2 base>/files，因此按「模块级路径优先 → 其它候选回退」解析。
      const appFiles: string = appCtx.filesDir;
      const moduleFiles: string = appFiles.indexOf('/haps/') >= 0
        ? appFiles
        : appFiles.replace('/files', '/haps/entry/files');
      const candidates: string[] = [
        moduleFiles + BOOKS_SUBDIR,
        entryCtx.filesDir + BOOKS_SUBDIR,
        appFiles + BOOKS_SUBDIR
      ];
      let booksDir: string = '';
      for (let c = 0; c < candidates.length; c++) {
        try { fileIo.mkdirSync(candidates[c], true); } catch (_e) { }
        if (booksDir === '' && probeWritable(candidates[c])) { booksDir = candidates[c]; }
      }
      if (booksDir === '') {
        hilog.error(DOMAIN, TAG, 'BENCH_CORPUS_NO_WRITABLE_DIR c0=%{public}s c1=%{public}s',
          candidates[0], candidates[1]);
        expect(booksDir).assertEqual('non-empty');
        return;
      }
      // 幂等：清掉旧语料与旧解压产物，避免旧数据干扰对比
      for (let c = 0; c < candidates.length; c++) {
        for (let s = 0; s < CORPUS.length; s++) {
          const p: string = candidates[c] + '/' + CORPUS[s].file;
          try { fileIo.unlinkSync(p); } catch (_e) { }
          removeRecursive(p + '_extracted');
          removeRecursive(p + '.extracted');
        }
      }
      hilog.info(DOMAIN, TAG, 'BENCH_CORPUS_START dir=%{public}s appFiles=%{public}s',
        booksDir, appFiles);

      const t0: number = Date.now();
      let ok: number = 0;
      let totalBytes: number = 0;
      for (let i = 0; i < CORPUS.length; i++) {
        const spec: CorpusSpec = CORPUS[i];
        const target: string = booksDir + '/' + spec.file;
        const tStart: number = Date.now();
        let written: number = 0;
        let err: string = '';
        try {
          if (spec.kind === 'txt-gen') {
            written = genTxtBook(target, spec.bytes);
          } else if (spec.kind === 'cbz-gen') {
            written = await genLargeCbz(entryCtx, spec.raw, target,
              spec.pages !== undefined ? spec.pages : 200,
              spec.pageBytes !== undefined ? spec.pageBytes : 1572864);
          } else {
            written = copyRawFile(entryCtx, spec.raw, target);
          }
          ok++;
          totalBytes += written;
        } catch (e) {
          err = String(e);
        }
        hilog.info(DOMAIN, TAG,
          'BENCH_CORPUS id=%{public}s file=%{public}s bytes=%{public}d ms=%{public}d err=%{public}s',
          spec.id, spec.file, written, Date.now() - tStart, err);
      }
      const totalMs: number = Date.now() - t0;
      hilog.info(DOMAIN, TAG,
        'BENCH_CORPUS_DONE dir=%{public}s count=%{public}d totalBytes=%{public}d ms=%{public}d',
        booksDir, ok, totalBytes, totalMs);
      expect(ok).assertEqual(CORPUS.length);
    });

  });
}
