/**
 * ImageRenderer — Image page rendering helper
 *
 * Renders image-based pages (CBZ/CBR) by loading images from
 * a ParsedBook chapter's href and preparing them for display
 * in the UI layer.
 *
 * Used by ImageRouter and the UI layer to convert raw image
 * chapters into displayable ImageBitmap data.
 */

import { ParsedBook } from 'ohrengine-common';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * Result of rendering a single image page.
 */
export interface ImagePageResult {
  /** Chapter index this image belongs to */
  chapterIndex: number;
  /** The loaded image pixel map, or undefined on failure */
  pixelMap: image.PixelMap | undefined;
  /** Error message if loading failed */
  error: string | undefined;
}

/**
 * ImageRenderer — loads and pre-processes image pages.
 */
export class ImageRenderer {
  /**
   * Load a single image chapter from a parsed book.
   *
   * @param book - The parsed book containing image chapters
   * @param chapterIndex - Index of the chapter (image) to load
   * @param bookBasePath - Base path of the book file for resolving relative hrefs
   * @returns ImagePageResult with the pixel map or error
   */
  static async loadImagePage(
    book: ParsedBook,
    chapterIndex: number,
    bookBasePath: string
  ): Promise<ImagePageResult> {
    if (chapterIndex < 0 || chapterIndex >= book.chapters.length) {
      return {
        chapterIndex: chapterIndex,
        pixelMap: undefined,
        error: 'Chapter index out of range: ' + String(chapterIndex)
      } as ImagePageResult;
    }

    const href: string = book.chapters[chapterIndex].href;
    const fullPath: string = ImageRenderer.resolveImagePath(href, bookBasePath);

    try {
      const file: fileIo.File = fileIo.openSync(fullPath, fileIo.OpenMode.READ_ONLY);
      const fileSize: number = fileIo.statSync(fullPath).size;
      const buf: ArrayBuffer = new ArrayBuffer(fileSize);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);

      const imageSource: image.ImageSource = image.createImageSource(buf);
      const pixelMap: image.PixelMap = await imageSource.createPixelMap();
      imageSource.release();

      return {
        chapterIndex: chapterIndex,
        pixelMap: pixelMap,
        error: undefined
      } as ImagePageResult;
    } catch (e) {
      return {
        chapterIndex: chapterIndex,
        pixelMap: undefined,
        error: String(e)
      } as ImagePageResult;
    }
  }

  /**
   * Resolve an image href relative to the book base path.
   */
  private static resolveImagePath(href: string, bookBasePath: string): string {
    if (href.startsWith('/')) {
      return href;
    }
    // Extract directory from bookBasePath
    const lastSlash: number = bookBasePath.lastIndexOf('/');
    const baseDir: string = lastSlash >= 0 ? bookBasePath.substring(0, lastSlash + 1) : '';
    return baseDir + href;
  }
}
