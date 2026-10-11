/**
 * PageCacheManagerOhosTest — OhosTest (hypium) unit tests for PageCacheManager (ENG-009)
 *
 * Covers: layout signature stability & change detection,
 *         serialization round-trip of a PaginatedChapter.
 * 磁盘读写相关（isCacheValid/loadChapter/saveChapter/invalidate）需要沙箱，
 * 在真机/模拟器环境验证；本文件覆盖可离线验证的纯函数。
 */
import { describe, it, expect } from '@ohos/hypium';
import { PageCacheManager, createDefaultEngineConfig, createEmptyLineBox, PAGE_CACHE_SCHEMA_VERSION, LAYOUT_ALGORITHM_VERSION } from 'ohrengine-common';
import type { EngineConfig, LayoutProfile, CacheChapter, CachePage, LineBox } from 'ohrengine-common';

function makeProfile(): LayoutProfile {
  const cfg: LayoutProfile = {
    lineSpacing: 4,
    letterSpacing: 0,
    wordSpacing: 0,
    textIndent: 32,
    margins: { left: 10, right: 10, top: 50, bottom: 36 },
    paragraphSpacing: 8,
    textAlign: 'justify',
    theme: { backgroundColor: '#ffffff', textColor: '#000000' },
    fontFamily: 'HarmonyOS Sans',
    rubyFontFamily: undefined,
    rubyColor: undefined,
    rubyFontSizeRatio: undefined
  };
  return cfg;
}

function makeChapter(): CacheChapter {
  const line: LineBox = createEmptyLineBox();
  line.text = 'Hello World';
  line.x = 0;
  line.y = 0;
  line.width = 320;
  line.height = 24;
  line.ascent = 16;
  line.descent = 4;
  const page: CachePage = {
    index: 0,
    lines: [line],
    startLineIndex: 0,
    endLineIndex: 0,
    startPosition: 0,
    endPosition: 1,
    hasPageBreakBefore: false,
    isEmpty: false,
    yOffset: 0
  };
  const chapter: CacheChapter = {
    href: 'chapter1.xhtml',
    pages: [page],
    totalPages: 1,
    totalLineCount: 1,
    isStub: false
  };
  return chapter;
}

export default function pageCacheManagerTest() {
  describe('PageCacheManagerTest', () => {
    it('layout_signature_is_stable_for_same_input', 0, () => {
      const config: EngineConfig = createDefaultEngineConfig();
      const profile: LayoutProfile = makeProfile();
      const sig1: string = PageCacheManager.computeLayoutSignature(config, profile, 16);
      const sig2: string = PageCacheManager.computeLayoutSignature(config, profile, 16);
      expect(sig1).assertEqual(sig2);
      expect(sig1.length).assertLarger(0);
    });

    it('layout_signature_changes_on_font_size', 0, () => {
      const config: EngineConfig = createDefaultEngineConfig();
      const profile: LayoutProfile = makeProfile();
      const sig1: string = PageCacheManager.computeLayoutSignature(config, profile, 16);
      const sig2: string = PageCacheManager.computeLayoutSignature(config, profile, 20);
      expect(sig1 === sig2).assertFalse();
    });

    it('layout_signature_changes_on_viewport', 0, () => {
      const config: EngineConfig = createDefaultEngineConfig();
      const profile: LayoutProfile = makeProfile();
      const sig1: string = PageCacheManager.computeLayoutSignature(config, profile, 16);
      config.viewWidth = 999;
      const sig2: string = PageCacheManager.computeLayoutSignature(config, profile, 16);
      expect(sig1 === sig2).assertFalse();
    });

    it('serialize_deserialize_roundtrip_preserves_structure', 0, () => {
      const chapter: CacheChapter = makeChapter();
      const json: string = PageCacheManager.serializePaginatedChapter(chapter);
      expect(json.length).assertLarger(0);
      const restored: CacheChapter | null = PageCacheManager.deserializePaginatedChapter(json);
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.totalPages).assertEqual(1);
        expect(restored.pages.length).assertEqual(1);
        expect(restored.href).assertEqual('chapter1.xhtml');
      }
    });

    it('deserialize_invalid_json_returns_null', 0, () => {
      const restored: CacheChapter | null = PageCacheManager.deserializePaginatedChapter('{not valid json');
      expect(restored).assertNull();
    });

    it('phase2_schema_and_algorithm_versions_exported', 0, () => {
      expect(PAGE_CACHE_SCHEMA_VERSION).assertEqual(1);
      expect(LAYOUT_ALGORITHM_VERSION).assertEqual(1);
    });

    it('phase2_serialize_roundtrip_preserves_char_range', 0, () => {
      const line1: LineBox = createEmptyLineBox();
      line1.text = 'hello';
      const line2: LineBox = createEmptyLineBox();
      line2.text = 'world';
      const page1: CachePage = {
        index: 0, lines: [line1], startLineIndex: 0, endLineIndex: 0,
        startPosition: 0, endPosition: 0.5, hasPageBreakBefore: false,
        isEmpty: false, yOffset: 0
      };
      const page2: CachePage = {
        index: 1, lines: [line2], startLineIndex: 0, endLineIndex: 0,
        startPosition: 0.5, endPosition: 1, hasPageBreakBefore: false,
        isEmpty: false, yOffset: 0
      };
      const chapter: CacheChapter = {
        href: 'ch.xhtml', pages: [page1, page2], totalPages: 2,
        totalLineCount: 2, isStub: false
      };
      const json: string = PageCacheManager.serializePaginatedChapter(chapter);
      expect(json.length).assertLarger(0);
      const restored: CacheChapter | null = PageCacheManager.deserializePaginatedChapter(json);
      expect(restored !== null).assertTrue();
      if (restored !== null) {
        expect(restored.pages.length).assertEqual(2);
        expect(restored.pages[0].startChar).assertEqual(0);
        expect(restored.pages[0].endChar).assertEqual(5);
        expect(restored.pages[1].startChar).assertEqual(5);
        expect(restored.pages[1].endChar).assertEqual(10);
        // 连续性：相邻页 endChar <= next.startChar
        expect(PageCacheManager.isPageRangeContinuous(restored)).assertTrue();
      }
    });

    it('phase2_overlapping_pages_are_detected', 0, () => {
      const line1: LineBox = createEmptyLineBox();
      line1.text = 'hello';
      const page1: CachePage = {
        index: 0, lines: [line1], startLineIndex: 0, endLineIndex: 0,
        startPosition: 0, endPosition: 0.5, hasPageBreakBefore: false,
        isEmpty: false, yOffset: 0,
        startChar: 0, endChar: 10
      };
      const page2: CachePage = {
        index: 1, lines: [], startLineIndex: 0, endLineIndex: 0,
        startPosition: 0.5, endPosition: 1, hasPageBreakBefore: false,
        isEmpty: true, yOffset: 0,
        startChar: 5, endChar: 15
      };
      const chapter: CacheChapter = {
        href: 'ch.xhtml', pages: [page1, page2], totalPages: 2,
        totalLineCount: 1, isStub: false
      };
      // page1.endChar(10) > page2.startChar(5) → overlap → 判损坏
      expect(PageCacheManager.isPageRangeContinuous(chapter)).assertFalse();
    });
  });
}
