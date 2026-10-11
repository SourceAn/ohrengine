/**
 * Readium Manifest 模型
 * 参考：Readium Manifest.kt + PublicationCollection.kt
 *
 * Manifest 是 EPUB 的核心索引结构，包含：
 * - metadata：图书元数据
 * - links：服务链接（self、opds、搜索等）
 * - readingOrder：默认阅读顺序
 * - resources：所有静态资源清单
 * - tableOfContents：目录层级结构
 * - landmarks：地标导航
 * - pageList，list（音频）等
 */

import { Link, createLink } from './Link.ets';
import { Metadata, createMetadata, Contributor } from './Metadata.ets';

export interface Manifest {
  metadata: Metadata;
  links: Link[];
  readingOrder: Link[];
  resources: Link[];
  tableOfContents: Link[];
  subcollections: Record<string, Object[]> | undefined;
  landmarks: Link[] | undefined;
  pageList: Link[] | undefined;
  list: Link[] | undefined;
}

export function createManifest(title: string): Manifest {
  return {
    metadata: createMetadata(title),
    links: [],
    readingOrder: [],
    resources: [],
    tableOfContents: [],
    subcollections: undefined,
    landmarks: undefined,
    pageList: undefined,
    list: undefined
  };
}

/**
 * 获取阅读顺序中的所有资源路径
 */
export function getReadingOrderHrefs(manifest: Manifest): string[] {
  const result: string[] = [];
  for (let i = 0; i < manifest.readingOrder.length; i++) {
    result.push(manifest.readingOrder[i].href);
  }
  return result;
}

/**
 * 按 href 在阅读顺序中查找 Link
 */
export function findLinkByHref(manifest: Manifest, href: string): Link | undefined {
  const allLinks: Link[] = manifest.readingOrder.concat(manifest.resources);
  for (let i = 0; i < allLinks.length; i++) {
    if (allLinks[i].href === href) {
      return allLinks[i];
    }
  }
  return undefined;
}

/**
 * 获取 spine 中 mediaType 为 application/xhtml+xml 的资源
 */
export function getHtmlReadingOrder(manifest: Manifest): Link[] {
  const result: Link[] = [];
  for (let i = 0; i < manifest.readingOrder.length; i++) {
    const link: Link = manifest.readingOrder[i];
    if (link.mediaType === 'application/xhtml+xml' || link.mediaType === 'text/html') {
      result.push(link);
    }
  }
  return result;
}

/**
 * 获取封面图片链接
 */
export function findCoverLink(manifest: Manifest): Link | undefined {
  for (let i = 0; i < manifest.resources.length; i++) {
    const link: Link = manifest.resources[i];
    if (link.rels.indexOf('cover') >= 0) {
      return link;
    }
    if (link.properties !== undefined && link.properties.page === 'cover') {
      return link;
    }
  }
  return undefined;
}
