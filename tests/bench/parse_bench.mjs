#!/usr/bin/env node
/**
 * parse_bench.mjs — 把 run_bench.sh 采到的 hilog 解析为标准指标表
 *
 * 输入: <runDir>/logs/*.txt （hdc shell hilog -x 原始输出）
 * 输出: <runDir>/metrics.json + <runDir>/report.md
 *
 * 口径见 tests/bench/README.md §指标口径（全部数值取自应用内埋点，不做定性描述）。
 */
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';

const runDir = process.argv[2];
if (!runDir || !existsSync(runDir)) { console.error('用法: node parse_bench.mjs <runDir>'); process.exit(2); }
const logsDir = join(runDir, 'logs');

/** 单条日志的解析规则：正则捕获组 → 指标字段 */
const RULES = [
  { key: 'openMs',         re: /CacheStats\[([^\]]*)\]\s*(.*?)\s*openMs=(\d+)\s+restoreMs=(\d+)\s+txtLazyIdxMs=(\d+)/ },
  { key: 'cacheStats',     re: /CacheStats\[([^\]]*)\]\s*(.*?)\s*openMs=/ },
  { key: 't_anchor',       re: /COLDSTART ANCHOR_RESOLVED page=(\d+) ch=(\d+) ready=(\d+) gen=(\d+)/ },
  { key: 't_firstFrame',   re: /COLDSTART FIRST_FRAME page=(\d+) gen=(\d+)/ },
  { key: 'bgReflow',       re: /COLDSTART BACKGROUND_REFLOW_START queued=(\d+) total=(\d+)/ },
  { key: 'bgChapter',      re: /COLDSTART BACKGROUND_CHAPTER ch=(\d+) ms=(\d+)/ },
  { key: 'bgEnd',          re: /COLDSTART BACKGROUND_REFLOW_END/ },
  { key: 'layoutChapter',  re: /LAYOUT_CHAPTER ch=(\d+) parse=(\d+)ms layout=(\d+)ms split=(\d+)ms commit=(\d+)ms total=(\d+)ms/ },
  { key: 'layoutWorker',   re: /LAYOUT_WORKER_END ch=(\d+) exec=(\d+)ms deser=(\d+)ms jsonParse=(\d+)ms rebuild=(\d+)ms/ },
  { key: 'openTotal',      re: /OPEN_TOTAL page=(\d+) total=(\d+)/ },
  { key: 'txtLazyOpen',    re: /TXT-LAZY open chapters=(\d+) vchs=(\d+) idx=size=(\d+)/ },
  { key: 'txtReflow',      re: /TXTREFLOW after-reflow totalPages=(\d+)/ },
  { key: 'jumpRequest',    re: /JUMP_REQUEST target=(\d+) ready=(\d+) gen=(\d+)/ },
  { key: 'flip',           re: /finishFlip[^f]*frames=(\d+)\s+avgMs=([\d.]+)\s+maxMs=([\d.]+)/ },
  { key: 'sessionOpen',    re: /SESSION_OPEN id=(\d+) book=(\S+)/ },
  { key: 'sessionInit',    re: /SESSION_INIT_(START|SUCCESS|FAIL)/ },
  { key: 'block',          re: /THREAD_BLOCK|APPFREEZE|NotifyAppFault|appfreeze_inner/ },
  { key: 'crash',          re: /APPCRASH|ProcessExit|Processexit|Fatal error/ },
];

