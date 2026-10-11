/**
 * FontFallbackCache — Unicode-block-based font lookup cache
 *
 * Caches font resolution results by Unicode block to avoid repeated
 * character-by-character lookups. Pre-warm on book open for all
 * common Unicode ranges, then serve O(1) lookups during rendering.
 *
 * Usage:
 *   const cache = new FontFallbackCache();
 *   cache.prewarm(fallbackChain);
 *   const font = cache.getFontForBlock(UnicodeBlock.CJK_UNIFIED, '中', fallbackChain);
 */

import { FontFallbackChain } from './FontFallbackChain.ets';

/**
 * Unicode block categories for font fallback caching.
 * Maps major Unicode ranges that commonly need different fonts.
 */
export enum UnicodeBlock {
  /** U+0020–U+007E (Basic Latin: ASCII letters, digits, punctuation) */
  BASIC_LATIN = 0,
  /** U+00A0–U+00FF (Latin-1 Supplement: accented Latin) */
  LATIN_1_SUPPLEMENT = 1,
  /** U+4E00–U+9FFF (CJK Unified Ideographs) */
  CJK_UNIFIED = 2,
  /** U+3400–U+4DBF (CJK Extension A) */
  CJK_EXTENSION_A = 3,
  /** U+F900–U+FAFF (CJK Compatibility Ideographs) */
  CJK_COMPATIBILITY = 4,
  /** U+20000–U+2A6DF (CJK Extension B) */
  CJK_EXTENSION_B = 5,
  /** U+2F800–U+2FA1F (CJK Supplement) */
  CJK_SUPPLEMENT = 6,
  /** U+1F300–U+1F9FF (Emoticons, symbols, supplemental) */
  EMOJI = 7,
  /** U+0000–U+0020, U+007F–U+009F, and other non-Latin/CJK/Emoji control/whitespace */
  UNKNOWN = 8
}

/**
 * Maps a character to its UnicodeBlock category.
 *
 * @param char - Single character to classify
 * @returns The UnicodeBlock that this character belongs to
 */
export function classifyUnicodeBlock(char: string): UnicodeBlock {
  if (char.length === 0) {
    return UnicodeBlock.UNKNOWN;
  }

  const code: number = char.charCodeAt(0);

  // Basic Latin (ASCII printable): 0x20–0x7E
  if (code >= 0x0020 && code <= 0x007E) {
    return UnicodeBlock.BASIC_LATIN;
  }

  // Latin-1 Supplement: 0xA0–0xFF (excluding control chars 0x7F–0x9F)
  if (code >= 0x00A0 && code <= 0x00FF) {
    return UnicodeBlock.LATIN_1_SUPPLEMENT;
  }

  // CJK Unified Ideographs: U+4E00–U+9FFF
  if (code >= 0x4E00 && code <= 0x9FFF) {
    return UnicodeBlock.CJK_UNIFIED;
  }

  // CJK Extension A: U+3400–U+4DBF
  if (code >= 0x3400 && code <= 0x4DBF) {
    return UnicodeBlock.CJK_EXTENSION_A;
  }

  // CJK Compatibility Ideographs: U+F900–U+FAFF
  if (code >= 0xF900 && code <= 0xFAFF) {
    return UnicodeBlock.CJK_COMPATIBILITY;
  }

  // CJK Extension B: U+20000–U+2A6DF
  if (code >= 0x20000 && code <= 0x2A6DF) {
    return UnicodeBlock.CJK_EXTENSION_B;
  }

  // CJK Supplement: U+2F800–U+2FA1F
  if (code >= 0x2F800 && code <= 0x2FA1F) {
    return UnicodeBlock.CJK_SUPPLEMENT;
  }

  // Emoji ranges (common blocks)
  if ((code >= 0x1F300 && code <= 0x1F9FF) ||
    (code >= 0x2600 && code <= 0x27BF) ||
    (code >= 0xFE00 && code <= 0xFE0F) ||
    (code >= 0x1FA00 && code <= 0x1FAFF)) {
    return UnicodeBlock.EMOJI;
  }

  return UnicodeBlock.UNKNOWN;
}

/**
 * Cache of font family lookups keyed by UnicodeBlock.
 *
 * Prevents repeated calls to FontFallbackChain.findBestFont()
 * for each character in the same Unicode range during rendering.
 */
export class FontFallbackCache {
  /**
   * Internal cache: UnicodeBlock → font family name (or undefined for system default).
   * Uses undefined as a sentinel for "resolved but default" to distinguish from uncached.
   */
  private cache: Map<UnicodeBlock, string | undefined> = new Map();

  /**
   * Get the cached font for a Unicode block, or resolve and cache it.
   *
   * @param block - The Unicode block to look up
   * @param char - A representative character from this block (used for first-time resolution)
   * @param fallbackChain - FontFallbackChain instance for resolution
   * @returns Font family name, or undefined for system default
   */
  public getFontForBlock(
    block: UnicodeBlock,
    char: string,
    fallbackChain: FontFallbackChain
  ): string | undefined {
    // Check cache (undefined is a valid cached value meaning "system default")
    if (this.cache.has(block)) {
      return this.cache.get(block);
    }

    // Resolve and cache
    const font: string | undefined = fallbackChain.findBestFont(char);
    this.cache.set(block, font);
    return font;
  }

  /**
   * Pre-populate the cache for all known Unicode blocks.
   * Call this once after fonts are loaded (e.g., on book open).
   *
   * @param fallbackChain - FontFallbackChain instance for resolution
   */
  public prewarm(fallbackChain: FontFallbackChain): void {
    // Use representative characters for each block
    this.getFontForBlock(UnicodeBlock.BASIC_LATIN, 'A', fallbackChain);
    this.getFontForBlock(UnicodeBlock.LATIN_1_SUPPLEMENT, 'é', fallbackChain);
    this.getFontForBlock(UnicodeBlock.CJK_UNIFIED, '中', fallbackChain);
    this.getFontForBlock(UnicodeBlock.CJK_EXTENSION_A, '㐀', fallbackChain);
    this.getFontForBlock(UnicodeBlock.CJK_COMPATIBILITY, '豈', fallbackChain);
    this.getFontForBlock(UnicodeBlock.CJK_EXTENSION_B, '𠀀', fallbackChain);
    this.getFontForBlock(UnicodeBlock.CJK_SUPPLEMENT, '丽', fallbackChain);
    this.getFontForBlock(UnicodeBlock.EMOJI, '😀', fallbackChain);
    this.getFontForBlock(UnicodeBlock.UNKNOWN, '\u0000', fallbackChain);
  }

  /**
   * Clear the cache (e.g., when fonts are reloaded).
   */
  public clear(): void {
    this.cache.clear();
  }
}
