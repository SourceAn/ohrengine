/**
 * TextBreakerOhosTest — OhosTest (hypium) unit tests for TextBreaker
 *
 * Covers: basic breaking, empty text, CJK multi-line,
 *         short text single line, long word flow
 */
import { describe, it, expect } from '@ohos/hypium';
import { TextBreaker } from 'ohrengine-ui-render';
import type { BreakerResult } from 'ohrengine-ui-render';

export default function textBreakerTest() {
  describe('TextBreakerTest', () => {
    it('empty_text_returns_no_lines', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setMaxWidth(356);
      breaker.setFontSize(16);
      const result: BreakerResult = breaker.breakText('');
      expect(result.totalLines).assertEqual(0);
    });

    it('short_text_fits_one_line', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setMaxWidth(1000);
      breaker.setFontSize(16);
      const result: BreakerResult = breaker.breakText('Hi');
      expect(result.totalLines).assertEqual(1);
    });

    it('long_text_produces_multiple_lines', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setMaxWidth(100);
      breaker.setFontSize(16);
      const result: BreakerResult = breaker.breakText(
        'This is a relatively long text that should wrap to multiple lines ' +
        'when the maximum width is quite narrow.'
      );
      expect(result.totalLines).assertLarger(1);
    });

    it('result_lines_have_non_empty_text', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setMaxWidth(356);
      breaker.setFontSize(16);
      const result: BreakerResult = breaker.breakText('Hello World TextBreaker');
      expect(result.totalLines).assertLarger(0);
      for (let i = 0; i < result.lines.length; i++) {
        expect(result.lines[i].text.length).assertLarger(0);
      }
    });

    it('CJK_text_breaks_into_multiple_lines', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setMaxWidth(80);
      breaker.setFontSize(16);
      const result: BreakerResult = breaker.breakText('这是一段中文测试文本用于验证换行功能');
      expect(result.totalLines).assertLarger(1);
    });

    it('charsPerLine_is_reported', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setMaxWidth(356);
      breaker.setFontSize(16);
      const result: BreakerResult = breaker.breakText('Hello World');
      expect(result.charsPerLine).assertLarger(0);
    });

    it('long_word_does_not_crash', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setMaxWidth(100);
      breaker.setFontSize(16);
      const result: BreakerResult = breaker.breakText('supercalifragilisticexpialidocious');
      expect(result.totalLines).assertLarger(0);
    });

    it('very_narrow_width_produces_more_lines', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setFontSize(16);
      breaker.setMaxWidth(30);
      const result: BreakerResult = breaker.breakText('The quick brown fox jumps over the lazy dog');
      expect(result.totalLines).assertLarger(1);
    });

    it('narrower_width_produces_at_least_as_many_lines', 0, () => {
      const breakerWide: TextBreaker = new TextBreaker();
      breakerWide.setFontSize(16);
      breakerWide.setMaxWidth(300);
      const wideResult: BreakerResult = breakerWide.breakText('The quick brown fox jumps over the lazy dog');
      const breakerNarrow: TextBreaker = new TextBreaker();
      breakerNarrow.setFontSize(16);
      breakerNarrow.setMaxWidth(50);
      const narrowResult: BreakerResult = breakerNarrow.breakText('The quick brown fox jumps over the lazy dog');
      expect(narrowResult.totalLines >= wideResult.totalLines).assertTrue();
    });

    it('cjk_lines_do_not_start_with_forbidden_punctuation', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setFontSize(16);
      breaker.setMaxWidth(70);
      const result: BreakerResult = breaker.breakText('他说：“这是一个测试。他说：‘另一个测试。’”');
      expect(result.totalLines).assertLarger(0);
      for (let i = 0; i < result.lines.length; i++) {
        const text: string = result.lines[i].text;
        if (text.length === 0) {
          continue;
        }
        // 禁则：行首不应是句末标点（。！？）或后引号
        const firstChar: string = text.charAt(0);
        const forbidden: string = '。！？）”』】';
        expect(forbidden.indexOf(firstChar) < 0).assertTrue();
      }
    });

    it('line_widths_do_not_exceed_max_width', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setFontSize(16);
      breaker.setMaxWidth(200);
      const result: BreakerResult = breaker.breakText('This sentence should not overflow the configured maximum line width at all');
      for (let i = 0; i < result.lines.length; i++) {
        expect(result.lines[i].width <= 200).assertTrue();
      }
    });

    it('whitespace_only_input_yields_lines_with_text', 0, () => {
      const breaker: TextBreaker = new TextBreaker();
      breaker.setFontSize(16);
      breaker.setMaxWidth(200);
      const result: BreakerResult = breaker.breakText('   ');
      expect(result.totalLines).assertLarger(0);
    });
  });
}
