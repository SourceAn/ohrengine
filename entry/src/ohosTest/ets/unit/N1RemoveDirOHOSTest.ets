/**
 * N1RemoveDirOHOSTest — 只读核查用探针（无产品逻辑改动）
 *
 * 目的：在真机沙箱内实证以下两点（对应审计 N1 假设）：
 *   A. 发货函数 `removeDirRecursive`（ohrengine-reader/utils/FileUtils.ets）
 *      对一个"非空目录"调用后，是否真的删除了内容/目录本身。
 *   B. `fileIo.mkdirSync(existingDir, true)` 在目录已存在时是否抛错。
 *   C. `fileIo.listFileSync(dir)` 返回的是"文件名"还是"绝对路径"（用于判定
 *      FileUtils.ets:42 `statSync(entry)` 是否漏拼目录前缀）。
 *
 * 全部结论以 hilog（tag=N1PROBE）原始输出为准，不依赖断言消息。
 */
import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { removeDirRecursive } from 'ohrengine-reader';

const DOMAIN: number = 0x0000;
const TAG: string = 'N1PROBE';
const BASE: string = '/data/storage/el2/base/haps/entry/files';

function n1Exists(path: string): boolean {
  try {
    fileIo.statSync(path);
    return true;
  } catch (_e) {
    return false;
  }
}

