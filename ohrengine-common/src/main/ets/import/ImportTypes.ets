/**
 * ImportTypes — 统一导入（导入即解析）与可逆导出的数据类型
 *
 * 本文件定义统一导入入口 `ImportService` 及其台账 `ImportedBookStore` 所用的
 * 数据/接口类型。均为 ArkTS 严格模式下可序列化的纯数据类型，不涉及 UI 状态。
 *
 * 设计约束：
 *   - 所有对象字面量必须带显式类型上下文（ArkTS 严格模式）
 *   - ImportedBook 需 JSON 可序列化（台账持久化）
 *   - 单条键值语义（ImportResult 非列表）
 */

/** 导入结果状态 */
export enum ImportStatus {
  /** 导入成功（完成接入 + 解压 + 解析 + 落盘 + 台账） */
  SUCCESS = 'SUCCESS',
  /** 已在台账命中且指纹有效（热启动快速路径，未重新解压/解析） */
  ALREADY_IMPORTED = 'ALREADY_IMPORTED',
  /** 不支持的格式（PDF / 未知扩展名），未产生任何产物 */
  UNSUPPORTED = 'UNSUPPORTED',
  /** 失败（来源接入/解压/解析/落盘任一步骤失败），不落为已导入 */
  FAILED = 'FAILED'
}

/**
 * 导入请求 — 描述一次导入的来源（沙箱路径或外部 URI 二选一）。
 */
export interface ImportRequest {
  /** 已在沙箱内的源文件绝对路径（与 sourceUri 二选一） */
  sourcePath?: string;
  /** 外部来源 URI（与 sourcePath 二选一；须在授权有效期内立即导入） */
  sourceUri?: string;
  /** 原始文件名（用于命名与唯一化；缺省时从路径/URI 推导） */
  displayName?: string;
  /** 期望格式扩展名（如 '.epub'；缺省从 displayName/路径推导） */
  formatHint?: string;
}

/**
 * 已导入图书记录（导入台账条目）— 用于热启动判定与导出定位。
 */
export interface ImportedBook {
  /** 稳定图书标识（由格式 + 源文件 basename + 大小派生） */
  bookId: string;
  /** 源格式：'.epub' | '.txt' | '.cbz'（'.cbr' 归一为 '.cbr' 原样记录） */
  format: string;
  /** 展示名（解析元数据标题，缺省回退文件名） */
  title: string;
  /** 保留的原始源文件绝对路径（可逆导出依据） */
  sourcePath: string;
  /** EPUB/CBZ 解压目录（TXT 为空串） */
  extractDir: string;
  /** L0/L2 解析缓存目录（cache/books/<bookName>） */
  cacheDir: string;
  /** 持久目录（TXT 索引所在，其余为约定目录） */
  libraryDir: string;
  /** 源文件指纹（`size:mtime`） */
  fingerprint: string;
  /** 导入时间戳（ms） */
  importedAt: number;
}

/**
 * 导入结果 — 一次导入的最终产出（单条，非列表）。
 */
export interface ImportResult {
  status: ImportStatus;
  /** 稳定图书标识（成功/已导入时有效；失败时可能为空串） */
  bookId: string;
  /** 成功/已导入时的台账记录 */
  record?: ImportedBook;
  /** 失败/不支持时的可理解错误信息 */
  error?: string;
}

/**
 * 批量导入进度 — 供界面展示「导入中 x/N：书名」。
 *
 * 逐本处理时，每本处理前触发一次（进入该项），携带其索引/总数/展示名；
 * `stage` 可选转发单本 `importBook` 的阶段名（ingest/unzip/parse/persist/...）。
 */
export interface BatchImportProgress {
  /** 当前处理项索引（0-based） */
  index: number;
  /** 批次总数 */
  total: number;
  /** 当前书名/文件名（展示用） */
  name: string;
  /** 可选阶段名（若转发单本阶段） */
  stage?: string;
}

/**
 * 批量导入结果 — 逐本结果（与请求顺序一致）+ 汇总计数。
 *
 * 说明：批量经统一入口 `ImportService.importBooks` 逐本串行复用单本
 * `importBook` 语义（幂等/指纹/去重/失败原子性），任一项失败/不支持时
 * 跳过并继续，不抛错、不中止；空列表返回 `total=0` 的空汇总。
 */
export interface BatchImportResult {
  /** 逐本结果（与请求顺序一致） */
  results: ImportResult[];
  /** 批次总数（等于 results.length） */
  total: number;
  /** 成功数（ImportStatus.SUCCESS） */
  succeeded: number;
  /** 已存在数（ImportStatus.ALREADY_IMPORTED） */
  alreadyImported: number;
  /** 不支持数（ImportStatus.UNSUPPORTED） */
  unsupported: number;
  /** 失败数（ImportStatus.FAILED） */
  failed: number;
}

/**
 * 导出产物 — 由已导入图书逆向还原得到的原始格式文件。
 */
export interface ExportArtifact {
  /** 导出产物绝对路径（filesDir/exports/<uniqueName>） */
  path: string;
  /** 对外文件名（原文件名/唯一化名） */
  fileName: string;
  /** 格式：'.epub' | '.txt' */
  format: string;
  /** 字节大小（与源文件一致，可作无损校验） */
  size: number;
}

/**
 * 导入台账文件格式（内部）— 持久于 filesDir/library/import-index.json。
 */
export interface ImportIndexFile {
  version: number;
  books: ImportedBook[];
  updatedAt: number;
}

/** 台账文件结构版本 */
export const IMPORT_INDEX_VERSION: number = 1;

// ==================== 统一删除（彻底删除）====================

/**
 * 删除结果状态（单条非列表）。
 */
export enum DeleteStatus {
  /** 已删除（台账移除 + 核心产物清理完成） */
  DELETED = 'DELETED',
  /** 台账无此记录（安全返回，不抛错） */
  NOT_FOUND = 'NOT_FOUND',
  /** 台账已移除，但部分清理项失败（可感知） */
  PARTIAL = 'PARTIAL',
  /** 台账移除失败（未产生任何清理效果） */
  FAILED = 'FAILED'
}

/**
 * 删除结果 — 一次彻底删除的最终产出。
 *
 * 说明：`cleanedItems`/`failedItems` 为清理项标识（如 `source`/`extract`/
 * `cache`/`library`/`readingState`/`ledger`/`associated`），供可感知与诊断。
 */
export interface DeleteResult {
  status: DeleteStatus;
  /** 被删除图书的稳定标识 */
  bookId: string;
  /** 被删除图书的标题（未找到时为空串） */
  title: string;
  /** 已清理项标识 */
  cleanedItems: string[];
  /** 清理失败项标识 */
  failedItems: string[];
}

/**
 * 删除选项。
 */
export interface DeleteOptions {
  /** 阅读进度目录（缺省 filesDir/reading_state） */
  readingStateDir?: string;
}

/**
 * 关联数据清理钩子（跨模块清理）。
 *
 * 共享层（ohrengine-common）不可反向依赖功能模块（ohrengine-feature），因此
 * 由应用层实现本接口并注册，用于清理共享层不可直接访问的模块数据（批注 SQLite、
 * 书签 Preferences 等）；`ImportService.deleteBook` 在移除台账并清理核心产物后
 * 统一调用所有已注册的清理钩子。
 */
export interface BookAssociatedDataCleaner {
  /**
   * 清理某本台账记录对应的模块关联数据（以 `record` 定位）。
   * 实现应尽力清理并保持幂等；异常由调用方（deleteBook）捕获并计入失败项。
   */
  clean(filesDir: string, record: ImportedBook): Promise<void>;
}
