/**
 * MediaOverlayTypes — EPUB3 媒体叠加数据模型
 *
 * 根据 EPUB3 Media Overlays 规范定义：
 * - SMIL 文件描述音频片断与文本片断的时间同步关系
 * - 每个 <par> 元素包含一个 <audio> 引用和一个 <text> 引用
 */

/**
 * SMIL 文件元数据
 */
export interface SmilFile {
  /** SMIL 文件相对路径（来自 OPF） */
  src: string;
  /** 该 SMIL 包含的同步段落列表 */
  pars: SmilPar[];
  /** 关联的 EPUB 章节文件路径 */
  chapterSrc: string;
}

/**
 * <par> 元素 — 一个同步段落（音频+文本配对）
 */
export interface SmilPar {
  /** 唯一标识（来自 id 属性） */
  id: string;
  /** 音频片段引用 */
  audio: SmilAudio;
  /** 文本片段引用 */
  text: SmilTextRef;
  /** 该段落在章节中的顺序序号 */
  seq: number;
  /** 可选的持续时间（秒） */
  duration: number;
}

/**
 * <audio> 元素引用
 */
export interface SmilAudio {
  /** 音频文件路径（相对或绝对） */
  src: string;
  /** 剪辑开始时间（秒），对应 clipBegin 属性 */
  clipBegin: number;
  /** 剪辑结束时间（秒），对应 clipEnd 属性 */
  clipEnd: number;
}

/**
 * <text> 元素引用
 */
export interface SmilTextRef {
  /** 文本片段引用 URL（形如 chapter.xhtml#id） */
  src: string;
  /** 片段 ID（# 后的部分） */
  fragmentId: string;
}

