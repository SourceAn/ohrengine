/**
 * SmilParser — EPUB3 媒体叠加 SMIL 文件解析器
 *
 * 解析 XHTML SMIL 文件（EPUB3 Media Overlays 规范），提取：
 * - <par> 同步段落列表（含 <audio> 和 <text> 子元素）
 * - 时间信息（clipBegin / clipEnd）
 * - 文本引用（epubcfi 片段或 #fragmentId）
 */

import { SmilFile, SmilPar, SmilAudio, SmilTextRef } from '../model/MediaOverlayTypes.ets';

/**
 * SMIL 解析器 — 静态方法
 */
export class SmilParser {
  /**
   * 解析 SMIL 文件内容字符串为 SmilFile 结构
   *
   * @param smilSrc   SMIL 文件路径
   * @param content   SMIL 文件 XML 内容字符串
   * @param chapterSrc 关联的章节文件路径
   * @returns 解析后的 SmilFile，解析失败时返回 null
   */
  public static parse(
    smilSrc: string,
    content: string,
    chapterSrc: string
  ): SmilFile | null {
    const pars: SmilPar[] = [];
    let seq: number = 0;

    // 简单正则提取 <par> 块
    const parPattern: RegExp = new RegExp(
      '<par[^>]*id\\s*=\\s*"([^"]*)"[^>]*>([\\s\\S]*?)<\\/par>',
      'gi'
    );
    let parMatch: RegExpExecArray | null = parPattern.exec(content);

    while (parMatch !== null) {
      const parId: string = parMatch[1];
      const parBody: string = parMatch[2];

      const audio: SmilAudio | null = SmilParser.parseAudio(parBody);
      const textRef: SmilTextRef | null = SmilParser.parseTextRef(parBody);

      if (audio !== null && textRef !== null) {
        const duration: number = audio.clipEnd - audio.clipBegin;
        pars.push({
          id: parId,
          audio: audio,
          text: textRef,
          seq: seq,
          duration: duration > 0 ? duration : 0
        });
      }
      seq++;
      parMatch = parPattern.exec(content);
    }

    if (pars.length === 0) {
      return null;
    }

    return {
      src: smilSrc,
      pars: pars,
      chapterSrc: chapterSrc
    };
  }

  /**
   * 根据章节路径查找对应的 SMIL 文件
   *
   * @param smilFiles  所有已发现的 SMIL 文件列表
   * @param chapterSrc 章节文件路径
   * @returns 匹配的 SmilFile，未找到时返回 null
   */
  public static findSmilForChapter(
    smilFiles: SmilFile[],
    chapterSrc: string
  ): SmilFile | null {
    for (let i = 0; i < smilFiles.length; i++) {
      if (smilFiles[i].chapterSrc === chapterSrc) {
        return smilFiles[i];
      }
    }
    return null;
  }

  /**
   * 从 <par> 体内解析 <audio> 元素
   */
  private static parseAudio(parBody: string): SmilAudio | null {
    const audioPattern: RegExp = new RegExp(
      '<audio[^>]*src\\s*=\\s*"([^"]*)"[^>]*>',
      'i'
    );
    const audioMatch: RegExpExecArray | null = audioPattern.exec(parBody);
    if (audioMatch === null) {
      return null;
    }

    const audioSrc: string = audioMatch[1];

    // 解析 clipBegin
    let clipBegin: number = 0;
    const cbPattern: RegExp = new RegExp(
      'clipBegin\\s*=\\s*"([^"]*)"',
      'i'
    );
    const cbMatch: RegExpExecArray | null = cbPattern.exec(parBody);
    if (cbMatch !== null) {
      clipBegin = SmilParser.parseTime(cbMatch[1]);
    }

    // 解析 clipEnd
    let clipEnd: number = 0;
    const cePattern: RegExp = new RegExp(
      'clipEnd\\s*=\\s*"([^"]*)"',
      'i'
    );
    const ceMatch: RegExpExecArray | null = cePattern.exec(parBody);
    if (ceMatch !== null) {
      clipEnd = SmilParser.parseTime(ceMatch[1]);
    }

    return {
      src: audioSrc,
      clipBegin: clipBegin,
      clipEnd: clipEnd
    };
  }

  /**
   * 从 <par> 体内解析 <text> 元素
   */
  private static parseTextRef(parBody: string): SmilTextRef | null {
    const textPattern: RegExp = new RegExp(
      '<text[^>]*src\\s*=\\s*"([^"]*)"[^>]*>',
      'i'
    );
    const textMatch: RegExpExecArray | null = textPattern.exec(parBody);
    if (textMatch === null) {
      return null;
    }

    const src: string = textMatch[1];
    // 提取片段 ID（# 后的部分）
    const hashIdx: number = src.lastIndexOf('#');
    const fragmentId: string = hashIdx >= 0 ? src.substring(hashIdx + 1) : '';

    return {
      src: src,
      fragmentId: fragmentId
    };
  }

  /**
   * 解析 SMIL 时间字符串为秒数
   *
   * 支持格式：
   * - HH:MM:SS.fraction  (如 00:01:30.500)
   * - MM:SS.fraction     (如 01:30.5)
   * - SS.fraction        (如 90.5)
   * - 纯数字秒数         (如 90.5)
   */
  private static parseTime(timeStr: string): number {
    const trimmed: string = timeStr.trim();

    // 纯数字 -> 秒
    const numVal: number = parseFloat(trimmed);
    if (!Number.isNaN(numVal) && trimmed.indexOf(':') < 0) {
      return numVal;
    }

    // HH:MM:SS.fraction 或 MM:SS.fraction
    const parts: string[] = trimmed.split(':');
    if (parts.length === 3) {
      const h: number = parseFloat(parts[0]);
      const m: number = parseFloat(parts[1]);
      const s: number = parseFloat(parts[2]);
      if (!Number.isNaN(h) && !Number.isNaN(m) && !Number.isNaN(s)) {
        return h * 3600 + m * 60 + s;
      }
    }

    if (parts.length === 2) {
      const m: number = parseFloat(parts[0]);
      const s: number = parseFloat(parts[1]);
      if (!Number.isNaN(m) && !Number.isNaN(s)) {
        return m * 60 + s;
      }
    }

    return 0;
  }
}
