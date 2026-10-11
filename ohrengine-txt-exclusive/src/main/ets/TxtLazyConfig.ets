/**
 * TxtLazyConfig — TXT Lazy 数据源的可调常量与灰度开关（Phase 9）
 * 开关（9.9）：默认开启 lazy；setEnabled(false) 回退 eager。
 */

export class TxtLazyConfig {
  private static enabled: boolean = true;

  /** 索引格式版本（结构不兼容时递增） */
  public static readonly INDEX_VERSION: number = 1;

  /** 索引构建/读取的读取窗口字节数 */
  public static readonly SCAN_WINDOW_BYTES: number = 128 * 1024;

  /** chunk 目标字节数（换行对齐） */
  public static readonly CHUNK_TARGET_BYTES: number = 256 * 1024;

  /** 单段最大字符数：超过则强制切段（degraded，防 1MB/10MB/50MB 行） */
  public static readonly MAX_PARAGRAPH_CHARS: number = 64 * 1024;

  /** 单段合并最大字符数（与 TxtConfig.MAX_MERGED_PARAGRAPH_LENGTH 一致） */
  public static readonly MAX_MERGED_PARAGRAPH_LENGTH: number = 600;

  /** vchapter 目标字符数（与 VChapterTypes.VCHAPTER_TARGET_CHARS 一致） */
  public static readonly VCH_TARGET_CHARS: number = 8000;

  /** vchapter 允许超调字符数（与 VChapterTypes.VCHAPTER_MAX_OVER 一致） */
  public static readonly VCH_MAX_OVER: number = 2000;

  /** fallback（无章检测）每页段落数（与 TxtParser.buildChapters 一致） */
  public static readonly FALLBACK_PARAGRAPHS_PER_PAGE: number = 40;

  public static isEnabled(): boolean {
    return TxtLazyConfig.enabled;
  }

  public static setEnabled(value: boolean): void {
    TxtLazyConfig.enabled = value;
  }
}