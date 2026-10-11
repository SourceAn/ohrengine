/**
 * PdfRenderer — fixed-layout renderer (stub)
 *
 * Reserved for future fixed-layout PDF page rendering.
 * Every invocation throws NotImplementedError.
 */

/**
 * PDF fixed-layout renderer stub — reserved for future implementation.
 */
export class PdfRenderer {
  /**
   * Render a single PDF page.
   *
   * @param pageIndex - Zero-based page index
   */
  render(pageIndex: number): void {
    throw new Error('NotImplementedError: PdfRenderer.render — PDF support is reserved for future use. pageIndex=' + String(pageIndex));
  }
}
