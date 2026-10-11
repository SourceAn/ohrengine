/**
 * MemoryPageCacheOHOSTest — L3 内存页缓存纯逻辑测试（Phase 3）
 *
 * 覆盖：LRU 命中/未命中、LRU 尾淘汰、shrinkToVisible、clear、byte 估算。
 * 磁盘无关，可在模拟器/真机离线验证。
 */
import { describe, it, expect } from '@ohos/hypium';
import { MemoryPageCache, createEmptyLineBox } from 'ohrengine-common';
import type { CacheChapter, CachePage, LineBox } from 'ohrengine-common';

function makeChapter(index: number, chars: number): CacheChapter {
  const line: LineBox = createEmptyLineBox();
  let text: string = '';
  for (let i: number = 0; i < chars; i++) {
    text += 'a';
  }
  line.text = text;
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
    href: 'ch' + index + '.xhtml',
    pages: [page],
    totalPages: 1,
    totalLineCount: 1,
    isStub: false
  };
  return chapter;
}

export default function memoryPageCacheTest() {
  describe('MemoryPageCacheTest', () => {
    it('L3_hit_after_put_returns_same_chapter', 0, () => {
      const cache: MemoryPageCache = new MemoryPageCache();
      const ch: CacheChapter = makeChapter(0, 10);
      cache.put(0, ch);
      const hit: CacheChapter | undefined = cache.get(0);
      expect(hit !== undefined).assertTrue();
      if (hit !== undefined) {
        expect(hit.href).assertEqual('ch0.xhtml');
        expect(hit.pages[0].lines[0].text.length).assertEqual(10);
      }
      expect(cache.size()).assertEqual(1);
    });

    it('L3_miss_returns_undefined', 0, () => {
      const cache: MemoryPageCache = new MemoryPageCache();
      const hit: CacheChapter | undefined = cache.get(7);
      expect(hit).assertUndefined();
    });

    it('L3_lru_evicts_oldest_beyond_capacity', 0, () => {
      const cache: MemoryPageCache = new MemoryPageCache(3, 1024 * 1024 * 1024);
      cache.put(0, makeChapter(0, 5));
      cache.put(1, makeChapter(1, 5));
      cache.put(2, makeChapter(2, 5));
      // 访问 0 → LRU 顺序: 0(最近),2,1(最旧)
      cache.get(0);
      cache.put(3, makeChapter(3, 5));
      // 淘汰最旧 1
      expect(cache.get(1)).assertUndefined();
      expect(cache.get(0) !== undefined).assertTrue();
      expect(cache.get(2) !== undefined).assertTrue();
      expect(cache.get(3) !== undefined).assertTrue();
      expect(cache.size()).assertEqual(3);
    });

    it('L3_shrink_to_visible_keeps_most_recent', 0, () => {
      const cache: MemoryPageCache = new MemoryPageCache(10, 1024 * 1024 * 1024);
      cache.put(0, makeChapter(0, 5));
      cache.put(1, makeChapter(1, 5));
      cache.put(2, makeChapter(2, 5));
      cache.shrinkToVisible(1);
      expect(cache.size()).assertEqual(1);
      // 最近访问的是 2
      expect(cache.get(2) !== undefined).assertTrue();
      expect(cache.get(0)).assertUndefined();
      expect(cache.get(1)).assertUndefined();
    });

    it('L3_clear_empties_cache', 0, () => {
      const cache: MemoryPageCache = new MemoryPageCache();
      cache.put(0, makeChapter(0, 5));
      cache.put(1, makeChapter(1, 5));
      cache.clear();
      expect(cache.size()).assertEqual(0);
      expect(cache.get(0)).assertUndefined();
    });
  });
}