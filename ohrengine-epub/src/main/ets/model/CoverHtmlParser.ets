/**
 * 从封面 HTML/SVG 中提取封面图片路径
 */
export class CoverHtmlParser {
  extractCoverImage(html: string, basePath: string): string | null {
    // SVG <image href="...">
    const svgMatch = html.match(
      /<svg[^>]*>[\s\S]*?<image[^>]+href="([^"]+)"/i
    );
    if (svgMatch) return this.resolvePath(basePath, svgMatch[1]);
    // <img src="...">
    const imgMatch = html.match(
      /<img[^>]+src="([^"]+)"/i
    );
    if (imgMatch) return this.resolvePath(basePath, imgMatch[1]);
    return null;
  }

  private resolvePath(base: string, relative: string): string {
    if (relative.startsWith('/')) return relative.substring(1);
    if (relative.startsWith('http')) return relative;
    const baseDir = base.substring(0, base.lastIndexOf('/') + 1);
    return baseDir + relative;
  }
}
