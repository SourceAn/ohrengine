# 公共 API

OhEngine 作为多模块 HAR 阅读引擎，对外暴露单一入口 `ohrengine-common`。
所有消费者项目 **MUST** 仅从 `ohrengine-common` 导入公共符号：

```typescript
import { ImportService, ImportedBookStore, ImportStatus } from 'ohrengine-common';
import type { ImportRequest, ImportResult, ImportedBook, ExportArtifact } from 'ohrengine-common';
```

---

## 统一导入（导入即解析）与可逆导出

### 消费契约（FR-001 / FR-006）

- **唯一入口**：所有想要使用本引擎的项目 **MUST** 经 `ImportService.importBook` 导入图书；
  **禁止**调用方自行实现源文件拷贝 / 解压 / 解析。引擎不承诺绕过统一入口路径的正确性。
- **导入即解析**：`importBook` 一步完成「接入源文件 →（EPUB/CBZ）解压 → 解析 → 解析结果持久化」。
  导入成功后该书即处于「已解析」状态——再次打开命中解析缓存，**热启动/暖启动**（跳过重新解压与解析）。
- **可逆导出**：导入保留原始源文件；`exportBook` 将其逆向还原为原始格式（EPUB/TXT）产物的字节，
  与导入源**逐字节一致**，可用于分享/另存。分享 UI 不在引擎职责内（沙箱产物由消费者项目负责系统分享）。
- **格式范围**：EPUB / TXT 完整支持（含热启动与可逆导出）；**CBZ 透传**（接入 + 解压，维持现状，
  不提供本特性的导入/导出承诺）；**PDF / 未知扩展名明确拒绝**（`UNSUPPORTED`，不写任何半初始化产物）。

### `ImportService`

```typescript
class ImportService {
  /** 唯一导入入口（幂等）。 */
  static async importBook(
    filesDir: string,
    request: ImportRequest,
    onProgress?: (stage: string) => void
  ): Promise<ImportResult>;

  /** 批量导入入口（统一入口的批量能力，唯一批量路径）。逐本串行复用单本语义。 */
  static async importBooks(
    filesDir: string,
    requests: ImportRequest[],
    onProgress?: (p: BatchImportProgress) => void
  ): Promise<BatchImportResult>;

  /** 同步查询台账（不触发解析）：判定「是否已导入/热启动」并获取路径。 */
  static resolve(filesDir: string, sourcePath: string): ImportedBook | undefined;

  /** 可逆导出：复制保留的原始源文件到 destDir（默认 filesDir/exports/）。 */
  static async exportBook(
    filesDir: string, bookId: string, destDir?: string
  ): Promise<ExportArtifact>;

  /** 彻底删除（唯一删除入口，幂等）。 */
  static async deleteBook(
    filesDir: string, bookId: string, opts?: DeleteOptions
  ): Promise<DeleteResult>;

  /** 注册跨模块关联数据清理钩子（应用层在启动时注册）。 */
  static registerAssociatedDataCleaner(cleaner: BookAssociatedDataCleaner): void;

  /** 清空已注册的清理钩子（测试/销毁用）。 */
  static clearAssociatedDataCleaners(): void;
}
```

- `importBook` 返回 `ImportStatus`：
  - `SUCCESS`：导入完成（接入 + 解压 + 解析 + 落盘 + 台账 upsert）。
  - `ALREADY_IMPORTED`：台账命中且指纹/产物有效（热启动快速路径，未重新解压/解析）。
  - `UNSUPPORTED`：PDF / 未知扩展名；**不产生任何产物**。
  - `FAILED`：任一步骤失败；**不落为已导入**，可重试，且不破坏既有数据。
- `importBooks`（批量，唯一批量入口）：对 `requests` **逐本串行**处理，每本复用
  `importBook` 语义（接入 + 解压 + 解析 + 落盘 + 台账；幂等；失败原子性）。
  - 任一项 `FAILED`/`UNSUPPORTED` 时**记录并继续**下一本，**不抛错、不中止整批**。
  - 逐本结果与请求顺序一致；返回汇总计数 `{ total, succeeded, alreadyImported, unsupported, failed }`。
  - 空列表 → 返回 `total=0` 的安全空结果。
  - **约束**：批量 MUST 经此入口；禁止调用方绕过统一入口自行实现批量拷贝/解压/解析。
