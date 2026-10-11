/**
 * TxtProfOHOSTest — TXT 首次索引构建性能归因（TEMP，20261011）
 *
 * 只测量，不改产品行为。测量走生产路径：
 *   TxtDocument.open() → TxtIndexBuilderTask.buildInTaskPool()（TaskPool worker）。
 * worker 与主线程是不同 VM，故实验开关经固定磁盘配置文件传给 worker
 * （TxtProfile 读取 /data/storage/el2/base/haps/entry/files/txtprof.json）。
 *
 * 语料：设备内已注入的 bench_txt_m.txt（~2.1MB）与 bench_txt_l.txt（~7.8MB）。
 * 每个 (文件 × 实验) 跑 3 次；worker 侧指标经 hilog(tag=TXTPROF) 输出。
 */
import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TxtDocument } from 'ohrengine-txt-exclusive';

const DOMAIN: number = 0x0000;
const TAG: string = 'TXTPROFTEST';
const BASE: string = '/data/storage/el2/base/haps/entry/files';
const CONFIG: string = BASE + '/txtprof.json';
const BOOKS: string = BASE + '/books';
const REPS: number = 3;

const FILES: string[] = ['bench_txt_m.txt', 'bench_txt_l.txt'];
const EXPS: string[] = ['E0', 'E1', 'E2', 'E3', 'E4', 'E5'];

interface ProfRun {
  wall: number;
  jsonLen: number;
  json: string;
  ok: boolean;
}

function writeConfig(mode: string, noYield: boolean, pass1EarlyExit: boolean, collectSamples: boolean): void {
  const json: string = '{"enabled":true,"mode":"' + mode + '"'
    + ',"noYield":' + (noYield ? 'true' : 'false')
    + ',"pass1EarlyExit":' + (pass1EarlyExit ? 'true' : 'false')
    + ',"collectSamples":' + (collectSamples ? 'true' : 'false')
    + ',"sampleLimit":10000,"benchRounds":3}';
  let f: fileIo.File | null = null;
  try {
    f = fileIo.openSync(CONFIG, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, json);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'TXTPROF_CFG_ERR %{public}s', String(e));
  } finally {
    if (f !== null) {
      try { fileIo.closeSync(f); } catch (_e) { }
    }
  }
}

async function runOnce(fname: string, mode: string, noYield: boolean,
  pass1EarlyExit: boolean, collectSamples: boolean, tag: string): Promise<ProfRun> {
  const base: string = fname.substring(0, fname.lastIndexOf('.'));
  const cacheDir: string = BASE + '/prof/' + base + '/' + tag;
  try { fileIo.mkdirSync(cacheDir, true); } catch (_e) { }
  try { fileIo.unlinkSync(cacheDir + '/txt-index-v2.json'); } catch (_e) { }
  writeConfig(mode, noYield, pass1EarlyExit, collectSamples);
  const t0: number = Date.now();
  let ok: boolean = false;
  try {
    const doc: TxtDocument | undefined = await TxtDocument.open(BOOKS + '/' + fname, cacheDir);
    ok = doc !== undefined;
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'TXTPROF_TEST_ERR %{public}s', fname + ' ' + mode + ' ' + String(e));
  }
  const wall: number = Date.now() - t0;
  let j: string = '';
  try { j = fileIo.readTextSync(cacheDir + '/txt-index-v2.json'); } catch (_e) { }
  hilog.info(DOMAIN, TAG, 'TXTPROF_TEST file=%{public}s mode=%{public}s tag=%{public}s wallMs=%{public}d ok=%{public}d jsonLen=%{public}d',
    fname, mode, tag, wall, ok ? 1 : 0, j.length);
  const run: ProfRun = { wall: wall, jsonLen: j.length, json: j, ok: ok };
  return run;
}

function countNewlines(fname: string): void {
  const path: string = BOOKS + '/' + fname;
  let lf: number = 0;
  let crlf: number = 0;
  let loneCr: number = 0;
  let total: number = 0;
  let prevCr: boolean = false;
  let f: fileIo.File | null = null;
  try {
    f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const CH: number = 1024 * 1024;
    const buf: Uint8Array = new Uint8Array(CH);
    let off: number = 0;
    while (true) {
      const n: number = fileIo.readSync(f.fd, buf.buffer, { offset: off, length: CH });
      if (n <= 0) { break; }
      total += n;
      for (let i: number = 0; i < n; i++) {
        const b: number = buf[i];
        if (b === 0x0A) {
          lf++;
          if (prevCr) { crlf++; }
          prevCr = false;
        } else {
          if (prevCr) { loneCr++; }
          prevCr = (b === 0x0D);
        }
      }
      off += n;
    }
    if (prevCr) { loneCr++; }
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'TXTPROF_E6_ERR %{public}s', String(e));
  } finally {
    if (f !== null) {
      try { fileIo.closeSync(f); } catch (_e) { }
    }
  }
  hilog.info(DOMAIN, TAG,
    'TXTPROF_E6 file=%{public}s bytes=%{public}d lf=%{public}d crlf=%{public}d lfNotPrecededByCr=%{public}d loneCr=%{public}d splitByLfLines=%{public}d',
    fname, total, lf, crlf, lf - crlf, loneCr, lf + 1);
}

async function runAll(): Promise<void> {
  countNewlines('bench_txt_m.txt');
  countNewlines('bench_txt_l.txt');
  for (let fi: number = 0; fi < FILES.length; fi++) {
    const fname: string = FILES[fi];
    let e0json: string = '';
    for (let ei: number = 0; ei < EXPS.length; ei++) {
      const mode: string = EXPS[ei];
      for (let rep: number = 0; rep < REPS; rep++) {
        let noYield: boolean = false;
        let pass1EarlyExit: boolean = false;
        let collectSamples: boolean = false;
        if (mode === 'E1') { noYield = true; }
        if (mode === 'E4') { collectSamples = true; }
        if (mode === 'E5') { pass1EarlyExit = true; }
        const tag: string = mode + '_r' + rep;
        const r: ProfRun = await runOnce(fname, mode, noYield, pass1EarlyExit, collectSamples, tag);
        if (mode === 'E0' && e0json.length === 0) { e0json = r.json; }
        if (mode === 'E5') {
          const same: boolean = r.json === e0json;
          hilog.info(DOMAIN, TAG, 'TXTPROF_E5CHECK file=%{public}s rep=%{public}d e5Len=%{public}d e0Len=%{public}d equal=%{public}d',
            fname, rep, r.json.length, e0json.length, same ? 1 : 0);
        }
      }
    }
  }
  hilog.info(DOMAIN, TAG, 'TXTPROF_RUNALL_DONE');
}

export default function txtProfTest() {
  describe('TxtProfTest', () => {
    it('run_all', 0, async () => {
      await runAll();
      expect(true).assertTrue();
    });
  });
}