const tsRe = /^(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.(\d{3})/;

function tsMs(line) {
  const m = tsRe.exec(line);
  if (!m) return null;
  const [, mo, d, h, mi, s, ms] = m;
  return Date.UTC(2026, Number(mo) - 1, Number(d), Number(h), Number(mi), Number(s), Number(ms));
}

const files = existsSync(logsDir) ? readdirSync(logsDir).filter(f => f.endsWith('.txt')).sort() : [];
const perRun = [];

for (const f of files) {
  const raw = readFileSync(join(logsDir, f), 'utf8');
  const lines = raw.split('\n');
  const r = { file: f, id: f.replace(/-\w+\.txt$/, ''), scenario: (f.match(/-(\w+)\.txt$/) || [])[1] || '?', lines: lines.length };

  // ---- 场景时间线：以 SESSION_OPEN 起点为 T0（设备侧埋点时间，避免主机时钟偏差）
  let t0 = null;
  const marks = {};
  const agg = { layoutChapterTotalMs: [], bgChapterMs: [], layoutWorkerExecMs: [], flipFrames: [], flipAvgMs: [], flipMaxMs: [] };
  const counters = {};
  let blocks = 0, crashes = 0;

  for (const line of lines) {
    if (!line.trim()) continue;
    if (/SESSION_OPEN/.test(line) && t0 === null) t0 = tsMs(line);
    for (const rule of RULES) {
      const m = rule.re.exec(line);
      if (!m) continue;
      counters[rule.key] = (counters[rule.key] || 0) + 1;
      switch (rule.key) {
        case 'openMs':       r.openMs = Number(m[3]); r.restoreMs = Number(m[4]); r.txtLazyIdxMs = Number(m[5]); r.cacheTag = m[1]; break;
        case 'cacheStats':   r.cacheStats = (m[2] || '').slice(0, 160); break;
        case 't_anchor':     marks.anchor = tsMs(line); r.anchorPage = Number(m[1]); r.anchorReady = Number(m[3]); break;
        case 't_firstFrame': marks.firstFrame = tsMs(line); r.firstFramePage = Number(m[1]); break;
        case 'bgReflow':     r.bgQueued = Number(m[1]); r.bgTotal = Number(m[2]); marks.bgStart = tsMs(line); break;
        case 'bgChapter':    agg.bgChapterMs.push(Number(m[2])); break;
        case 'bgEnd':        marks.bgEnd = tsMs(line); break;
        case 'layoutChapter':agg.layoutChapterTotalMs.push(Number(m[6])); break;
        case 'layoutWorker': agg.layoutWorkerExecMs = agg.layoutWorkerExecMs || []; agg.layoutWorkerExecMs.push(Number(m[2])); break;
        case 'openTotal':    r.totalPages = Number(m[2]); break;
        case 'txtLazyOpen':  r.chapters = Number(m[1]); r.vchs = Number(m[2]); break;
        case 'txtReflow':    r.reflowTotalPages = Number(m[1]); marks.reflowEnd = tsMs(line); break;
        case 'jumpRequest':  r.jumpTarget = Number(m[1]); r.jumpReady = Number(m[2]); break;
        case 'flip':         agg.flipFrames.push(Number(m[1])); agg.flipAvgMs.push(Number(m[2])); agg.flipMaxMs.push(Number(m[3])); break;
        case 'block':        blocks++; break;
        case 'crash':        crashes++; break;
      }
    }
  }

  // ---- 由设备侧时间戳计算延迟（不依赖主机时钟）
  const rel = (t) => (t !== undefined && t !== null && t0 !== null) ? (t - t0) : null;
  r.t_anchor_ms = rel(marks.anchor);
  r.t_firstFrame_ms = rel(marks.firstFrame);
  r.t_bgStart_ms = rel(marks.bgStart);
  r.t_bgEnd_ms = rel(marks.bgEnd);

  const num = (a) => a.length ? a : null;
  const pct = (a, p) => { if (!a || !a.length) return null; const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(s.length * p))]; };
  const maxOf = (a) => (a && a.length ? Math.max(...a) : null);
  r.layoutChapterMs = { n: agg.layoutChapterTotalMs.length, p50: pct(agg.layoutChapterTotalMs, 0.5), p95: pct(agg.layoutChapterTotalMs, 0.95), max: maxOf(agg.layoutChapterTotalMs) };
  r.bgChapterMs = { n: agg.bgChapterMs.length, p50: pct(agg.bgChapterMs, 0.5), p95: pct(agg.bgChapterMs, 0.95), max: maxOf(agg.bgChapterMs) };
  r.layoutWorkerMs = { n: agg.layoutWorkerExecMs.length, p50: pct(agg.layoutWorkerExecMs, 0.5), p95: pct(agg.layoutWorkerExecMs, 0.95), max: maxOf(agg.layoutWorkerExecMs) };
  r.flip = { n: agg.flipFrames.length, avgMsP50: pct(agg.flipAvgMs, 0.5), avgMsP95: pct(agg.flipAvgMs, 0.95), maxMsMax: maxOf(agg.flipMaxMs) };
  r.blocks = blocks; r.crashes = crashes; r.counters = counters;

  perRun.push(r);
}

