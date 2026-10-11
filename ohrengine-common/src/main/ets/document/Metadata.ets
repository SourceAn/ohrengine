/**
 * 图书元数据模型
 * 参考：Readium Metadata 数据类型 + crengine lvdocview 缩略版
 *
 * 包含 EPUB 的核心元数据字段：
 * 标识符、标题、作者、语言、出版信息、封面等
 * 简化版本：不支持多作者（contributors）展开
 */

export interface Contributor {
  name: string;
  role: string | undefined;
  fileAs: string | undefined;
}

export function createContributor(name: string): Contributor {
  return { name: name, role: undefined, fileAs: undefined };
}

/**
 * 原始 OPF meta 元素
 */
export interface OpfMeta {
  name: string | undefined;
  content: string | undefined;
  property: string | undefined;
  id: string | undefined;
}

export interface Metadata {
  identifier: string | undefined;
  title: string;
  subtitle: string | undefined;
  sortAs: string | undefined;
  authors: Contributor[];
  translators: Contributor[];
  editors: Contributor[];
  artists: Contributor[];
  illustrators: Contributor[];
  letterers: Contributor[];
  pencilers: Contributor[];
  colorists: Contributor[];
  narrators: Contributor[];
  contributors: Contributor[];
  publisher: Contributor | undefined;
  imprint: Contributor | undefined;
  language: string[];
  languages: string[];
  modified: string | undefined;
  published: string | undefined;
  publicationDate: string | undefined;
  description: string | undefined;
  subjects: string[];
  subjectsAlt: Record<string, string>[];
  collections: Record<string, string>[];
  readingProgression: string | undefined;
  pageCount: number | undefined;
  duration: number | undefined;
  numberOfPages: number | undefined;
  source: string | undefined;
  rights: string | undefined;
  rendition: Record<string, Object> | undefined;
  meta: OpfMeta[];
}

export function createMetadata(title: string): Metadata {
  return {
    identifier: undefined,
    title: title,
    subtitle: undefined,
    sortAs: undefined,
    authors: [],
    translators: [],
    editors: [],
    artists: [],
    illustrators: [],
    letterers: [],
    pencilers: [],
    colorists: [],
    narrators: [],
    contributors: [],
    publisher: undefined,
    imprint: undefined,
    language: [],
    languages: [],
    modified: undefined,
    published: undefined,
    publicationDate: undefined,
    description: undefined,
    subjects: [],
    subjectsAlt: [],
    collections: [],
    readingProgression: 'auto',
    pageCount: undefined,
    duration: undefined,
    numberOfPages: undefined,
    source: undefined,
    rights: undefined,
    rendition: undefined,
    meta: []
  };
}

export function getAuthorDisplayName(metadata: Metadata): string {
  if (metadata.authors.length > 0) {
    return metadata.authors[0].name;
  }
  return '';
}

export function getLanguageDisplay(metadata: Metadata): string {
  if (metadata.language.length > 0) {
    return metadata.language[0];
  }
  return '';
}
