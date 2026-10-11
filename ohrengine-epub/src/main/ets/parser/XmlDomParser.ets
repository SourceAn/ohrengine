/**
 * XmlDomParser — 轻量级 XML DOM 解析器
 *
 * 基于 @kit.ArkTS xml.XmlPullParser（回调式 API）将 XML 字符串解析为 DOM 树。
 * 提供 querySelector/querySelectorAll 用于标签名查询。
 */
import { xml } from '@kit.ArkTS';
import { util } from '@kit.ArkTS';

/** DOM 元素节点 */
export interface XmlElement {
  tagName: string;
  attributes: Record<string, string>;
  textContent: string;
  children: XmlElement[];
  parentElement: XmlElement | undefined;
}

// ── 解析器内部状态 ──────────────────────────────────────────

class XmlDomBuilder {
  public stack: XmlElement[] = [];
  public root: XmlElement | undefined = undefined;

  // 由 tagValueCallback 暂存的名字（可能是 tagName 或 text）
  public pendingName: string = '';
  // 由 attributeValueCallback 累加的属性
  public pendingAttrs: Record<string, string> = {};

  /** tagValueCallbackFunction — 接收标签名或文本 */
  public onTagValue(name: string, _value: string): boolean {
    this.pendingName = name;
    return true;
  }

  /** attributeValueCallbackFunction — 接收属性键值对 */
  public onAttribute(name: string, value: string): boolean {
    this.pendingAttrs[name] = value;
    return true;
  }

  /** tokenValueCallbackFunction — 处理 START_TAG / TEXT / END_TAG 事件 */
  public onToken(eventType: xml.EventType, _info: xml.ParseInfo): boolean {
    if (eventType === xml.EventType.START_TAG) {
      // pendingName 此时是标签名，pendingAttrs 是已收集的属性
      const attrs: Record<string, string> = this.pendingAttrs;
      this.pendingAttrs = {}; // 重置
      const el: XmlElement = {
        tagName: this.pendingName,
        attributes: attrs,
        textContent: '',
        children: [],
        parentElement: undefined,
      };
      if (this.stack.length > 0) {
        const parent: XmlElement = this.stack[this.stack.length - 1];
        el.parentElement = parent;
        parent.children.push(el);
      }
      this.stack.push(el);
      if (this.root === undefined) {
        this.root = el;
      }
    } else if (eventType === xml.EventType.TEXT) {
      // pendingName 此时是文本内容
      if (this.stack.length > 0) {
        this.stack[this.stack.length - 1].textContent += this.pendingName;
      }
    } else if (eventType === xml.EventType.END_TAG) {
      this.stack.pop();
    }
    return true;
  }
}

/**
 * 将 XML 字符串解析为 DOM 树
 * @param xmlStr XML 字符串
 * @returns 根元素（无有效根时返回 undefined）
 */
export function parseXmlToDom(xmlStr: string): XmlElement | undefined {
  // 1) 编码为 ArrayBuffer
  const textEncoder: util.TextEncoder = new util.TextEncoder();
  const uint8Arr: Uint8Array = textEncoder.encodeInto(xmlStr);
  const buf: ArrayBuffer = uint8Arr.buffer as object as ArrayBuffer;

  // 2) 构造解析器
  const parser: xml.XmlPullParser = new xml.XmlPullParser(buf, 'UTF-8');

  // 3) 用状态机关联回调
  const builder: XmlDomBuilder = new XmlDomBuilder();

  const options: xml.ParseOptions = {
    supportDoctype: true,
    ignoreNameSpace: true,
    tagValueCallbackFunction: (name: string, value: string): boolean => builder.onTagValue(name, value),
    attributeValueCallbackFunction: (name: string, value: string): boolean => builder.onAttribute(name, value),
    tokenValueCallbackFunction: (eventType: xml.EventType, info: xml.ParseInfo): boolean =>
      builder.onToken(eventType, info),
  };

  // 4) 执行解析（parseXml 替代废弃的 parse，API 14+）
  parser.parseXml(options);
  return builder.root;
}

/**
 * 在 DOM 树中查找第一个匹配标签名的元素（DFS 前序）
 */
export function querySelector(root: XmlElement | undefined, tagName: string): XmlElement | undefined {
  if (root === undefined) return undefined;
  if (root.tagName === tagName) return root;
  for (let i = 0; i < root.children.length; i++) {
    const found: XmlElement | undefined = querySelector(root.children[i], tagName);
    if (found !== undefined) return found;
  }
  return undefined;
}

/**
 * 在 DOM 树中查找所有匹配标签名的元素（DFS 前序）
 */
export function querySelectorAll(root: XmlElement | undefined, tagName: string): XmlElement[] {
  const result: XmlElement[] = [];
  if (root === undefined) return result;
  if (root.tagName === tagName) result.push(root);
  for (let i = 0; i < root.children.length; i++) {
    const found: XmlElement[] = querySelectorAll(root.children[i], tagName);
    for (let j = 0; j < found.length; j++) {
      result.push(found[j]);
    }
  }
  return result;
}
