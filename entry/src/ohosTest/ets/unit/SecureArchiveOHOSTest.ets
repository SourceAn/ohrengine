/**
 * SecureArchiveOhosTest — OhosTest (hypium) unit tests for SecureArchive (SEC-002)
 *
 * Covers: normal archive extraction, non-existent archive rejection,
 *         empty archive rejection, out-of-sandbox rejection,
 *         archive-too-large rejection.
 *
 * Note: 需在真机/模拟器沙箱内运行。恶意样本（路径穿越/符号链接/超量文件）
 * 需外部构造 zip 放入测试沙箱后再解压验证。
 */
import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { SecureArchive } from 'ohrengine-common';

const BASE: string = '/data/storage/el2/base/haps/entry/files';

function writeTextFile(path: string, content: string): void {
  try {
    const f: fileIo.File = fileIo.openSync(path,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, content);
    fileIo.closeSync(f);
  } catch (_e) {
    // 测试辅助：写入失败由断言/后续逻辑暴露
  }
}

function cleanupDir(dir: string): void {
  try {
    const entries: string[] = fileIo.listFileSync(dir);
    for (let i = 0; i < entries.length; i++) {
      const p: string = dir + '/' + entries[i];
      const st: fileIo.Stat = fileIo.statSync(p);
      try {
        if (st.isDirectory()) {
          cleanupDir(p);
        } else {
          try { fileIo.unlinkSync(p); } catch (_e) { /* ignore */ }
        }
      } catch (_e) { /* ignore */ }
    }
    try { fileIo.rmdirSync(dir); } catch (_e) { /* ignore */ }
  } catch (_e) { /* ignore */ }
}

export default function secureArchiveTest() {
  describe('SecureArchiveTest', () => {
    it('extracts_normal_archive', 0, () => {
      const ts: string = String(Date.now());
      const src: string = BASE + '/sec_src_' + ts;
      const out: string = BASE + '/sec_out_' + ts;
      const zip: string = BASE + '/sec_' + ts + '.zip';
      try {
        fileIo.mkdirSync(src, true);
        writeTextFile(src + '/a.txt', 'hello world');
        try {
          fileIo.unlinkSync(zip);
        } catch (_e) { /* ignore */ }
        zlib.compressFile(src, zip, {}).then(() => {
          return SecureArchive.decompressArchive(zip, out, BASE);
        }).then(() => {
          const entries: string[] = fileIo.listFileSync(out);
          expect(entries.length).assertLarger(0);
        }).catch(() => {
          expect(0).assertEqual(1); // normal archive must not be rejected
        });
      } catch (e) {
        expect(0).assertEqual(1);
      } finally {
        cleanupDir(src);
        cleanupDir(out);
        try { fileIo.unlinkSync(zip); } catch (_e) { /* ignore */ }
      }
    });

    it('rejects_nonexistent_archive', 0, () => {
      const out: string = BASE + '/sec_missing_' + Date.now();
      SecureArchive.decompressArchive(BASE + '/does_not_exist.zip', out, BASE)
        .then(() => {
          expect(0).assertEqual(1); // must reject
        }).catch((e: Error) => {
          expect(e instanceof Error).assertTrue();
        });
    });

    it('rejects_empty_archive', 0, () => {
      const ts: string = String(Date.now());
      const zip: string = BASE + '/sec_empty_' + ts + '.zip';
      const out: string = BASE + '/sec_empty_out_' + ts;
      try {
        writeTextFile(zip, '');
        SecureArchive.decompressArchive(zip, out, BASE)
          .then(() => {
            expect(0).assertEqual(1); // must reject
          }).catch((e: Error) => {
            expect(e instanceof Error).assertTrue();
          });
      } catch (e) {
        expect(0).assertEqual(1);
      } finally {
        try { fileIo.unlinkSync(zip); } catch (_e) { /* ignore */ }
      }
    });

    it('rejects_out_of_sandbox_target', 0, () => {
      const ts: string = String(Date.now());
      const zip: string = BASE + '/sec_osb_' + ts + '.zip';
      writeTextFile(zip, 'x');
      // target outside sandbox base → rejected without reading archive
      SecureArchive.decompressArchive(zip, '/tmp/outside/' + ts, BASE)
        .then(() => {
          expect(0).assertEqual(1); // must reject
        }).catch((e: Error) => {
          expect(e instanceof Error).assertTrue();
        });
      try { fileIo.unlinkSync(zip); } catch (_e) { /* ignore */ }
    });

    it('rejects_archive_too_large', 0, () => {
      const ts: string = String(Date.now());
      const zip: string = BASE + '/sec_big_' + ts + '.zip';
      const out: string = BASE + '/sec_big_out_' + ts;
      // 构造一个超过单文件上限的大文件作为压缩源
      const bigSrc: string = BASE + '/sec_big_src_' + ts;
      try {
        fileIo.mkdirSync(bigSrc, true);
        const f: fileIo.File = fileIo.openSync(bigSrc + '/big.bin',
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        const chunk: Uint8Array = new Uint8Array(1024 * 1024); // 1 MB chunk
        for (let i = 0; i < 512; i++) {
          fileIo.writeSync(f.fd, chunk.buffer);
        }
        fileIo.closeSync(f); // 512 MB > maxSingleFileBytes(256MB)
        zlib.compressFile(bigSrc, zip, {}).then(() => {
          return SecureArchive.decompressArchive(zip, out, BASE);
        }).then(() => {
          expect(0).assertEqual(1); // must reject
        }).catch((e: Error) => {
          expect(e instanceof Error).assertTrue();
        });
      } catch (e) {
        expect(0).assertEqual(1);
      } finally {
        cleanupDir(bigSrc);
        cleanupDir(out);
        try { fileIo.unlinkSync(zip); } catch (_e) { /* ignore */ }
      }
    });
  });
}
