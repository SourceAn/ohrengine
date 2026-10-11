/**
 * FontFallbackChain — Character-range-based font selection
 *
 * Provides a font resolution service that maps individual characters
 * to the most appropriate registered font based on script category:
 * CJK → Latin → Emoji → system default.
 *
 * Priority order (within each category):
 *   exact match (future: unicode-range) → CJK → Latin → Emoji → system default
 *
 * Usage:
 *   const chain = new FontFallbackChain();
 *   chain.addFont('SourceHanSerif');
 *   chain.addFont('NotoSans');
 *   const font = chain.resolveFont('中'); // returns 'SourceHanSerif'
 */

import { FontLoader } from './FontLoader.ets';

/**
 * A contiguous segment of text that should be rendered with the same font.
 */
export interface TextSegment {
  /** The text content of this segment */
  text: string;
  /** The font family to use, or undefined for system default */
  fontFamily: string | undefined;
  /** Start index in the original text */
  startIndex: number;
  /** End index (exclusive) in the original text */
  endIndex: number;
}

/**
 * Describes a system-installed font for glyph availability checking.
 * Used internally by findBestFont() to validate font support.
 */
export interface SystemFontInfo {
  /** Font family name */
  family: string;
  /** Optional callback to check if this font has a specific glyph */
  hasGlyph?: (char: string) => boolean;
}

/**
 * Describes a loaded (custom) font for glyph availability checking.
 * Passed from outside to enable hasGlyph checks in findBestFont().
 */
export interface LoadedFontInfo {
  /** Font family name */
  familyName: string;
  /** Optional callback to check if this font has a specific glyph */
  hasGlyph?: (char: string) => boolean;
}

/**
 * Manages a prioritized font fallback chain for character-based font selection.
 */
export class FontFallbackChain {
  /**
   * Registered font families in registration order.
   */
  private families: string[] = [];

  /**
   * Register a loaded font family into the fallback chain.
   *
   * @param familyName - The font family name as declared in @font-face
   */
  public addFont(familyName: string): void {
    // Avoid duplicates
    if (this.families.indexOf(familyName) === -1) {
      this.families.push(familyName);
    }
  }

  /**
   * Resolve the best font for a given character.
   *
   * Returns the family name of the most appropriate registered font,
   * or `undefined` to fall back to the system default font.
   *
   * @param char - A single character to resolve
   * @returns Font family name, or undefined for system default
   */
  public resolveFont(char: string): string | undefined {
    return this.findBestFont(char, undefined);
  }

  /**
   * Get the full list of registered font families (for logging).
   */
  public getFamilies(): string[] {
    return this.families;
  }

