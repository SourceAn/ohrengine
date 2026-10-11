/**
 * 资源链接模型
 * 参考：Readium Link 数据类型
 *
 * 描述 EPUB 清单中单个资源的链接：
 * 包含 href（相对路径）、mediaType、title、rels（关系类型）
 * 以及属性集合（properties），用于自适应排版或子资源选择
 */

export interface Properties {
  orientation: string | undefined;
  page: string | undefined;
  mediaOverlay: string | undefined;
  contains: string[];
  layout: string | undefined;
  encrypted: Record<string, string> | undefined;
}

export function createDefaultProperties(): Properties {
  return {
    orientation: undefined,
    page: undefined,
    mediaOverlay: undefined,
    contains: [],
    layout: undefined,
    encrypted: undefined
  };
}

export interface Link {
  href: string;
  mediaType: string;
  title: string | undefined;
  rels: string[];
  properties: Properties | undefined;
  alternates: Link[];
  children: Link[];
  height: number | undefined;
  width: number | undefined;
  duration: number | undefined;
  bitrate: number | undefined;
  language: string | undefined;
  templated: boolean;
  /** OPF manifest item id */
  id: string | undefined;
  /** OPF guide reference type */
  type: string | undefined;
}

export function createLink(href: string, mediaType: string): Link {
  return {
    href: href,
    mediaType: mediaType,
    title: undefined,
    rels: [],
    properties: undefined,
    alternates: [],
    children: [],
    height: undefined,
    width: undefined,
    duration: undefined,
    bitrate: undefined,
    language: undefined,
    templated: false,
    id: undefined,
    type: undefined
  };
}

export function createLinkWithTitle(href: string, mediaType: string, title: string): Link {
  return {
    href: href,
    mediaType: mediaType,
    title: title,
    rels: [],
    properties: undefined,
    alternates: [],
    children: [],
    height: undefined,
    width: undefined,
    duration: undefined,
    bitrate: undefined,
    language: undefined,
    templated: false,
    id: undefined,
    type: undefined
  };
}

export function createLinkFromJson(json: Record<string, Object>): Link {
  const href: string = (json['href'] as string) ?? '';
  const mediaType: string = (json['type'] as string) ?? 'application/octet-stream';
  const link: Link = createLink(href, mediaType);
  link.title = json['title'] as string | undefined;
  if (json['rel'] !== undefined) {
    const rel: string = json['rel'] as string;
    link.rels = [rel];
  }
  if (json['properties'] !== undefined) {
    const props: Record<string, Object> = json['properties'] as Record<string, Object>;
    link.properties = createDefaultProperties();
    link.properties.orientation = props['orientation'] as string | undefined;
    link.properties.page = props['page'] as string | undefined;
    if (props['contains'] !== undefined) {
      link.properties.contains = props['contains'] as string[];
    }
  }
  return link;
}
