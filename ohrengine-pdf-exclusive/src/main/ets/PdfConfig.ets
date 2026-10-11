/**
 * PdfConfig — PDF format configuration (stub)
 *
 * Placeholder configuration namespace for future PDF support.
 */

/**
 * PDF configuration — stub values; actual tuning happens with the
 * real PDF implementation.
 */
export namespace PdfConfig {
  /** PDF default rendering DPI */
  export const defaultDpi: number = 72;
  /** PDF 已支持：文本层可提取的可重排渲染（2026-08 实现，PdfParser 文本提取） */
  export const supported: boolean = true;
  /** Maximum cached rendered pages (stub default) */
  export const maxCachedPages: number = 8;
}
