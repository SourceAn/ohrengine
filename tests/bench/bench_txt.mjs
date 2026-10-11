#!/usr/bin/env node
/**
 * 桌面参考基准：TXT 分块读取 + 空行分章（与 TxtParser 同算法，ENG-004/ENG-011）
 *
 * 注意：这是桌面 Node 参考测量，不是 HarmonyOS 真机测量，不可作为真机性能数据。
 */
import { readFileSync, statSync } from 'node:fs';
import { TextDecoder } from 'node:util';

const file = process.argv[2] || '/Users/a123456/Code/Harmony/ohrengine/《一念永恒》（校对版全本）.txt';
const CHUNK = 256 * 1024;

function readChunked(path) {
  const bytes = readFileSync(path);
  const decoder = new TextDecoder('utf-8');
  const parts = [];
  let pos = 0;
  while (pos < bytes.length) {
    const end = Math.min(bytes.length, pos + CHUNK);
    parts.push(decoder.decode(bytes.slice(pos, end), { stream: true }));
    pos = end;
  }
  parts.push(decoder.decode(new Uint8Array(0), { stream: false }));
  return parts.join('');
}

function split(text) {
  const blocks = [];
  const pattern = /\n\s*\n/g;
  let lastEnd = 0;
  let m;
  while ((m = pattern.exec(text)) !== null) {
    const b = text.substring(lastEnd, m.index).trim();
    if (b.length > 0) blocks.push(b);
    lastEnd = m.index + m[0].length;
  }
  const lb = text.substring(lastEnd).trim();
  if (lb.length > 0) blocks.push(lb);
  return blocks;
}

const size = statSync(file).size;
const runs = [];
for (let i = 0; i < 5; i++) {
  const t0 = Date.now();
  const content = readChunked(file);
  const blocks = split(content);
  const t1 = Date.now();
  runs.push(t1 - t0);
  if (i === 0) console.log('size bytes:', size, 'chapters:', blocks.length);
}
runs.sort((a, b) => a - b);
const avg = runs.reduce((a, b) => a + b, 0) / runs.length;
console.log('runs(ms):', runs.join(','));
console.log('avg(ms):', avg.toFixed(1));
console.log('note: desktop node reference only, NOT a HarmonyOS device measurement');
