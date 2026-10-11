#!/usr/bin/env node
/**
 * make_corpus.mjs — 生成 OhEngine 标准 Bench 语料
 *
 * 便携：只依赖 tests/bench/corpus.json + 项目根已有书籍；输出到 tests/bench/corpus/。
 * 本机（macOS/Linux）生成 → 由 run_bench.sh 推送到设备；TXT 超大档在设备内生成
 * （见 --stage=planned 输出，供 ohosTest 用）。
 *
 * 用法: node tests/bench/make_corpus.mjs [--only <id,...>] [--force]
 */
import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync, copyFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const OUT = join(HERE, 'corpus');
mkdirSync(OUT, { recursive: true });

const args = process.argv.slice(2);
const onlyArg = args.find(a => a.startsWith('--only'));
const only = onlyArg ? (args[args.indexOf(onlyArg) + 1] || '').split(',').filter(Boolean) : [];
const force = args.includes('--force');

const spec = JSON.parse(readFileSync(join(HERE, 'corpus.json'), 'utf8'));
const rows = [];

/** 按字节截断 UTF-8 文本，并对齐到段落边界（\\n\\n） */
function sliceAligned(buf, bytes) {
  if (buf.length <= bytes) return buf;
  let end = bytes;
  // 向前找最近的段落边界（0x0A 0x0A）
  for (let i = bytes; i > Math.max(0, bytes - 4096); i--) {
    if (buf[i - 1] === 0x0a && buf[i] === 0x0a) { end = i + 1; break; }
    if (buf[i - 1] === 0x0a && buf[i] === 0x0d) { end = i + 1; break; }
  }
  return buf.subarray(0, end);
}

/** 循环拼接源文本直到 >= bytes，再对齐段落边界 */
function repeatAligned(srcBuf, bytes) {
  const out = Buffer.alloc(bytes + 4096);
  let off = 0;
  while (off < bytes) {
    const n = Math.min(srcBuf.length, bytes + 4096 - off);
    srcBuf.copy(out, off, 0, n);
    off += n;
  }
  return sliceAligned(out.subarray(0, bytes + 4096), bytes);
}

function genTxt(sample) {
  const from = join(ROOT, sample.gen.from);
  if (!existsSync(from)) throw new Error(`源文件缺失: ${from}`);
  const src = readFileSync(from);
  const bytes = sample.gen.bytes;
  const buf = sample.gen.repeat ? repeatAligned(src, bytes) : sliceAligned(src, bytes);
  const target = join(OUT, sample.target);
  writeFileSync(target, buf);
  return { target, size: buf.length };
}

function genCbz(sample) {
  const globDir = join(ROOT, dirname(sample.gen.images));
  const base = sample.gen.images.split('/').pop();
  const ext = base.replace('*', '');
  const imgs = readdirSync(globDir).filter(f => f.endsWith(ext)).sort().slice(0, sample.gen.limit);
  if (imgs.length === 0) throw new Error(`CBZ 图片素材缺失: ${globDir}/*${ext}`);
  const stage = join(OUT, '.cbz-stage');
  mkdirSync(stage, { recursive: true });
  imgs.forEach((f, i) => copyFileSync(join(globDir, f), join(stage, String(i + 1).padStart(3, '0') + ext)));
  const target = join(OUT, sample.target);
  try { execFileSync('rm', ['-f', target]); } catch (_e) { }
  execFileSync('zip', ['-q', '-r', '-X', target, '.'], { cwd: stage });
  return { target, size: statSync(target).size, files: imgs.length };
}

for (const s of spec.samples) {
  if (only.length > 0 && !only.includes(s.id)) continue;
  if (s.optional && !args.includes('--with-optional') && only.length === 0) continue;
  const target = join(OUT, s.target);
  try {
    if (!force && existsSync(target) && s.mode !== 'generated') {
      rows.push({ id: s.id, target: s.target, size: statSync(target).size, note: 'cached' });
      continue;
    }
    let r;
    if (s.mode === 'copy') {
      const src = join(ROOT, s.source);
      if (!existsSync(src)) throw new Error(`源文件缺失: ${src}`);
      copyFileSync(src, target);
      r = { target, size: statSync(target).size };
    } else if (s.format === 'txt') {
      r = genTxt(s);
    } else if (s.format === 'cbz') {
      r = genCbz(s);
    } else {
      throw new Error(`未支持的生成模式: ${s.id}`);
    }
    rows.push({ id: s.id, target: s.target, size: r.size, note: 'generated', files: r.files });
  } catch (e) {
    rows.push({ id: s.id, target: s.target, error: String(e.message || e) });
  }
}

console.log('id            file                     bytes        note');
for (const r of rows) {
  const size = r.size !== undefined ? String(r.size).padStart(11) : '          -';
  console.log(`${(r.id || '').padEnd(13)} ${String(r.target).padEnd(24)} ${size}  ${r.error ? 'ERROR: ' + r.error : r.note}`);
}
const ok = rows.filter(r => !r.error).length;
console.log(`\n语料目录: ${OUT}`);
console.log(`完成 ${ok}/${rows.length}`);
if (rows.some(r => r.error)) process.exit(1);
