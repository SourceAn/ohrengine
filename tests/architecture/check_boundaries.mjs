#!/usr/bin/env node
/**
 * check_boundaries.mjs — OHR 架构边界 / 模块拓扑 校验（可执行判据）
 *
 * 覆盖任务 §22：module graph / forbidden imports / leakage / cycles / generic buckets。
 * 只读源码；不改产品代码。允许作为迁移期“当前状态”证据（FAIL ≠ 阻断）。
 *
 * 运行： node tests/architecture/check_boundaries.mjs
 * 退出码：全 PASS=0；否则=1。
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';

const ROOT = process.cwd();
const EXCLUDE = /(^|\/)(build|backup|archive|docs|node_modules|\.hvigor|oh_modules)(\/|$)/;
const MODULES = readdirSync(ROOT).filter((d) => d.startsWith('ohrengine-')).concat(['entry'])
  .filter((d) => statSync(join(ROOT, d)).isDirectory());

function walk(dir, out = []) {
  let es;
  try { es = readdirSync(dir); } catch { return out; }
  for (const e of es) {
    const p = join(dir, e);
    if (EXCLUDE.test('/' + relative(ROOT, p))) continue;
    const st = statSync(p);
    if (st.isDirectory()) walk(p, out);
    else if (p.endsWith('.ets')) out.push(p);
  }
  return out;
}
const files = walk(ROOT);
const rel = (p) => relative(ROOT, p);
const modOf = (f) => MODULES.find((m) => ('/' + rel(f)).includes('/' + m + '/')) || '(other)';

function realLines(file) {
  const out = [];
  readFileSync(file, 'utf8').split('\n').forEach((l, i) => {
    const s = l.trim();
    if (s.startsWith('*') || s.startsWith('//') || s.startsWith('/*')) return;
    out.push({ n: i + 1, l });
  });
  return out;
}
function hits(re, mods) {
  const r = [];
  for (const f of files) if (mods.includes(modOf(f))) for (const { n, l } of realLines(f)) if (re.test(l)) r.push(`${rel(f)}:${n}`);
  return r;
}

// ---- module graph ----
const edges = new Map(MODULES.map((m) => [m, new Set()]));
for (const f of files) {
  const m = modOf(f);
  for (const { l } of realLines(f)) {
    const mm = l.match(/from '(ohrengine-[a-z-]+)'/);
    if (mm && MODULES.includes(mm[1]) && mm[1] !== m) edges.get(m).add(mm[1]);
  }
}
function findCycles() {
  const cyc = [];
  const state = new Map();
  const dfs = (n, stack) => {
    state.set(n, 1); stack.push(n);
    for (const x of edges.get(n) || []) {
      if (!state.get(x)) dfs(x, stack);
      else if (state.get(x) === 1) cyc.push([...stack.slice(stack.indexOf(x)), x].join(' -> '));
    }
    state.set(n, 2); stack.pop();
  };
  for (const m of MODULES) if (!state.get(m)) dfs(m, []);
  return [...new Set(cyc)];
}

const ENGINE = ['ohrengine-ui-render', 'ohrengine-common'];
const FORMAT = ['ohrengine-epub', 'ohrengine-txt-exclusive', 'ohrengine-cbz-exclusive', 'ohrengine-pdf-exclusive'];
const RENDER = ['ohrengine-reader'];
const GENERIC = new Set(['common', 'utils', 'util', 'helpers', 'helper', 'misc', 'manager', 'service', 'base', 'core', 'types', 'model', 'shared', 'support']);

const rules = [
  ['INV-PLATFORM', 'Engine(ui-render/common) 不得 import @kit.*', () => hits(/from '@kit\./, ENGINE)],
  ['INV-UI', 'Engine(ui-render/common) 不得 import @kit.ArkUI 或声明组件', () => hits(/from '@kit\.ArkUI'|@Entry|@Component|^struct /, ENGINE)],
  ['INV-FORMAT-IN-ENGINE', 'Engine 不得 import concrete Format 模块', () => hits(new RegExp("from '(" + FORMAT.join('|') + ")'"), ENGINE)],
  ['INV-COMMON-LEAF', 'ohrengine-common 不得 import 其它模块', () => hits(/from 'ohrengine-[a-z-]+'/, ['ohrengine-common']).filter((h) => !h.includes("'ohrengine-common'"))],
  ['INV-RENDER-FORMAT', 'Renderer(reader) 不得 import format/ParseCache/Navigation', () => hits(/from '(ohrengine-epub|ohrengine-txt-exclusive|ohrengine-pdf-exclusive|ohrengine-cbz-exclusive)'|ParseCacheManager|NavPathStack/, RENDER)],
  ['INV-CYCLES', '模块依赖图不得有环', () => findCycles()],
];

let failed = 0;
console.log('=== OHR module topology / boundary check ===');
console.log(`modules=${MODULES.length} ets=${files.length}\n`);
console.log('module dependency edges:');
for (const m of MODULES) { const d = [...edges.get(m)]; if (d.length) console.log(`  ${m} -> ${d.join(', ')}`); }
console.log('');
for (const [id, desc, fn] of rules) {
  const bad = fn();
  const ok = bad.length === 0;
  if (!ok) failed++;
  console.log(`[${ok ? 'PASS' : 'FAIL'}] ${id} — ${desc}`);
  if (!ok) { bad.slice(0, 10).forEach((b) => console.log(`        ${b}`)); if (bad.length > 10) console.log(`        … (+${bad.length - 10})`); }
}
const genericDirs = (() => {
  const s = new Set();
  for (const f of files) { const parts = rel(f).split('/'); for (const p of parts) if (GENERIC.has(p)) s.add(parts.slice(0, parts.indexOf(p) + 1).join('/')); }
  return [...s];
})();
console.log(`\n=== generic-name dirs (target 0): ${genericDirs.length} ===`);
genericDirs.forEach((g) => console.log('   ' + g));

// ---- platform capability leakage report (任务 §28) ----
function capability(kit, members) {
  if (kit === '@kit.CoreFileKit') return members.includes('picker') ? 'FilePicker' : 'FileSystem';
  if (kit === '@kit.BasicServicesKit') return members.includes('zlib') ? 'Archive(zip)' : (members.includes('commonEventManager') || members.includes('batteryInfo') ? 'SystemEvents/Battery' : 'BasicServices:other');
  if (kit === '@kit.ArkTS') return members.includes('taskpool') ? 'TaskScheduler' : (members.includes('xml') ? 'XmlCodec' : 'TextCodec(util)');
  if (kit === '@kit.PerformanceAnalysisKit') return 'Logger(hilog)';
  if (kit === '@kit.ImageKit') return 'ImageDecoder';
  if (kit === '@kit.ArkUI') return members.includes('font') ? 'FontRegister(ArkUI)' : 'ArkUI/UI';
  if (kit === '@kit.ArkData') return members.includes('relationalStore') ? 'Database' : 'Preferences';
  if (kit === '@kit.NetworkKit') return 'Network(http)';
  if (kit === '@kit.SensorServiceKit') return 'Vibrator/Sensor';
  if (kit === '@kit.InputKit') return 'Input(keys)';
  if (kit === '@kit.AbilityKit') return 'Ability/Context';
  if (kit === '@kit.UIDesignKit') return 'UIDesign(material)';
  if (kit === '@kit.SpeechKit') return 'TTS';
  if (kit === '@kit.TranslationKit') return 'Translation';
  if (kit === 'libliquidglass.so') return 'GLES(native)';
  return kit;
}
const capByLayer = new Map();
for (const f of files) {
  const m = modOf(f);
  const layer = ENGINE.includes(m) ? 'ENGINE' : (FORMAT.includes(m) ? 'FORMAT' : (RENDER.includes(m) ? 'RENDER' : (m === 'entry' ? 'APP' : 'OTHER')));
  for (const { l } of realLines(f)) {
    const mm = l.match(/import\s*\{([^}]*)\}\s*from\s*'(@kit\.[A-Za-z]+|@ohos\.[A-Za-z.]+|libliquidglass\.so)'/);
    if (!mm) continue;
    const cap = capability(mm[2], mm[1]);
    const k = layer + ' :: ' + cap;
    capByLayer.set(k, (capByLayer.get(k) || 0) + 1);
  }
}
console.log('\n=== platform capability usage by layer (leakage) ===');
for (const k of [...capByLayer.keys()].sort()) console.log(`   ${k} : ${capByLayer.get(k)}`);
console.log('   (target: only PLATFORM layer uses OS; ENGINE uses platform-api only)');

console.log(`\nRESULT: ${rules.length - failed}/${rules.length} invariants PASS`);
process.exit(failed === 0 ? 0 : 1);
