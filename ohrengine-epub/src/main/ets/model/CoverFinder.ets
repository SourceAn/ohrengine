import { Publication } from 'ohrengine-common';
import { Link } from 'ohrengine-common';
import { OpfMeta } from 'ohrengine-common';

export interface CoverResult {
  path: string;
  mimeType: string;
  source: 'meta' | 'guide' | 'spine' | 'heuristic';
  /** 封面是否为 HTML 页面（需要进一步提取图片） */
  needsHtmlParsing?: boolean;
}

/**
 * 封面查找器 — 四级定位
 * 优先级：OPF meta → guide → spine 首项 → 文件名启发式
 */
export class CoverFinder {
  findCover(pub: Publication): CoverResult | null {
    // 1) OPF metadata 中 <meta name="cover" content="cover-image-id"/>
    const coverId = this.findCoverIdFromMeta(pub);
    if (coverId) {
      const item: Link | undefined = pub.manifest?.resources
        ?.find(r => r.id === coverId);
      if (item) {
        return { path: item.href, mimeType: item.mediaType, source: 'meta' };
      }
    }
    // 2) OPF guide 中 <reference type="cover" href="..."/>
    const guideRef: Link | undefined = pub.guide?.references
      ?.find(r => r.type === 'cover');
    if (guideRef) {
      return { path: guideRef.href, mimeType: 'application/xhtml+xml',
        source: 'guide', needsHtmlParsing: true };
    }
    // 3) spine 首项（可能是封面 HTML）
    const firstSpine: Link | undefined = pub.spine?.items?.[0];
    if (firstSpine) {
      return { path: firstSpine.href, mimeType: 'application/xhtml+xml',
        source: 'spine', needsHtmlParsing: true };
    }
    // 4) 文件名启发式
    return this.findByFilename(pub);
  }

  private findCoverIdFromMeta(pub: Publication): string | undefined {
    const metas: OpfMeta[] = pub.metadata?.meta ?? [];
    const m = metas.find(x => x.name === 'cover');
    if (m?.content) return m.content;
    const p = metas.find(x => x.property === 'cover');
    if (p?.id) return p.id;
    return undefined;
  }

  private findByFilename(pub: Publication): CoverResult | null {
    const keywords = ['cover', 'front', 'jacket'];
    const exts = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg'];
    for (const r of pub.manifest?.resources ?? []) {
      const name: string = (r.href.split('/').pop() ?? '').toLowerCase();
      if (exts.some(e => name.endsWith(e)) && keywords.some(k => name.includes(k))) {
        return { path: r.href, mimeType: r.mediaType, source: 'heuristic' };
      }
    }
    return null;
  }
}