function n1WriteText(path: string, content: string): void {
  const f: fileIo.File = fileIo.openSync(path,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(f.fd, content);
  fileIo.closeSync(f);
}

/** 已知正确的递归删除（对照组：显式拼接 dir + '/' + name） */
function n1CorrectRemove(dir: string): void {
  let entries: string[] = [];
  try {
    entries = fileIo.listFileSync(dir);
  } catch (_e) {
    return;
  }
  for (let i = 0; i < entries.length; i++) {
    const p: string = dir + '/' + entries[i];
    let st: fileIo.Stat | null = null;
    try {
      st = fileIo.statSync(p);
    } catch (_e) {
      continue;
    }
    if (st.isDirectory()) {
      n1CorrectRemove(p);
    } else {
      try {
        fileIo.unlinkSync(p);
      } catch (_e) { /* ignore */ }
    }
  }
  try {
    fileIo.rmdirSync(dir);
  } catch (_e) { /* ignore */ }
}

export default function n1RemoveDirTest() {
  describe('N1RemoveDirTest', () => {

    // A. 对非空目录调用发货版 removeDirRecursive
    it('probeA_removeDirRecursive_nonempty', 0, () => {
      const dir: string = BASE + '/n1_probe_' + Date.now();
      try {
        fileIo.mkdirSync(dir, true);
        fileIo.mkdirSync(dir + '/sub', true);
        n1WriteText(dir + '/a.txt', 'aaa');
        n1WriteText(dir + '/sub/b.txt', 'bbb');

        const before: string[] = fileIo.listFileSync(dir);
        hilog.info(DOMAIN, TAG, 'A-before dirExists=%{public}d entries=[%{public}s]',
          n1Exists(dir) ? 1 : 0, before.join(','));

        removeDirRecursive(dir);

        const dirAfter: boolean = n1Exists(dir);
        const aAfter: boolean = n1Exists(dir + '/a.txt');
        const subAfter: boolean = n1Exists(dir + '/sub');
        const subFileAfter: boolean = n1Exists(dir + '/sub/b.txt');
        hilog.info(DOMAIN, TAG,
          'A-after  dirExists=%{public}d aTxt=%{public}d subDir=%{public}d subFile=%{public}d',
          dirAfter ? 1 : 0, aAfter ? 1 : 0, subAfter ? 1 : 0, subFileAfter ? 1 : 0);

        // 正确行为应为：目录连同内容被删除（dirAfter=false）
        expect(dirAfter).assertFalse();
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'A-exception %{public}s', String(e));
        expect(0).assertEqual(1);
      } finally {
        n1CorrectRemove(dir);
      }
    });

    // B. mkdirSync(existingDir, true) 是否抛错
    it('probeB_mkdirSync_existing', 0, () => {
      const dir: string = BASE + '/n1_mkdir_' + Date.now();
      let threw: boolean = false;
      let msg: string = '';
      try {
        fileIo.mkdirSync(dir, true);   // 首次：目录不存在
        fileIo.mkdirSync(dir, true);   // 二次：目录已存在（待观察）
      } catch (e) {
        threw = true;
        msg = String(e);
      }
      hilog.info(DOMAIN, TAG, 'B mkdirSync(existing,recursive=true) threw=%{public}d msg=[%{public}s]',
        threw ? 1 : 0, msg);
      // 只记录事实，不预设结论
      expect(true).assertTrue();
      n1CorrectRemove(dir);
    });

    // C. listFileSync 返回形态 + 对照组删除能力自检
    it('probeC_listFileSync_and_control', 0, () => {
      const dir: string = BASE + '/n1_list_' + Date.now();
      try {
        fileIo.mkdirSync(dir, true);
        n1WriteText(dir + '/x.txt', 'x');
        const names: string[] = fileIo.listFileSync(dir);
        const firstAbsolute: boolean = names.length > 0 && names[0].startsWith('/');
        hilog.info(DOMAIN, TAG, 'C listFileSync -> [%{public}s] firstAbsolute=%{public}d',
          names.join(','), firstAbsolute ? 1 : 0);

        n1CorrectRemove(dir);
        const stillThere: boolean = n1Exists(dir);
        hilog.info(DOMAIN, TAG, 'C control(correctRemove) dirExists=%{public}d', stillThere ? 1 : 0);
        // 对照组：正确拼接路径必须删除成功（证明探针环境可删）
        expect(stillThere).assertFalse();
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'C-exception %{public}s', String(e));
        expect(0).assertEqual(1);
      } finally {
        n1CorrectRemove(dir);
      }
    });

    // D. 裸文件名 statSync/unlinkSync 的解析语义
    it('probeD_relative_name_semantics', 0, () => {
      const dir: string = BASE + '/n1_rel_' + Date.now();
      try {
        fileIo.mkdirSync(dir, true);
        n1WriteText(dir + '/a.txt', 'rr');
        const rootHasA: boolean = n1Exists(BASE + '/a.txt');
        let sThrew: boolean = false; let sMsg: string = '';
        try { fileIo.statSync('a.txt'); } catch (e) { sThrew = true; sMsg = String(e); }
        let uThrew: boolean = false; let uMsg: string = '';
        try { fileIo.unlinkSync('a.txt'); } catch (e) { uThrew = true; uMsg = String(e); }
        hilog.info(DOMAIN, TAG,
          'D rootHasATxt=%{public}d statSync("a.txt")threw=%{public}d[%{public}s] unlinkSync("a.txt")threw=%{public}d[%{public}s] childStillThere=%{public}d',
          rootHasA ? 1 : 0, sThrew ? 1 : 0, sMsg, uThrew ? 1 : 0, uMsg, n1Exists(dir + '/a.txt') ? 1 : 0);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'D-exception %{public}s', String(e));
      } finally {
        n1CorrectRemove(dir);
      }
      expect(true).assertTrue();
    });

    // E. 逐字复制 FileUtils 的"裸名"写法并逐步观测（不借助任何其它删除方）
    it('probeE_inline_bare_recursion', 0, () => {
      const dir: string = BASE + '/n1_inline_' + Date.now();
      try {
        fileIo.mkdirSync(dir, true);
        fileIo.mkdirSync(dir + '/sub', true);
        n1WriteText(dir + '/a.txt', 'a');
        n1WriteText(dir + '/sub/b.txt', 'b');
        const entries: string[] = fileIo.listFileSync(dir);
        hilog.info(DOMAIN, TAG, 'E entries=[%{public}s]', entries.join(','));
        for (let i = 0; i < entries.length; i++) {
          const entry: string = entries[i];
          let ok: boolean = true; let m: string = '';
          try { fileIo.statSync(entry); } catch (e) { ok = false; m = String(e); }
          hilog.info(DOMAIN, TAG, 'E statSync("%{public}s") ok=%{public}d msg=[%{public}s]',
            entry, ok ? 1 : 0, m);
        }
        removeDirRecursive(dir);
        hilog.info(DOMAIN, TAG, 'E after shipped removeDirRecursive dirExists=%{public}d',
          n1Exists(dir) ? 1 : 0);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'E-exception %{public}s', String(e));
      } finally {
        n1CorrectRemove(dir);
      }
      expect(true).assertTrue();
    });

    // F. 单独验证 rmdirSync 对"非空目录"的行为（解释 A/C/E 的删除来源）
    it('probeF_rmdirSync_nonempty', 0, () => {
      const dir: string = BASE + '/n1_rmdir_' + Date.now();
      try {
        fileIo.mkdirSync(dir, true);
        fileIo.mkdirSync(dir + '/sub', true);
        n1WriteText(dir + '/a.txt', 'a');
        n1WriteText(dir + '/sub/b.txt', 'b');
        let threw: boolean = false; let msg: string = '';
        try { fileIo.rmdirSync(dir); } catch (e) { threw = true; msg = String(e); }
        hilog.info(DOMAIN, TAG,
          'F rmdirSync(nonempty) threw=%{public}d msg=[%{public}s] dirExists=%{public}d',
          threw ? 1 : 0, msg, n1Exists(dir) ? 1 : 0);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'F-exception %{public}s', String(e));
      } finally {
        n1CorrectRemove(dir);
      }
      expect(true).assertTrue();
    });
  });
}