  /**
   * Find the best font for a single character.
   *
   * Resolves by priority:
   *   1. fontFamilyList (CSS font-family) — loadedFonts[hasGlyph] → registered fonts
   *   2. Character range — CJK / Latin / Emoji → last registered font
   *   3. System default (undefined)
   *
   * @param char - Single character to resolve
   * @param fontFamilyList - Optional CSS font-family list from HTML/CSS
   * @param loadedFonts - Optional list of loaded fonts with hasGlyph check
   * @returns Font family name, or undefined for system default
   */
  public findBestFont(
    char: string,
    fontFamilyList?: string[],
    loadedFonts?: LoadedFontInfo[],
    fontLoader?: FontLoader
  ): string | undefined {
    if (char.length === 0 || this.families.length === 0) {
      return undefined;
    }

    const code: number = char.charCodeAt(0);

    // Priority 1: Check fontFamilyList — loadedFonts first, then registered
    if (fontFamilyList !== undefined) {
      for (let i = 0; i < fontFamilyList.length; i++) {
        const family: string = fontFamilyList[i].replace(/['"]/g, '');
        // Check loadedFonts with hasGlyph first
        if (loadedFonts !== undefined) {
          const loaded: LoadedFontInfo | undefined = loadedFonts.find(f => f.familyName === family);
          if (loaded !== undefined) {
            // Validate unicode-range if fontLoader is available
            if (fontLoader !== undefined) {
              const matched: string | undefined = fontLoader.getFontForChar(char, family);
              if (matched === undefined) {
                continue; // 该字体 unicode-range 不覆盖此字符
              }
            }
            if (loaded.hasGlyph === undefined || loaded.hasGlyph(char)) {
              return family;
            }
            continue;
          }
        }
        // Fall back to registered fonts
        if (this.families.indexOf(family) !== -1) {
          // Validate unicode-range if fontLoader is available
          if (fontLoader !== undefined) {
            const matched: string | undefined = fontLoader.getFontForChar(char, family);
            if (matched !== undefined) {
              return matched;
            }
            continue; // 该字体 unicode-range 不覆盖此字符
          }
          return family;
        }
      }
    }

    // Priority 2: Range-based fallback to the most recently registered font
    const preferredFamily: string | undefined = this.families[this.families.length - 1];

    if (preferredFamily !== undefined && fontLoader !== undefined) {
      // Validate fallback font against unicode-range
      const matched: string | undefined = fontLoader.getFontForChar(char, preferredFamily);
      if (matched === undefined) {
        return undefined; // fallback 字体也不覆盖此字符 → 系统默认
      }
    }

    if (FontFallbackChain.isCjk(code)) {
      return preferredFamily;
    }

    if (FontFallbackChain.isLatin(code)) {
      return preferredFamily;
    }

    if (FontFallbackChain.isEmoji(code)) {
      return preferredFamily;
    }

    return undefined;
  }

  /**
   * Segment text into consecutive runs that share the same resolved font.
   *
   * @param text - The text string to segment
   * @param fontFamilyList - Optional CSS font-family list from HTML/CSS
   * @param loadedFonts - Optional list of loaded fonts with hasGlyph checks
   * @returns Array of TextSegments, each with a consistent fontFamily
   */
  public resolveTextSegments(
    text: string,
    fontFamilyList?: string[],
    loadedFonts?: LoadedFontInfo[],
    fontLoader?: FontLoader
  ): TextSegment[] {
    if (text.length === 0) {
      return [];
    }

    const segments: TextSegment[] = [];
    let currentFont: string | undefined = undefined;
    let segmentStart: number = 0;

    for (let i = 0; i < text.length; i++) {
      const font: string | undefined = this.findBestFont(text[i], fontFamilyList, loadedFonts, fontLoader);

      if (i === 0) {
        currentFont = font;
      } else if (font !== currentFont) {
        segments.push({
          text: text.substring(segmentStart, i),
          fontFamily: currentFont,
          startIndex: segmentStart,
          endIndex: i
        });
        segmentStart = i;
        currentFont = font;
      }
    }

    // Push the final segment
    segments.push({
      text: text.substring(segmentStart),
      fontFamily: currentFont,
      startIndex: segmentStart,
      endIndex: text.length
    });

    return segments;
  }

  /**
   * Check if a Unicode code point is CJK (CJK Unified Ideographs + extensions).
   *
   * Ranges:
   *   CJK Unified Ideographs:          U+4E00–U+9FFF
   *   CJK Extension A:                 U+3400–U+4DBF
   *   CJK Compatibility Ideographs:    U+F900–U+FAFF
   *   CJK Extension B:                 U+20000–U+2A6DF
   *   CJK Supplement:                  U+2F800–U+2FA1F
   */
  private static isCjk(code: number): boolean {
    return (code >= 0x4E00 && code <= 0x9FFF) ||
      (code >= 0x3400 && code <= 0x4DBF) ||
      (code >= 0xF900 && code <= 0xFAFF) ||
      (code >= 0x20000 && code <= 0x2A6DF) ||
      (code >= 0x2F800 && code <= 0x2FA1F);
  }

  /**
   * Check if a Unicode code point is Latin (Basic + Extended).
   *
   * Ranges:
   *   Basic Latin:                     U+0041–U+005A (A-Z), U+0061–U+007A (a-z)
   *   Latin-1 Supplement:              U+00C0–U+024F (accented Latin)
   */
  private static isLatin(code: number): boolean {
    return (code >= 0x0041 && code <= 0x005A) ||
      (code >= 0x0061 && code <= 0x007A) ||
      (code >= 0x00C0 && code <= 0x024F);
  }

  /**
   * Check if a Unicode code point is an Emoji character.
   *
   * Ranges (common emoji blocks):
   *   Emoticons:                       U+1F600–U+1F64F
   *   Miscellaneous Symbols:           U+1F300–U+1F5FF
   *   Transport & Map Symbols:         U+1F680–U+1F6FF
   *   Miscellaneous Symbols:           U+2600–U+26FF
   *   Dingbats:                        U+2700–U+27BF
   *   Variation Selectors:             U+FE00–U+FE0F
   *   Supplemental Symbols:            U+1F900–U+1F9FF
   *   Extended-A:                      U+1FA00–U+1FA6F
   *   Extended-B:                      U+1FA70–U+1FAFF
   */
  private static isEmoji(code: number): boolean {
    return (code >= 0x1F600 && code <= 0x1F64F) ||
      (code >= 0x1F300 && code <= 0x1F5FF) ||
      (code >= 0x1F680 && code <= 0x1F6FF) ||
      (code >= 0x2600 && code <= 0x26FF) ||
      (code >= 0x2700 && code <= 0x27BF) ||
      (code >= 0xFE00 && code <= 0xFE0F) ||
      (code >= 0x1F900 && code <= 0x1F9FF) ||
      (code >= 0x1FA00 && code <= 0x1FA6F) ||
      (code >= 0x1FA70 && code <= 0x1FAFF);
  }
}
