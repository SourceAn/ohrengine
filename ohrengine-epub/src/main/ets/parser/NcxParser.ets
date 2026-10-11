/**
 * NcxParser — EPUB 2 NCX 导航解析器
 *
 * 解析 NCX XML 文件，提取 <navMap>/<navPoint> 层次结构，
 * 转换为 TocItem[]（扁平或嵌套目录）。
 */
import { XmlElement, parseXmlToDom, querySelector, querySelectorAll } from './XmlDomParser.ets';
import { TocItem } from 'ohrengine-common';

/** NCX 解析器 */
export class NcxParser {
  /**
   * 解析 NCX XML 字符串为 TocItem 列表
   * @param ncxXml NCX XML 内容
   * @returns 目录项列表（带 children 嵌套）
   */
  public parse(ncxXml: string): TocItem[] {
    const root: XmlElement | undefined = parseXmlToDom(ncxXml);
    if (root === undefined) return [];

    // 查找 <navMap>
    const navMap: XmlElement | undefined = querySelector(root, 'navMap');
    if (navMap === undefined) return [];

    return this.parseNavPoints(navMap);
  }

  /**
   * 递归解析 <navPoint> 列表
   */
  private parseNavPoints(parent: XmlElement): TocItem[] {
    const result: TocItem[] = [];
    for (let i = 0; i < parent.children.length; i++) {
      const child: XmlElement = parent.children[i];
      if (child.tagName !== 'navPoint') continue;
      const item: TocItem | undefined = this.parseNavPoint(child);
      if (item !== undefined) result.push(item);
    }
    return result;
  }

  /**
   * 解析单个 <navPoint>
   */
  private parseNavPoint(navPoint: XmlElement): TocItem | undefined {
    const navLabel: XmlElement | undefined = this.findChild(navPoint, 'navLabel');
    if (navLabel === undefined) return undefined;
    const text: XmlElement | undefined = this.findChild(navLabel, 'text');
    const title: string = text !== undefined ? text.textContent.trim() : '';

    const content: XmlElement | undefined = this.findChild(navPoint, 'content');
    const href: string = content !== undefined
      ? (content.attributes['src'] ?? '')
      : '';

    // 递归解析子 navPoint
    const children: TocItem[] = [];
    for (let i = 0; i < navPoint.children.length; i++) {
      const sub: XmlElement = navPoint.children[i];
      if (sub.tagName === 'navPoint') {
        const subItem: TocItem | undefined = this.parseNavPoint(sub);
        if (subItem !== undefined) children.push(subItem);
      }
    }

    return {
      title: title,
      href: href,
      children: children.length > 0 ? children : undefined,
    };
  }

  /** 在子元素中查找第一个匹配 tagName 的 */
  private findChild(parent: XmlElement, tagName: string): XmlElement | undefined {
    for (let i = 0; i < parent.children.length; i++) {
      if (parent.children[i].tagName === tagName) return parent.children[i];
    }
    return undefined;
  }
}
