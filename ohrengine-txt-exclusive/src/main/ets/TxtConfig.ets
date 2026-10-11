/**
 * TxtConfig — TXT 解析可调常量
 *
 * 集中管理章节检测、编码探测、段落切分的阈值，
 * 便于调参而无需改动解析器主体逻辑。
 */

export class TxtConfig {
  /** 编码探测采样字节数（BOM 检查 + UTF-8 合法性扫描） */
  public static readonly ENCODING_SAMPLE_BYTES: number = 64 * 1024;

  /** 章节标题行最大长度：超过则视为正文段落而非标题 */
  public static readonly MAX_HEADING_LINE_LENGTH: number = 50;

  /** 命中章节标题的最少数量：低于该值回退到空行分段 */
  public static readonly MIN_DETECTED_CHAPTERS: number = 2;

  /**
   * 段落合并的硬换行解包上限：
   * 单个累计段落超过该字符数时强制断段，防止异常文本撑爆布局。
   */
  public static readonly MAX_MERGED_PARAGRAPH_LENGTH: number = 600;

  /** 句末标点集合：段落合并时，以这些字符结尾的行允许断段 */
  public static readonly SENTENCE_ENDING_PUNCTUATION: string =
    '。！？；…!?;"”』」〕）】›»';
}
