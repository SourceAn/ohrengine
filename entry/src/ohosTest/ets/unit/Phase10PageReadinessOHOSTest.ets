/**
 * Phase10PageReadinessOHOSTest — 冷启动页面恢复与双向翻页稳定性（Phase 10）
 *
 * 覆盖（Phase 10.0 审计 → 10.1 instrumentation 的最小可验证事实）：
 *   Case1 Open → Immediately Previous（目标页 N-1 非 stub / 就绪）
 *   Case2 Open → Immediately Next（目标页 N+1 对称就绪）
 *   Case3 Open → wait(异步章完成) → Previous（仍对称）
 *   Case4 Open → Previous × 10（连续翻回无 stub/无代际变更）
 *   Case5 Open → Next × 10（连续翻前无 stub/无代际变更）
 *   Case6 Open → Previous/Next 往返 × 5（RTL/FORWARD 一致性 + gen 稳定）
 *   Case7 恢复场景：ReadingAnchor 持久化 → 二次 open → Resume Page N 就绪
 *         + N-1/N/N+1 均 RENDER_READY（文本页，无图片资产）
 *
 * 断言口径（与 docs/phase10-page-readiness-audit.md 一致）：
 *   slot.readyState∈{LAYOUT_READY, RENDER_READY}；文本页应为 RENDER_READY(3)；
 *   目标页 state==='ready'（非 stub）；翻页后 pageGeneration 保持不变；
 *   peekPage 返回的就绪目标与 turnPage 后页面身份吻合。
 */
import { describe, it, expect } from '@ohos/hypium';
import { fileIo } from '@kit.CoreFileKit';
import { OhEngine, OhEngineCore } from 'ohrengine-ui-render';
import { ParserRegistry, TurnDirection, PageReadyState, BookFormat } from 'ohrengine-common';
import type { PageSlot } from 'ohrengine-common';
import { TxtParser } from 'ohrengine-txt-exclusive';

const DIR: string = '/data/test/phase10';
const FILE: string = DIR + '/book.txt';
const CACHE_DIR: string = DIR + '/cache';
const STATE_DIR: string = DIR + '/state';

