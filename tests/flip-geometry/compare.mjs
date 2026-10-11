// 对照测试：STPageFlip 原版算法 vs 我的移植
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { FlipCalculation, FlipDirection, FlipCorner } = require('./orig-out/flipcalc.js');
import { FlipGeometry, FORWARD, BACK, TOP, BOTTOM } from './flip-algo.mjs';

const W = 360, H = 600;
const cases = [
  // [direction(0=FWD,1=BACK), corner(0=TOP,1=BOTTOM), x, y]
  [0, 0, 324, 60], [0, 0, 300, 300], [0, 0, 240, 300], [0, 0, 180, 300], [0, 0, 0, 300],
  [0, 0, -100, 300], [0, 0, -360, 300], [0, 0, -360, 0], [0, 0, 359, 1], [0, 0, 200, 30],
  [0, 1, 260, 540], [0, 1, 100, 550], [0, 1, -200, 600], [0, 1, 300, 200],
  [1, 0, 80, 300], [1, 0, 200, 300], [1, 0, 300, 100], [1, 0, 50, 30],
  [1, 1, 150, 500], [1, 1, 280, 100], [1, 1, -100, 300],
];

let pass = 0, fail = 0;
const cmp = (a, b, eps = 1e-6) => {
  if (a === null || b === null) return a === b;
  return Math.abs(a - b) < eps;
};

for (const [d, c, x, y] of cases) {
  // 原版（方向/角枚举数值相同）
  const orig = new FlipCalculation(d, c === 0 ? 'top' : 'bottom', String(W), String(H));
  const origOk = orig.calc({ x, y });
  // 我的移植
  const mine = new FlipGeometry(d === 0 ? FORWARD : BACK, c === 0 ? TOP : BOTTOM, W, H);
  const mineOk = mine.calc({ x, y });

  if (origOk !== mineOk) {
    fail++; console.log(`MISMATCH calc(${d},${c},${x},${y}): orig=${origOk} mine=${mineOk}`); continue;
  }
  if (!origOk) { pass++; continue; }
  const checks = [
    ['angle', orig.getAngle(), mine.getAngle()],
    ['progress', orig.getFlippingProgress(), mine.getFlippingProgress()],
    ['pos.x', orig.getPosition().x, mine.getPosition().x],
    ['pos.y', orig.getPosition().y, mine.getPosition().y],
    ['rect.TL.x', orig.getRect().topLeft.x, mine.getRect().topLeft.x],
    ['rect.TR.x', orig.getRect().topRight.x, mine.getRect().topRight.x],
    ['rect.BL.y', orig.getRect().bottomLeft.y, mine.getRect().bottomLeft.y],
    ['rect.BR.y', orig.getRect().bottomRight.y, mine.getRect().bottomRight.y],
    ['shadowAngle', orig.getShadowAngle(), mine.getShadowAngle()],
  ];
  let allOk = true;
  for (const [name, a, b] of checks) {
    if (!cmp(a, b)) { allOk = false; console.log(`  MISMATCH ${name} @(${d},${c},${x},${y}): orig=${a} mine=${b}`); }
  }
  // 裁剪多边形对比（顶点数 + 坐标）
  const oc = orig.getFlippingClipArea().filter(p => p !== null).map(p => [Math.round(p.x*1e3)/1e3, Math.round(p.y*1e3)/1e3]);
  const mc = mine.getFlippingClipArea().filter(p => p !== null).map(p => [Math.round(p.x*1e3)/1e3, Math.round(p.y*1e3)/1e3]);
  if (oc.length !== mc.length) { allOk = false; console.log(`  MISMATCH clipV @(${d},${c},${x},${y}): orig=${oc.length} mine=${mc.length}`); }
  else {
    for (let i = 0; i < oc.length; i++) {
      if (Math.abs(oc[i][0] - mc[i][0]) > 1e-3 || Math.abs(oc[i][1] - mc[i][1]) > 1e-3) { allOk = false; console.log(`  MISMATCH clip[${i}] @(${d},${c},${x},${y}): orig=${oc[i]} mine=${mc[i]}`); }
    }
  }
  if (allOk) pass++; else fail++;
}
console.log(`\nPASS=${pass} FAIL=${fail}`);
process.exit(fail > 0 ? 1 : 0);
