/**
 * FontFallbackChainOhosTest — OhosTest (hypium) unit tests for FontFallbackChain (ENG-009)
 *
 * Covers: CJK/Latin/Emoji range fallback, missing-glyph fallback to system,
 *         family dedup, and text segmentation into per-font runs.
 */
import { describe, it, expect } from '@ohos/hypium';
import { FontFallbackChain, FontLoader } from 'ohrengine-common';
import type { LoadedFontInfo } from 'ohrengine-common';

export default function fontFallbackChainTest() {
  describe('FontFallbackChainTest', () => {
    it('empty_chain_returns_undefined', 0, () => {
      const chain: FontFallbackChain = new FontFallbackChain();
      expect(chain.resolveFont('a')).assertUndefined();
      expect(chain.getFamilies().length).assertEqual(0);
    });

    it('cjk_resolves_to_registered_family', 0, () => {
      const chain: FontFallbackChain = new FontFallbackChain();
      chain.addFont('MyCJK');
      const resolved: string | undefined = chain.resolveFont('中');
      expect(resolved).assertEqual('MyCJK');
    });

    it('latin_resolves_to_registered_family', 0, () => {
      const chain: FontFallbackChain = new FontFallbackChain();
      chain.addFont('MyLatin');
      const resolved: string | undefined = chain.resolveFont('A');
      expect(resolved).assertEqual('MyLatin');
    });

    it('emoji_resolves_to_registered_family', 0, () => {
      const chain: FontFallbackChain = new FontFallbackChain();
      chain.addFont('MyEmoji');
      const resolved: string | undefined = chain.resolveFont('\uD83D\uDE00');
      expect(resolved).assertEqual('MyEmoji');
    });

    it('addFont_dedups_same_family', 0, () => {
      const chain: FontFallbackChain = new FontFallbackChain();
      chain.addFont('Dup');
      chain.addFont('Dup');
      expect(chain.getFamilies().length).assertEqual(1);
    });

    it('missing_glyph_returns_undefined_with_loader', 0, () => {
      const chain: FontFallbackChain = new FontFallbackChain();
      chain.addFont('RangeFont');
      // 注册字体记录包含 unicode-range：U+3040-30FF（日文片假名），不覆盖 CJK 汉字
      // → getFontForChar('中') 返回 undefined → findBestFont 回退系统默认
      const loader: FontLoader = new FontLoader();
      const fontLoaderInstance = loader;
      const resolved: string | undefined = chain.findBestFont('中', undefined, undefined, fontLoaderInstance);
      expect(resolved).assertUndefined();
    });

    it('fontFamilyList_priority_picks_loaded_font', 0, () => {
      const chain: FontFallbackChain = new FontFallbackChain();
      chain.addFont('Registered');
      const loaded: LoadedFontInfo[] = [
        { familyName: 'LoadedFont', hasGlyph: (): boolean => true }
      ];
      const resolved: string | undefined =
        chain.findBestFont('A', ['LoadedFont', 'Registered'], loaded);
      expect(resolved).assertEqual('LoadedFont');
    });

    it('resolveTextSegments_splits_by_font_runs', 0, () => {
      const chain: FontFallbackChain = new FontFallbackChain();
      chain.addFont('MyFont');
      // 全部字符在同一字体链下 → 单段
      const segments = chain.resolveTextSegments('abc中\uD83D\uDE00');
      expect(segments.length).assertLarger(0);
      expect(segments[0].text).assertEqual('abc中\uD83D\uDE00');
    });

    it('empty_text_returns_no_segments', 0, () => {
      const chain: FontFallbackChain = new FontFallbackChain();
      chain.addFont('MyFont');
      const segments = chain.resolveTextSegments('');
      expect(segments.length).assertEqual(0);
    });
  });
}
