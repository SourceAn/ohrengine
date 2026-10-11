/**
 * Bookmark — value-object interface for reading position bookmarks
 */
export interface Bookmark {
  id: string;
  chapterIndex: number;
  charOffset: number;        // 本章内字符偏移（字号/边距无关，唯一锚点）
  chapterHref?: string;
  textPreview?: string;      // 书签处的文本预览
  title?: string;            // 用户自定义标题
  createdAt: number;
  type: 'bookmark' | 'highlight' | 'note';
  color?: string;
  note?: string;
}