- `exportBook` 对记录缺失 / 格式不支持（CBZ/PDF） / 源文件缺失 / 写入失败**抛错**（可理解信息）。
- 调用方约束：`filesDir` 传 `ctx.filesDir`（应用沙箱根）。

### `ImportedBookStore`（导入台账）

```typescript
class ImportedBookStore {
  static load(filesDir: string): ImportedBook[];
  static upsert(filesDir: string, record: ImportedBook): void;
  static findById(filesDir: string, bookId: string): ImportedBook | undefined;
  static findBySource(filesDir: string, sourcePath: string): ImportedBook | undefined;
  static remove(filesDir: string, bookId: string): void;
}
```

- 持久文件：`filesDir/library/import-index.json`（tmp + rename 原子写）。
- 损坏 / 缺失静默回退为空台账，**不抛错、不阻断**。
- `upsert` 保证「一个保留源文件 = 一条记录」：同 `bookId` 或同 `sourcePath` 覆盖。

### 数据类型

```typescript
enum ImportStatus { SUCCESS, ALREADY_IMPORTED, UNSUPPORTED, FAILED }

interface ImportRequest {
  sourcePath?: string;   // 沙箱内源文件绝对路径（与 sourceUri 二选一）
  sourceUri?: string;    // 外部来源 URI（与 sourcePath 二选一）
  displayName?: string;  // 原始文件名（命名/唯一化，缺省从路径推导）
  formatHint?: string;   // 期望扩展名（如 '.epub'）
}

interface ImportedBook {
  bookId: string; format: string; title: string;
  sourcePath: string; extractDir: string; cacheDir: string; libraryDir: string;
  fingerprint: string;  // 形如 "size:mtime"
  importedAt: number;
}

interface ImportResult { status: ImportStatus; bookId: string; record?: ImportedBook; error?: string; }
interface ExportArtifact { path: string; fileName: string; format: string; size: number; }

// —— 批量导入（多选一次导入多本）——
// BatchImportRequest 在实现上即「单本 ImportRequest 的数组」（ImportRequest[]）。
interface BatchImportProgress { index: number; total: number; name: string; stage?: string; }
interface BatchImportResult {
  results: ImportResult[];   // 逐本结果（与请求顺序一致）
  total: number;
  succeeded: number;         // ImportStatus.SUCCESS
  alreadyImported: number;   // ImportStatus.ALREADY_IMPORTED
  unsupported: number;       // ImportStatus.UNSUPPORTED
  failed: number;            // ImportStatus.FAILED
}
```

### 典型用法

```typescript
// 导入（导入即解析）
const result = await ImportService.importBook(ctx.filesDir, { sourceUri: uri });
if (result.status === ImportStatus.SUCCESS || result.status === ImportStatus.ALREADY_IMPORTED) {
  const book = result.record!;             // 台账记录
  // 打开阅读：engine.open(book.extractDir || book.sourcePath, {
  //   sourcePath: book.sourcePath, cacheDir: book.cacheDir, libraryDir: book.libraryDir })
}

// 可逆导出（用于分享）
const art = await ImportService.exportBook(ctx.filesDir, result.bookId!);
// art.path → filesDir/exports/<name>（与源逐字节一致）
```

```typescript
// 批量导入（书架多选一次导入多本）：逐本串行复用单本语义，失败/不支持跳过继续
const requests: ImportRequest[] = uris.map((u: string): ImportRequest => ({ sourceUri: u }));
const batch = await ImportService.importBooks(ctx.filesDir, requests,
  (p: BatchImportProgress) => { /* 进度：p.index + 1 / p.total : p.name */ });
// batch.succeeded / batch.alreadyImported / batch.unsupported / batch.failed
```

### 存储布局（与引擎判定一致）

| 用途 | 路径 |
|------|------|
| 保留源文件 | `filesDir/books/<name>` |
| EPUB/CBZ 解压目录 | `filesDir/books/<name>_extracted`（`.fingerprint.json` 于此） |
| 解析缓存（L0/L2） | `filesDir/cache/books/<bookName>/parse/`（EPUB 分块缓存） |
| 持久目录（导入成果） | `filesDir/library/<bookName>/`（TXT 索引 `txt-index-v2.json`） |
| 导入台账 | `filesDir/library/import-index.json` |
| 导出产物 | `filesDir/exports/<uniqueName>` |

