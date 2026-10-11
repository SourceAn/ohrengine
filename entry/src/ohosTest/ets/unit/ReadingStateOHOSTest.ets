/**
 * ReadingStateOHOSTest — OhosTest (hypium) unit tests for Phase 1 (L1) 纯函数
 *
 * 覆盖：
 *  - extractParagraphs：确定性段落提取（块级边界/自闭合/空章）
 *  - hashParagraphText：同文本同 hash、不同文本不同 hash、算法前缀
 *  - computeParagraphStarts：章节内段落起始偏移
 *  - clampParagraphCharOffset：非法偏移钳制
 * 磁盘读写（ReadingStateStore.save/load）需要沙箱，在真机/模拟器环境验证。
 */
import { describe, it, expect } from '@ohos/hypium';
import { extractParagraphs, hashParagraphText, computeParagraphStarts,
         clampParagraphCharOffset } from 'ohrengine-common';

export default function readingStateTest() {
  describe('ReadingStateTest', () => {
    it('extract_paragraphs_splits_block_boundaries', 0, () => {
      const html: string = '<html><body><p>第一段内容。</p><p>第二段内容。</p></body></html>';
      const paragraphs: string[] = extractParagraphs(html);
      expect(paragraphs.length).assertEqual(2);
      expect(paragraphs[0]).assertEqual('第一段内容。');
      expect(paragraphs[1]).assertEqual('第二段内容。');
    });

    it('extract_paragraphs_handles_br_and_entities', 0, () => {
      const html: string = '<div>第一行<br>第二行</div><p>a&nbsp;&amp;&lt;b</p>';
      const paragraphs: string[] = extractParagraphs(html);
      expect(paragraphs.length).assertEqual(3);
      expect(paragraphs[0]).assertEqual('第一行');
      expect(paragraphs[1]).assertEqual('第二行');
      expect(paragraphs[2]).assertEqual('a &<b');
    });

    it('extract_paragraphs_empty_html_returns_empty', 0, () => {
      const paragraphs: string[] = extractParagraphs('');
      expect(paragraphs.length).assertEqual(0);
    });

    it('paragraph_hash_is_deterministic_and_prefixed', 0, () => {
      const h1: string = hashParagraphText('你好世界');
      const h2: string = hashParagraphText('你好世界');
      expect(h1).assertEqual(h2);
      expect(h1.startsWith('fnv1a:')).assertTrue();
    });

    it('paragraph_hash_differs_for_different_text', 0, () => {
      const h1: string = hashParagraphText('你好世界');
      const h2: string = hashParagraphText('你好世界！');
      expect(h1 === h2).assertFalse();
    });

    it('compute_paragraph_starts_accumulates_lengths', 0, () => {
      const paragraphs: string[] = ['ab', 'cdef', 'g'];
      const starts: number[] = computeParagraphStarts(paragraphs);
      expect(starts[0]).assertEqual(0);
      expect(starts[1]).assertEqual(2);
      expect(starts[2]).assertEqual(6);
    });

    it('clamp_paragraph_char_offset_bounds', 0, () => {
      expect(clampParagraphCharOffset(-5, 'hello')).assertEqual(0);
      expect(clampParagraphCharOffset(2, 'hello')).assertEqual(2);
      expect(clampParagraphCharOffset(99, 'hello')).assertEqual(5);
    });

    it('extract_paragraphs_deterministic_same_input', 0, () => {
      const html: string = '<p>测试段落</p><p>另一段</p>';
      const p1: string[] = extractParagraphs(html);
      const p2: string[] = extractParagraphs(html);
      expect(p1.length).assertEqual(p2.length);
      expect(p1[0]).assertEqual(p2[0]);
      expect(p1[1]).assertEqual(p2[1]);
    });
  });
}