const metrics = { runDir, generatedAt: new Date().toISOString(), runs: perRun };
writeFileSync(join(runDir, 'metrics.json'), JSON.stringify(metrics, null, 2));

// ---------------------------------------------------------------- Markdown
const fmt = (v) => (v === null || v === undefined ? '—' : String(v));
const md = [];
md.push(`# OhEngine Bench 报告（设备实测）`);
md.push('');
md.push(`> 运行目录：\`${runDir}\`　设备：见 \`meta.json\`　日志：\`logs/\``);
md.push('> 数据来源：hilog 应用内埋点（CacheStats / COLDSTART / LAYOUT_* / OPEN_TOTAL / TXT-LAZY）。');
md.push('');
md.push('## 1 打开路径（每个样例）');
md.push('');
md.push('| 样例 | 场景 | openMs | restoreMs | txtLazyIdxMs | 首帧(ms,设备钟) | 锚点(ms,设备钟) | totalPages | 行数 |');
md.push('|---|---|---|---|---|---|---|---|---|');
for (const r of perRun) {
  md.push(`| ${r.id} | ${r.scenario} | ${fmt(r.openMs)} | ${fmt(r.restoreMs)} | ${fmt(r.txtLazyIdxMs)} | ${fmt(r.t_firstFrame_ms)} | ${fmt(r.t_anchor_ms)} | ${fmt(r.totalPages)} | ${r.lines} |`);
}
md.push('');
md.push('## 2 排版 / Worker 耗时分布');
md.push('');
md.push('| 样例 | 场景 | Worker 排版 n | p50(ms) | p95(ms) | max(ms) | 后台章 n | p50 | p95 | max |');
md.push('|---|---|---|---|---|---|---|---|---|---|');
for (const r of perRun) {
  const w = r.layoutWorkerMs, b = r.bgChapterMs;
  md.push(`| ${r.id} | ${r.scenario} | ${w.n} | ${fmt(w.p50)} | ${fmt(w.p95)} | ${fmt(w.max)} | ${b.n} | ${fmt(b.p50)} | ${fmt(b.p95)} | ${fmt(b.max)} |`);
}
md.push('');
md.push('## 3 翻页动画帧耗时（finishFlip）');
md.push('');
md.push('| 样例 | 场景 | 次数 | avgMs P50 | avgMs P95 | maxMs(Max) |');
md.push('|---|---|---|---|---|---|');
for (const r of perRun) {
  if (!r.flip.n) continue;
  md.push(`| ${r.id} | ${r.scenario} | ${r.flip.n} | ${fmt(r.flip.avgMsP50)} | ${fmt(r.flip.avgMsP95)} | ${fmt(r.flip.maxMsMax)} |`);
}
md.push('');
md.push('## 4 稳定性');
md.push('');
md.push('| 样例 | 场景 | THREAD_BLOCK/Freeze | 崩溃 | 缓存摘要 |');
md.push('|---|---|---|---|---|');
for (const r of perRun) {
  md.push(`| ${r.id} | ${r.scenario} | ${r.blocks} | ${r.crashes} | ${(r.cacheStats || '—').replace(/\|/g, '/')} |`);
}
md.push('');
md.push('## 5 埋点覆盖（未出现的指标 = 该场景未触发）');
md.push('');
md.push('| 样例 | 场景 | 命中埋点 |');
md.push('|---|---|---|');
for (const r of perRun) {
  md.push(`| ${r.id} | ${r.scenario} | ${Object.entries(r.counters || {}).map(([k, v]) => `${k}×${v}`).join(', ') || '—'} |`);
}
md.push('');
writeFileSync(join(runDir, 'report.md'), md.join('\n'));

console.log(`解析 ${perRun.length} 份日志 → ${join(runDir, 'metrics.json')} + report.md`);
for (const r of perRun) {
  console.log(`  ${r.id.padEnd(14)} ${r.scenario.padEnd(6)} openMs=${fmt(r.openMs).padEnd(6)} firstFrame=${fmt(r.t_firstFrame_ms).padEnd(6)} pages=${fmt(r.totalPages).padEnd(6)} lines=${r.lines}`);
}
