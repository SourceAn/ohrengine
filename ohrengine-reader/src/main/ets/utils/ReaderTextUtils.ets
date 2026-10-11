import type { LineBox } from 'ohrengine-common';
import type { SelectionRange } from 'ohrengine-feature';

/**
 * ReaderTextUtils — 选区 / 文本判定纯工具（从 Index 拆分）。
 * 无 UI 依赖，仅文本与行盒计算。
 */
export class ReaderTextUtils {
  /** 判断选区是否需要显示翻译（非系统语言） */
  static isNonSystemLanguage(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    // 简化的脚本判定：含 CJK 视为中文，其余视为非中文
    let hasCJK: boolean = false;
    for (let i = 0; i < Math.min(text.length, 64); i++) {
      const code: number = text.charCodeAt(i);
      if ((code >= 0x4E00 && code <= 0x9FFF) || (code >= 0x3400 && code <= 0x4DBF)) {
        hasCJK = true;
        break;
      }
    }
    // 系统 UI 语言（简化为中文设备）：系统语言为中文 → 非中文文本显示翻译
    const sysLang: string = 'zh';
    if (sysLang === 'zh') {
      return !hasCJK && ReaderTextUtils.hasLetters(text);
    }
    return hasCJK;
  }

  /** 文本是否含拉丁字母 */
  static hasLetters(text: string): boolean {
    for (let i = 0; i < Math.min(text.length, 64); i++) {
      const code: number = text.charCodeAt(i);
      if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
        return true;
      }
    }
    return false;
  }

  /** 是否为单词（无空白） */
  static isSingleWord(text: string): boolean {
    return text.length > 0 && !text.includes(' ') && !text.includes('\t') && !text.includes('\n');
  }

  /** 依据当前页行盒重建选区文本（起止偏移为本章全局字符偏移） */
  static selectionText(s: SelectionRange, lines: LineBox[]): string {
    if (s.startCharOffset > s.endCharOffset) {
      const tmp: number = s.startCharOffset;
      s.startCharOffset = s.endCharOffset;
      s.endCharOffset = tmp;
    }
    let out: string = '';
    for (let i = 0; i < lines.length; i++) {
      const line: LineBox = lines[i];
      const lineStart: number = line.startCharOffset;
      const lineLen: number = line.text.length;
      const lineEnd: number = lineStart + lineLen;
      const lo: number = Math.max(s.startCharOffset, lineStart);
      const hi: number = Math.min(s.endCharOffset + 1, lineEnd);
      if (lo < hi) {
        out += line.text.substring(lo - lineStart, hi - lineStart);
      }
    }
    return out;
  }
}