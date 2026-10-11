/**
 * VChapterOHOSTest — TXT 虚拟章节切分纯逻辑测试（Phase 8 D2）
 *
 * 覆盖：vchapter id 生成、段落边界切分、切分确定性、旧 chapter-N 解析、
 *       空章单 vchapter fallback。
 */
import { describe, it, expect } from '@ohos/hypium';
import { vchapterId, oldChapterIndexFromId, buildVChapters,
         VCHAPTER_TARGET_CHARS } from 'ohrengine-common';
import type { VChapterDef } from 'ohrengine-common';

function makeParagraphs(count: number, len: number): string[] {
  const out: string[] = [];
  for (let i = 0; i < count; i++) {
    let s: string = '';
    for (let j = 0; j < len; j++) {
      s += 'a';
    }
    out.push(s);
  }
  return out;
}

function makeTexts(count: number, len: number): string[] {
  const out: string[] = [];
  for (let i = 0; i < count; i++) {
    let s: string = '<p>';
    for (let j = 0; j < len; j++) {
      s += 'a';
    }
    out.push(s + '</p>');
  }
  return out;
}

export default function vChapterTest() {
  describe('VChapterTest', () => {
    it('vchapter_id_is_five_digit_prefixed', 0, () => {
      expect(vchapterId(0)).assertEqual('vchapter_00000');
      expect(vchapterId(1)).assertEqual('vchapter_00001');
      expect(vchapterId(1234)).assertEqual('vchapter_01234');
    });

    it('old_chapter_index_parses_chapter_N', 0, () => {
      expect(oldChapterIndexFromId('chapter-1')).assertEqual(0);
      expect(oldChapterIndexFromId('chapter-3')).assertEqual(2);
      expect(oldChapterIndexFromId('page-5')).assertEqual(4);
      expect(oldChapterIndexFromId('vchapter_00001')).assertEqual(-1);
      expect(oldChapterIndexFromId('bogus')).assertEqual(-1);
    });

    it('build_vchapters_splits_large_paragraph_blocks', 0, () => {
      const paras: string[] = makeParagraphs(50, 1000); // 50 段 × 1000 chars
      const texts: string[] = makeTexts(50, 1000);
      const defs: VChapterDef[] = buildVChapters(0, paras, texts);
      expect(defs.length > 1).assertTrue();
      // 每段正文长度 ≈ 目标处切分
      expect(defs[0].charEnd - defs[0].charStart >= VCHAPTER_TARGET_CHARS * 0.8).assertTrue();
      // 拼接完整
      let total: number = 0;
      for (const d of defs) {
        total += d.charEnd - d.charStart;
      }
      expect(total).assertEqual(50 * 1000);
    });

    it('build_vchapters_deterministic_same_input', 0, () => {
      const paras: string[] = makeParagraphs(20, 500);
      const texts: string[] = makeTexts(20, 500);
      const d1: VChapterDef[] = buildVChapters(2, paras, texts);
      const d2: VChapterDef[] = buildVChapters(2, paras, texts);
      expect(d1.length).assertEqual(d2.length);
      expect(d1[0].id).assertEqual(d2[0].id);
      expect(d1[0].html).assertEqual(d2[0].html);
    });

    it('build_vchapters_empty_chapter_single_def', 0, () => {
      const defs: VChapterDef[] = buildVChapters(0, [], []);
      expect(defs.length).assertEqual(1);
      expect(defs[0].html).assertEqual('');
    });

    it('build_vchapters_small_chapter_no_split', 0, () => {
      const paras: string[] = makeParagraphs(3, 100);
      const texts: string[] = makeTexts(3, 100);
      const defs: VChapterDef[] = buildVChapters(1, paras, texts);
      expect(defs.length).assertEqual(1);
      expect(defs[0].oldChapterIndex).assertEqual(1);
    });
  });
}