> `bookName = BookStorage.deriveBookName(sourcePath, bookBasePath)`。

---

## 彻底删除（唯一删除入口）

### 消费契约（FR-005 / FR-006 / FR-007）

- **唯一入口**：删除图书 **MUST** 经 `ImportService.deleteBook` 完成，禁止调用方自行
  分散清理（源/解压/缓存/台账/进度/批注/书签）而导致残留。
- **彻底删除**：清除该书全部关联数据——源文件、解压目录、解析缓存、分页缓存、
  持久目录（含 TXT 索引）、台账记录、阅读进度、批注与书签。
- **删除顺序（避免幽灵条目）**：① 读取台账记录 → ② **先移除台账并回读校验**
  （失败 `FAILED`）→ ③ 清理核心产物 → ④ 调用已注册清理钩子（批注/书签）。
- **失败一致性**：核心清理或钩子失败计入 `failedItems`、状态为 `PARTIAL`
  （台账已移除，书架不残留条目）；对已被外部删除的书安全完成（`NOT_FOUND` 或视为已清理）。

### 跨模块清理钩子

共享层（`ohrengine-common`）**不可**反向依赖功能模块（`ohrengine-feature`），因此批注
（SQLite）/书签（Preferences）等模块数据的清理由**应用层实现钩子并注册**，由
`deleteBook` 统一编排：

```typescript
interface BookAssociatedDataCleaner {
  clean(filesDir: string, record: ImportedBook): Promise<void>;
}

// 应用启动时注册（如 EntryAbility.onCreate）
ImportService.registerAssociatedDataCleaner(new FeatureDataCleaner(this.context));
```

应用层实现 `FeatureDataCleaner` 以 `record.title`（与引擎侧 `pub.getMetadata().title`
一致）为键调用 `AnnotationStorage.removeAll` / `BookmarkStorage.removeAll`。

### 删除数据类型

```typescript
enum DeleteStatus { DELETED, NOT_FOUND, PARTIAL, FAILED }

interface DeleteOptions { readingStateDir?: string; } // 缺省 filesDir/reading_state

interface DeleteResult {
  status: DeleteStatus;
  bookId: string;
  title: string;
  cleanedItems: string[]; // 已清理项标识：source/extract/cache/library/readingState/ledger/associated
  failedItems: string[];  // 清理失败项标识（可感知/诊断）
}
```

- `DELETED`：台账移除 + 核心产物清理完成。
- `NOT_FOUND`：台账无此记录（安全返回，不抛错）。
- `PARTIAL`：台账已移除，但部分清理项（核心产物或钩子）失败。
- `FAILED`：台账移除失败（未产生任何清理效果）。

### 已知限制

- 阅读进度的键为 `identifier || title`，删除以台账 `record.title` 定位；当该书存在
  非空 `identifier` 时可能不完全命中（残留状态无害、可后续清理）。
- 仅清理台账记录对应的产物；无台账对应的“孤儿”目录不在本入口范围。

---

## 其它公共能力（摘要）

- **核心引擎**：`OhEngine`（`ohrengine-ui-render`）、`EngineState` / `EngineConfig` 等（`ohrengine-common`）。
- **模型**：`Publication` / `Manifest` / `Metadata` / `Link` / `Book` 等（`ohrengine-common`）。
- **解析 SPI**：`ParserRegistry` / `BookParser` / `ParsedBook` / `BookFormat` / `RenderStrategy`（`ohrengine-common`）。
  格式解析器（`EpubParser` / `TxtParser` / `CbzParser` / `PdfParser`）须在应用启动时注册。
- **缓存**：`ParseCacheManager` / `PageCacheManager` / `DiskCacheQuotaManager` / `ImportCheckpoint`（`ohrengine-common`）。
- **存储 / 安全**：`BookStorage` / `SecureArchive`（`ohrengine-common`）。

页面层完整用法见 `entry/src/main/ets/pages/Index.ets`。