function writeSampleBook(): void {
  try { fileIo.mkdirSync(DIR, true); } catch (_e) { }
  const parts: string[] = [];
  for (let c = 0; c < 4; c++) {
    parts.push('第' + String(c + 1) + '章');
    for (let p = 0; p < 24; p++) {
      let para: string = '冷启动翻页测试段落内容。';
      while (para.length < 700) {
        para = para + '补充文字补足内容，保证每章多页。';
      }
      parts.push(para);
    }
    parts.push('');
  }
  const f: fileIo.File = fileIo.openSync(FILE,
    fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  fileIo.writeSync(f.fd, parts.join('\n'));
  fileIo.closeSync(f);
}

function ensureParser(): void {
  if (ParserRegistry.resolve(BookFormat.TXT) === undefined) {
    ParserRegistry.register(new TxtParser());
  }
}

function windowReady(core: OhEngineCore, cur: number): boolean {
  const slots = core.pageManager.pageSlots;
  for (let o = -1; o <= 1; o++) {
    const idx: number = cur + o;
    if (idx < 0 || idx >= slots.length) {
      continue;
    }
    const s: PageSlot = slots[idx];
    if (s.state !== 'ready' || s.lines.length === 0) {
      return false;
    }
    if (s.readyState !== PageReadyState.RENDER_READY &&
      s.readyState !== PageReadyState.LAYOUT_READY) {
      return false;
    }
  }
  return true;
}

export default function phase10PageReadinessTest() {
  describe('Phase10PageReadinessTest', () => {
    it('case1_open_immediately_previous_target_ready', 0, async () => {
      ensureParser();
      writeSampleBook();
      const engine: OhEngine = new OhEngine();
      engine.configure({ viewWidth: 720, viewHeight: 1080, density: 3.0 });
      const pub = await engine.open(FILE, {
        cacheDir: CACHE_DIR + '/c1',
        readingStateDir: STATE_DIR + '/c1'
      });
      expect(pub !== undefined || engine.getCurrentPage() !== undefined).assertTrue();
      // 前进到非首页，使 N-1 存在
      for (let i = 0; i < 3; i++) {
        engine.turnPage(TurnDirection.FORWARD);
      }
      const cur: PageSlot | undefined = engine.getCurrentPage();
      expect(cur !== undefined).assertTrue();
      if (cur === undefined) {
        return;
      }
      const prev: PageSlot | undefined = engine.peekPage(TurnDirection.BACKWARD);
      expect(prev !== undefined).assertTrue();
      if (prev !== undefined) {
        expect(prev.state).assertEqual('ready');
        expect(prev.lines.length > 0).assertTrue();
        expect(prev.readyState === PageReadyState.RENDER_READY ||
          prev.readyState === PageReadyState.LAYOUT_READY).assertTrue();
      }
      expect(engine.turnPage(TurnDirection.BACKWARD)).assertTrue();
      const after: PageSlot | undefined = engine.getCurrentPage();
      if (after !== undefined) {
        expect(after.state).assertEqual('ready');
      }
      engine.destroy();
    });

    it('case2_open_immediately_next_target_ready_symmetric', 0, async () => {
      ensureParser();
      writeSampleBook();
      const engine: OhEngine = new OhEngine();
      engine.configure({ viewWidth: 720, viewHeight: 1080, density: 3.0 });
      await engine.open(FILE, {
        cacheDir: CACHE_DIR + '/c2',
        readingStateDir: STATE_DIR + '/c2'
      });
      const next: PageSlot | undefined = engine.peekPage(TurnDirection.FORWARD);
      expect(next !== undefined).assertTrue();
      if (next !== undefined) {
        expect(next.state).assertEqual('ready');
        expect(next.readyState === PageReadyState.RENDER_READY ||
          next.readyState === PageReadyState.LAYOUT_READY).assertTrue();
      }
      engine.destroy();
    });

    it('case3_open_wait3s_previous_still_symmetric', 0, async () => {
      ensureParser();
      writeSampleBook();
      const engine: OhEngine = new OhEngine();
      engine.configure({ viewWidth: 720, viewHeight: 1080, density: 3.0 });
      await engine.open(FILE, {
        cacheDir: CACHE_DIR + '/c3',
        readingStateDir: STATE_DIR + '/c3'
      });
      await new Promise<void>((resolve: () => void): void => {
        setTimeout((): void => { resolve(); }, 3000);
      });
      for (let i = 0; i < 2; i++) {
        engine.turnPage(TurnDirection.FORWARD);
      }
      const prev: PageSlot | undefined = engine.peekPage(TurnDirection.BACKWARD);
      expect(prev !== undefined).assertTrue();
      if (prev !== undefined) {
        expect(prev.state).assertEqual('ready');
        expect(prev.lines.length > 0).assertTrue();
      }
      engine.destroy();
    });

    it('case4_previous_x10_no_stub_no_gen_change', 0, async () => {
      ensureParser();
      writeSampleBook();
      const engine: OhEngine = new OhEngine();
      engine.configure({ viewWidth: 720, viewHeight: 1080, density: 3.0 });
      await engine.open(FILE, {
        cacheDir: CACHE_DIR + '/c4',
        readingStateDir: STATE_DIR + '/c4'
      });
      // 深入书中段，然后连续翻回 10 次
      for (let i = 0; i < 12; i++) {
        engine.turnPage(TurnDirection.FORWARD);
      }
      const genBefore: number = engine.getCore().getPageGeneration();
      let ok: boolean = true;
      for (let i = 0; i < 10; i++) {
        const cur: PageSlot | undefined = engine.getCurrentPage();
        if (cur === undefined || cur.lines.length === 0) {
          ok = false;
          break;
        }
        if (!engine.turnPage(TurnDirection.BACKWARD)) {
          break;
        }
      }
      expect(ok).assertTrue();
      const genAfter: number = engine.getCore().getPageGeneration();
      // 无 reflow 前提下翻页不应导致 stale 重建
      expect(genAfter).assertEqual(genBefore);
      engine.destroy();
    });

    it('case5_next_x10_no_stub_no_gen_change', 0, async () => {
      ensureParser();
      writeSampleBook();
      const engine: OhEngine = new OhEngine();
      engine.configure({ viewWidth: 720, viewHeight: 1080, density: 3.0 });
      await engine.open(FILE, {
        cacheDir: CACHE_DIR + '/c5',
        readingStateDir: STATE_DIR + '/c5'
      });
      const genBefore: number = engine.getCore().getPageGeneration();
      let ok: boolean = true;
      for (let i = 0; i < 10; i++) {
        const cur: PageSlot | undefined = engine.getCurrentPage();
        if (cur === undefined || cur.lines.length === 0) {
          ok = false;
          break;
        }
        if (!engine.turnPage(TurnDirection.FORWARD)) {
          break;
        }
      }
      expect(ok).assertTrue();
      const genAfter: number = engine.getCore().getPageGeneration();
      expect(genAfter).assertEqual(genBefore);
      engine.destroy();
    });

    it('case6_prev_next_roundtrip_x5_window_symmetric', 0, async () => {
      ensureParser();
      writeSampleBook();
      const engine: OhEngine = new OhEngine();
      engine.configure({ viewWidth: 720, viewHeight: 1080, density: 3.0 });
      await engine.open(FILE, {
        cacheDir: CACHE_DIR + '/c6',
        readingStateDir: STATE_DIR + '/c6'
      });
      // 进入书中
      for (let i = 0; i < 6; i++) {
        engine.turnPage(TurnDirection.FORWARD);
      }
      let allReady: boolean = true;
      for (let r = 0; r < 5; r++) {
        const cur: number = engine.getCore().pageManager.currentGlobalPage;
        if (!windowReady(engine.getCore(), cur)) {
          allReady = false;
          break;
        }
        engine.turnPage(TurnDirection.BACKWARD);
        if (!windowReady(engine.getCore(), engine.getCore().pageManager.currentGlobalPage)) {
          allReady = false;
          break;
        }
        engine.turnPage(TurnDirection.FORWARD);
        if (!windowReady(engine.getCore(), engine.getCore().pageManager.currentGlobalPage)) {
          allReady = false;
          break;
        }
      }
      expect(allReady).assertTrue();
      engine.destroy();
    });

    it('case7_resume_page_n_render_ready_on_reopen', 0, async () => {
      ensureParser();
      writeSampleBook();
      const engine1: OhEngine = new OhEngine();
      engine1.configure({ viewWidth: 720, viewHeight: 1080, density: 3.0 });
      await engine1.open(FILE, {
        cacheDir: CACHE_DIR + '/c7',
        readingStateDir: STATE_DIR + '/c7'
      });
      // 导航到书深处并强制持久化 ReadingState（真实部署是 debounce 500ms）
      for (let i = 0; i < 8; i++) {
        engine1.turnPage(TurnDirection.FORWARD);
      }
      const savedState: PageSlot | undefined = engine1.getCurrentPage();
      expect(savedState !== undefined).assertTrue();
      if (savedState === undefined) {
        engine1.destroy();
        return;
      }
      const savedChapter: number = savedState.chunkIndex;
      engine1.getCore().pageManager.persistCurrentReadingState();
      engine1.destroy();

      // 二次 open：应恢复到同一位置且 Resume Page 就绪
      const engine2: OhEngine = new OhEngine();
      engine2.configure({ viewWidth: 720, viewHeight: 1080, density: 3.0 });
      await engine2.open(FILE, {
        cacheDir: CACHE_DIR + '/c7',
        readingStateDir: STATE_DIR + '/c7'
      });
      const resumed: PageSlot | undefined = engine2.getCurrentPage();
      expect(resumed !== undefined).assertTrue();
      if (resumed === undefined) {
        engine2.destroy();
        return;
      }
      expect(resumed.state).assertEqual('ready');
      expect(resumed.lines.length > 0).assertTrue();
      expect(resumed.readyState).assertEqual(PageReadyState.RENDER_READY);
      // 恢复章一致（ReadingAnchor 章级定位）；页级近似定位由 Phase 1 测试覆盖
      expect(resumed.chunkIndex).assertEqual(savedChapter);
      // N-1/N/N+1 三页同窗就绪
      const curN: number = engine2.getCore().pageManager.currentGlobalPage;
      const slots = engine2.getCore().pageManager.pageSlots;
      for (let o = -1; o <= 1; o++) {
        const idx: number = curN + o;
        if (idx >= 0 && idx < slots.length) {
          const s: PageSlot = slots[idx];
          expect(s.state).assertEqual('ready');
          expect(s.readyState === PageReadyState.RENDER_READY ||
            s.readyState === PageReadyState.LAYOUT_READY).assertTrue();
        }
      }
      engine2.destroy();
    });
  });
}