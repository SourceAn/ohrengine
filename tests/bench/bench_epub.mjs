#!/usr/bin/env node
/**
 * 桌面参考基准：EPUB 解压 + container 读取（近似引擎解压路径，ENG-011）
 *
 * 注意：这是桌面 Node/macOS 参考测量，不是 HarmonyOS 真机测量。
 */
import { readFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

const file = process.argv[2] || '/Users/a123456/Code/Harmony/ohrengine/The_Adventures_of_Sherlock_Holmes_by_Arthur_Conan_Doyle.epub';

const runs = [];
for (let i = 0; i < 3; i++) {
  const tmp = mkdtempSync(join(tmpdir(), 'bench_epub_'));
  const t0 = Date.now();
  try {
    execFileSync('ditto', ['-x', '-k', file, tmp]);
  } catch (_e) {
    execFileSync('unzip', ['-qo', file, '-d', tmp]);
  }
  readFileSync(`${tmp}/META-INF/container.xml`, 'utf8');
  const t1 = Date.now();
  runs.push(t1 - t0);
}
runs.sort((a, b) => a - b);
const avg = runs.reduce((a, b) => a + b, 0) / runs.length;
console.log('runs(ms):', runs.join(','));
console.log('avg decompress+container(ms):', avg.toFixed(1));
console.log('note: desktop node/ditto reference only, NOT a HarmonyOS device measurement');
