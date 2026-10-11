/**
 * PageGenerationOhosTest — pageGeneration 6 入口递增覆盖测试（T017，0.13）
 *
 * 递增点设计：pageGeneration 在 PageManager.rebuildPageSlots()（唯一替换
 * pageSlots 的点）递增；以下 6 个重排入口全部经它级联递增（代码审查对照表）：
 *   [1] rebuildPageSlots() 直接调用
 *   [2] reflowFromCurrentPage()（内部调用 rebuildPageSlots）
 *   [3] relayoutAllChapters()（PipelineManager 排队 → processNextInQueue →
 *       host.rebuildPageSlots → PageManager.rebuildPageSlots）
 *   [4] relayoutCurrentPageOnly()（内部调用 rebuildPageSlots）
 *   [5] recompileCss() 触发的 reflow（→ reflowFromCurrentPage）
 *   [6] PipelineManager.processNextInQueue() 异步 rebuildPageSlots
 */
import { describe, it, expect } from '@ohos/hypium';
import { OhEngineCore } from 'ohrengine-ui-render';
import { Publication, TurnDirection } from 'ohrengine-common';
import type { PageSlot } from 'ohrengine-common';
import { createEmptyLineBox } from 'ohrengine-common';

function makeSlot(pageNumber: number, chunkIndex: number, state: 'stub' | 'ready'): PageSlot {
  const line = createEmptyLineBox();
  line.text = 'page';
  line.width = 320;
  line.height = 24;
  const slot: PageSlot = {
    pageNumber: pageNumber,
    chunkIndex: chunkIndex,
    href: 'ch.xhtml',
    state: state,
    epoch: 0,
    lines: [line],
    charRange: [0, 4]
  };
  return slot;
}

export default function pageGenerationTest() {
  describe('PageGenerationTest', () => {
    it('entry1_rebuildPageSlots_increments', 0, () => {
      const core: OhEngineCore = new OhEngineCore();
      const before: number = core.pageManager.getPageGeneration();
      core.pageManager.rebuildPageSlots();
      expect(core.pageManager.getPageGeneration()).assertLarger(before);
    });

    it('entry2_reflowFromCurrentPage_increments', 0, () => {
      const core: OhEngineCore = new OhEngineCore();
      core.publication = new Publication('test-book');
      core.pageManager.pageSlots = [makeSlot(0, 0, 'ready')];
      core.pageManager.currentGlobalPage = 0;
      const before: number = core.pageManager.getPageGeneration();
      core.pageManager.reflowFromCurrentPage();
      expect(core.pageManager.getPageGeneration()).assertLarger(before);
    });

    it('entry3_relayoutAllChapters_increments_via_queue', 0, () => {
      const core: OhEngineCore = new OhEngineCore();
      core.publication = new Publication('test-book');
      core.pageManager.pageSlots = [makeSlot(0, 0, 'stub')];
      core.pageManager.currentGlobalPage = 0;
      const before: number = core.pageManager.getPageGeneration();
      // relayoutAllChapters 排队 → 处理队列触发 host.rebuildPageSlots → 递增
      core.pipelineManager.relayoutAllChapters(0);
      core.pipelineManager.processNextInQueue();
      expect(core.pageManager.getPageGeneration()).assertLarger(before);
    });

    it('entry4_relayoutCurrentPageOnly_increments', 0, () => {
      const core: OhEngineCore = new OhEngineCore();
      core.pageManager.pageSlots = [makeSlot(0, 0, 'ready')];
      core.pageManager.currentGlobalPage = 0;
      const before: number = core.pageManager.getPageGeneration();
      core.pageManager.relayoutCurrentPageOnly();
      expect(core.pageManager.getPageGeneration()).assertLarger(before);
    });

    it('entry5_recompileCss_reflow_increments', 0, () => {
      const core: OhEngineCore = new OhEngineCore();
      core.publication = new Publication('test-book');
      core.pageManager.pageSlots = [makeSlot(0, 0, 'ready')];
      core.pageManager.currentGlobalPage = 0;
      const before: number = core.pageManager.getPageGeneration();
      core.recompileCss();
      expect(core.pageManager.getPageGeneration()).assertLarger(before);
    });

    it('entry6_processNextInQueue_async_rebuild_increments', 0, () => {
      const core: OhEngineCore = new OhEngineCore();
      core.publication = new Publication('test-book');
      core.pageManager.pageSlots = [makeSlot(0, 0, 'stub')];
      core.pageManager.currentGlobalPage = 0;
      const before: number = core.pageManager.getPageGeneration();
      // 队列中放入一个章节，处理时触发 host.rebuildPageSlots（0.13 入口 6）
      core.pipelineManager.chapterHtmlCache = ['<p>hello</p>'];
      core.pipelineManager.layoutQueue = [0];
      core.pipelineManager.processNextInQueue();
      expect(core.pageManager.getPageGeneration()).assertLarger(before);
    });

    it('getPageGeneration_does_not_bump_epoch', 0, () => {
      // pageGeneration 与 epoch 语义完全分离（0.13）：rebuild 递增 pageGeneration，
      // 不触碰 PageSlot.epoch
      const core: OhEngineCore = new OhEngineCore();
      const epochBefore: number = core.epoch;
      core.pageManager.rebuildPageSlots();
      expect(core.epoch).assertEqual(epochBefore);
    });
  });
}
