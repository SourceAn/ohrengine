/**
 * AnnotationExporter — 将标注列表导出为不同格式
 *
 * 提供以下静态方法：
 * - toJson(annotations): 标准 JSON 字符串
 * - toMarkdown(annotations, chapterTitles): Markdown 格式文本
 * - toCsv(annotations): CSV 表格文本
 * - toHtml(annotations, bookTitle, chapterTitles): HTML 格式
 * - toIncrementalMarkdown(annotations, chapterTitles, lastExportTime): 增量 Markdown
 * - toCustomTemplate(annotations, template, chapterTitles): 自定义模板导出
 */
import { Annotation } from 'ohrengine-common';

export interface TemplateContext {
  title: string;
  text: string;
  note: string;
  type: string;
  color: string;
}

interface GroupedAnnotations {
  title: string;
  annotations: Annotation[];
}

export class AnnotationExporter {
  /**
   * 导出为 JSON 字符串
   */
  static toJson(annotations: Annotation[]): string {
    return JSON.stringify(annotations, null, 2);
  }

  /**
   * 导出为 Markdown 字符串
   *
   * @param annotations - 标注列表
   * @param chapterTitles - 章节标题数组，按 chapterIndex 索引
   */
  static toMarkdown(annotations: Annotation[], chapterTitles: string[]): string {
    let md: string = '# 标注导出\n\n';
    for (let i: number = 0; i < annotations.length; i++) {
      const ann: Annotation = annotations[i];
      const chapIdx: number = ann.chapterIndex ?? 0;
      const title: string = chapIdx < chapterTitles.length ? chapterTitles[chapIdx] : ('章节 ' + chapIdx);
      const noteText: string | undefined = ann.noteText ?? ann.note;
      md += '## 标注 ' + (i + 1) + '\n';
      md += '- **类型**: ' + ann.type + '\n';
      md += '- **章节**: ' + title + '\n';
      md += '- **时间**: ' + AnnotationExporter.formatDate(ann) + '\n';
      if (ann.text !== undefined && ann.text !== '') {
        md += '- **原文**: ' + ann.text + '\n';
      }
      if (noteText !== undefined && noteText !== '') {
        md += '- **笔记**: ' + noteText + '\n';
      }
      md += '\n';
    }
    return md;
  }

  /**
   * 导出为 CSV 字符串
   */
  static toCsv(annotations: Annotation[]): string {
    const header: string = 'ID,类型,章节,字符偏移,原文,笔记,创建时间\n';
    let csv: string = header;
    for (let i: number = 0; i < annotations.length; i++) {
      const ann: Annotation = annotations[i];
      const type: string = ann.type;
      const chapterIdx: string = String(ann.chapterIndex ?? '');
      const charOff: string = String(ann.startCharOffset ?? '');
      const text: string = AnnotationExporter.escapeCsvField(ann.text ?? '');
      const note: string = AnnotationExporter.escapeCsvField(ann.noteText ?? ann.note ?? '');
      const created: string = AnnotationExporter.formatDate(ann);
      csv += ann.id + ',' + type + ',' + chapterIdx + ',' + charOff + ',' + text + ',' + note + ',' + created + '\n';
    }
    return csv;
  }

  /**
   * 格式化标注时间：优先使用 createdAt（epoch ms），回退到 created（ISO 字符串）
   */
  private static formatDate(ann: Annotation): string {
    if (ann.createdAt !== undefined) {
      return new Date(ann.createdAt).toISOString().replace('T', ' ').substring(0, 19);
    }
    return ann.created ?? '';
  }

  /**
   * CSV 字段转义：双引号包裹包含逗号/换行/双引号的字段
   */
  private static escapeCsvField(value: string): string {
    if (value.indexOf(',') >= 0 || value.indexOf('\n') >= 0 || value.indexOf('"') >= 0) {
      const escaped: string = value.replace(/"/g, '""');
      return '"' + escaped + '"';
    }
    return value;
  }

  /**
   * 按章节分组标注
   */
  private static groupByChapter(annotations: Annotation[], chapterTitles: string[]): GroupedAnnotations[] {
    const map: Map<number, Annotation[]> = new Map();
    for (let i: number = 0; i < annotations.length; i++) {
      const a: Annotation = annotations[i];
      const ci: number = a.chapterIndex ?? 0;
      let list: Annotation[] | undefined = map.get(ci);
      if (list === undefined) {
        list = [];
        map.set(ci, list);
      }
      list.push(a);
    }
    const keys: number[] = [];
    map.forEach((_val: Annotation[], key: number): void => {
      keys.push(key);
    });
    keys.sort((a: number, b: number): number => a - b);
    const result: GroupedAnnotations[] = [];
    for (let i: number = 0; i < keys.length; i++) {
      const ci: number = keys[i];
      const list: Annotation[] | undefined = map.get(ci);
      if (list !== undefined) {
        result.push({
          title: ci < chapterTitles.length ? chapterTitles[ci] : ('第' + (ci + 1) + '章'),
          annotations: list,
        });
      }
    }
    return result;
  }

  /**
   * 导出为 HTML 字符串（带样式，按章节分组）
   */
  static toHtml(annotations: Annotation[], bookTitle: string, chapterTitles: string[]): string {
    const grouped: GroupedAnnotations[] = AnnotationExporter.groupByChapter(annotations, chapterTitles);
    let html: string = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>'
      + AnnotationExporter.escapeHtml(bookTitle) + ' - 标注导出</title>'
      + '<style>'
      + 'body{max-width:720px;margin:0 auto;padding:20px;font-family:system-ui,sans-serif;line-height:1.6}'
      + '.hl{background:#FFEB3B44;padding:2px 0}'
      + '.ul{text-decoration:underline;text-decoration-color:#FF9800}'
      + '.note{border-left:3px solid #FF9800;padding:8px 16px;margin:8px 0;background:#FFF8E1;border-radius:4px}'
      + 'h2{margin-top:32px;color:#333}.meta{color:#888;font-size:14px}'
      + '</style></head><body>'
      + '<h1>' + AnnotationExporter.escapeHtml(bookTitle) + ' - 标注导出</h1>'
      + '<p class="meta">导出时间: ' + new Date().toISOString().replace('T', ' ').substring(0, 19)
      + ' | 总计: ' + annotations.length + ' 条</p>';
    for (let g: number = 0; g < grouped.length; g++) {
      const group: GroupedAnnotations = grouped[g];
      html += '<h2>' + AnnotationExporter.escapeHtml(group.title) + '</h2>';
      for (let a: number = 0; a < group.annotations.length; a++) {
        const ann: Annotation = group.annotations[a];
        const text: string = ann.text ?? '';
        if (ann.type === 'highlight') {
          html += '<blockquote class="hl">' + AnnotationExporter.escapeHtml(text) + '</blockquote>';
        } else if (ann.type === 'underline') {
          html += '<p class="ul">' + AnnotationExporter.escapeHtml(text) + '</p>';
        } else {
          html += '<blockquote class="hl">' + AnnotationExporter.escapeHtml(text) + '</blockquote>';
        }
        const noteText: string | undefined = ann.noteText ?? ann.note;
        if (noteText !== undefined && noteText.length > 0) {
          html += '<div class="note">' + AnnotationExporter.escapeHtml(noteText) + '</div>';
        }
      }
    }
    html += '</body></html>';
    return html;
  }

  /**
   * 增量导出 Markdown（仅返回 lastExportTime 之后的标注）
   */
  static toIncrementalMarkdown(annotations: Annotation[], chapterTitles: string[], lastExportTime: number): string {
    const filtered: Annotation[] = [];
    for (let i: number = 0; i < annotations.length; i++) {
      const ann: Annotation = annotations[i];
      if ((ann.createdAt ?? 0) > lastExportTime) {
        filtered.push(ann);
      }
    }
    if (filtered.length === 0) {
      return '# 增量导出\n\n本次无新增标注。\n';
    }
    let md: string = '# 增量导出（自 ' + AnnotationExporter.formatTimestamp(lastExportTime) + ' 以来）\n\n';
    md += '新增 ' + filtered.length + ' 条\n\n';
    md += AnnotationExporter.toMarkdown(filtered, chapterTitles);
    return md;
  }

  /**
   * 使用自定义模板导出标注
   *
   * 模板支持以下占位符:
   * - {title} — 章节标题
   * - {text} — 标注原文
   * - {note} — 笔记内容
   * - {type} — 标注类型（highlight / underline / note）
   * - {color} — 标注颜色
   *
   * @param annotations - 标注列表
   * @param template - 自定义模板字符串
   * @param chapterTitles - 章节标题数组
   * @returns 所有标注按模板渲染后以换行拼接
   */
  static toCustomTemplate(annotations: Annotation[], template: string, chapterTitles: string[]): string {
    const results: string[] = [];
    for (let i: number = 0; i < annotations.length; i++) {
      const ann: Annotation = annotations[i];
      const ctx: TemplateContext = AnnotationExporter.buildContext(ann, chapterTitles);
      results.push(parseCustomTemplate(template, ctx));
    }
    return results.join('\n');
  }

  /**
   * 构建 TemplateContext
   */
  private static buildContext(ann: Annotation, chapterTitles: string[]): TemplateContext {
    const chapIdx: number = ann.chapterIndex ?? 0;
    const title: string = chapIdx < chapterTitles.length ? chapterTitles[chapIdx] : ('第' + (chapIdx + 1) + '章');
    const text: string = ann.text ?? '';
    const note: string = ann.noteText ?? ann.note ?? '';
    const type: string = ann.type;
    const color: string = ann.color ?? '';
    return { title: title, text: text, note: note, type: type, color: color };
  }

  /**
   * HTML 转义
   */
  private static escapeHtml(text: string): string {
    return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  /**
   * 格式化时间戳（epoch ms → 本地可读字符串）
   */
  private static formatTimestamp(ts: number): string {
    return new Date(ts).toLocaleString();
  }
}

/**
 * 解析自定义模板，替换 {title} {text} {note} {type} {color} 占位符
 *
 * @param template - 模板字符串，如 "{type}: {text}  ({title})"
 * @param ctx - 占位符上下文
 * @returns 替换后的字符串
 */
export function parseCustomTemplate(template: string, ctx: TemplateContext): string {
  let result: string = template;
  result = result.replace(/\{title\}/g, ctx.title);
  result = result.replace(/\{text\}/g, ctx.text);
  result = result.replace(/\{note\}/g, ctx.note);
  result = result.replace(/\{type\}/g, ctx.type);
  result = result.replace(/\{color\}/g, ctx.color);
  return result;
}
