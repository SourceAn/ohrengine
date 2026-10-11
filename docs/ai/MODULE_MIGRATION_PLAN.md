# MODULE_MIGRATION_PLAN — HAR 物理迁移计划（不执行，仅设计）

> 生成：2026-10-11 ｜ 承接 `MODULE_TOPOLOGY.md`。目标拓扑：**6 HAR + entry**。
> 约束：本轮**不执行**；每 Phase 单独可构建/可回归/可回滚；旧 API 经 compat facade 保留。

## 1. 核心对象 → 目标落位（任务 §27）

| 当前对象 | 当前位置 | 目标 HAR | 目标 package | Compatibility | Phase |
|---|---|---|---|---|---|
| `ReaderHost` | `reader/ReaderHost.ets` | `ohrengine-app` | `app/host` | **facade 保留**（对外名不变） | 3 |
| `OhEngine` | `ui-render/OhEngine.ets` | `ohrengine-engine`(核心) + `ohrengine-app`(feature 聚合剥离) | `engine/api` | facade 保留 | 2 |
| `OhEngineCore` | `ui-render/OhEngineCore.ets` | `ohrengine-engine` | `engine/session` + `engine/document` + `engine/cache` | 拆后保留 re-export | 3 |
| `PageManager` | `ui-render/core/PageManager.ets` | `ohrengine-engine` | `engine/pagination` + `engine/navigation` + `engine/session` | facade 保留 | 3 |
| `PipelineManager` | `ui-render/core/PipelineManager.ets` | `ohrengine-engine` + `ohrengine-platform-harmony`(taskpool) | `engine/layout` + `engine/pagination` + `engine/style` + `platform/api.TaskScheduler` | facade 保留 | 3 |
| `PageRenderer` | `reader/reader/PageRenderer.ets` | `ohrengine-render` | `render/backend/canvas` | 无（内部） | 6 |
| `OhGlass`(GLES) | `reader/glass/OhGlass.ets` | `ohrengine-render` | `render/backend/gles` | facade（给 reader UI 用） | 6 |
| `PageCacheManager` | `common/service/PageCacheManager.ets` | `ohrengine-engine` | `cache/layout` | 磁盘格式迁移/双读 | 5 |
| `ParseCacheManager` | `common/service/ParseCacheManager.ets` | `ohrengine-engine` | `cache/document` | 磁盘格式迁移/双读 | 5 |
| `SecureArchive` | `common/service/SecureArchive.ets` | `ohrengine-platform-harmony`(+`ohrengine-format`) | `platform/archive` + `format/spi` | 保留 | 4 |
| `TextBreaker`(Knuth-Plass) | `ui-render/layout/TextBreaker.ets` | `ohrengine-engine` | `engine/layout/text` | 无 | 3 |
| `JustifyEngine`/`PageSplitter` | `ui-render/layout/*` | `ohrengine-engine` | `engine/layout` / `engine/pagination` | 无 | 3 |
| EPUB parser | `epub/*` | `ohrengine-format` | `format/epub` | 保留 `EpubParser` | 4 |
| TXT parser | `txt-exclusive/*`(含 taskpool) | `ohrengine-format` + `ohrengine-platform-harmony` | `format/txt` + `platform/api.TaskScheduler` | 保留 `TxtParser`；索引逐字节 G1 | 4 |
| PDF renderer | `pdf-exclusive/PdfRenderer.ets` | `ohrengine-render` | `render/backend/pdf` | 无 | 6 |
| PDF parser | `pdf-exclusive/PdfParser.ets` | `ohrengine-format` | `format/pdf` | 保留 `PdfParser` | 4 |
| `feature/*`(批注/书签/搜索/选词) | `feature/*` | `ohrengine-engine`(语义) + `ohrengine-app`(存储) | `engine/annotation` `engine/search` + `app/storage` | 保留 | 3/7 |
| `feature/*`(词典/TTS/生词本/历史/主题) | `feature/*` | `ohrengine-app` | `app/features` | 保留 | 7 |
| `parsers/*`(HTML/CSS) | `ohrengine-parsers` | `ohrengine-engine` | `engine/style/parse` + `engine/document/dom` | 无 | 3 |

## 2. Phase 计划（0 → 8）

| Phase | 目标 | 修改/新增 HAR | 关键点 | 验证 | 回滚 |
|---|---|---|---|---|---|
| **P0 Freeze** | 冻结本目录 4 文档 + 校验脚本；CI 接入 `check_boundaries.mjs` | 无 | 文档/脚本 | 脚本可运行 | 删脚本 |
| **P1 Platform SPI** | 新增 `ohrengine-platform-api`（纯接口，零 `@kit`）；各层 `@kit.*` 调用点改为经接口 | 新增 1 HAR | 接口 + 转发，零行为变更 | 构建 + 回归 + `INV-PLATFORM`↓ | 删 HAR |
| **P2 API 边界** | `OhEngine` 的 Feature 聚合剥离；`engine/api` 作为唯一 Public API | 无（改 export） | 保留 facade 名 | 构建 + 回归 | 还原 index.ets |
| **P3 Engine 拆分** | 新建 `ohrengine-engine`；把 `ui-render` 核心 + `common` 模型/缓存 + `parsers` 迁入 | 新增 `ohrengine-engine`；`ui-render`/`common`/`parsers` 逐步变薄 | 大改，须 facade：`OhEngine/OhEngineCore/PageManager/PipelineManager` re-export | golden(EPUB/TXT) + 回归 + e2e | 保留旧 HAR 至 P8 |
| **P4 Format 分离** | 新建 `ohrengine-format`；迁 `epub/txt/pdf/cbz` 为 `format/*` | 新增 `ohrengine-format` | **TXT G1 逐字节**；`TaskScheduler` 抽到 platform | 各格式 golden | 旧 4 HAR 保留 |
| **P5 Cache 边界** | `Parse/Page/Memory` 缓存归 `engine/cache/*`；键集中；磁盘格式迁移 | 无新 HAR | 旧缓存双读 + 迁移；`library/` 不受影响 | 清缓存不改正确性 | 还原路径 |
| **P6 Renderer 后端化** | 新建 `ohrengine-render`；迁 `PageRenderer`/`OhGlass`/`PdfRenderer` | 新增 `ohrengine-render` | Engine 只见 `render/spi` | headless 测试（I9） | 旧 reader 保留 |
| **P7 Platform 实现 + App** | 新建 `ohrengine-platform-harmony`（`@kit` 唯一落点）+ `ohrengine-app`（Host/UI/features） | 新增 2 HAR | `ReaderHost` 变 facade | 构建 + 回归 + `INV-UI/PLATFORM`=PASS | 旧 reader/feature 保留 |
| **P8 移除兼容壳** | 删除薄化的旧 HAR（`common/ui-render/parsers/epub/txt/cbz/pdf/reader/feature`） | 删 9 → 剩 6 HAR | 确认无外部引用 | 全量构建 + e2e | 保留 tag |

**安全顺序**：P1（SPI）必须先于 P3/P4/P6/P7（拆分）；P5（缓存）先于 P3（避免边拆边动缓存路径）。

## 3. 每 Phase 的不变量收敛

| Phase | 收敛 |
|---|---|
| P1 | `INV-PLATFORM`（engine 不再直接 `@kit.*`） |
| P3 | `INV-UI`（engine 去 ArkUI） |
| P4 | `INV-FORMAT-IN-ENGINE`（维持 PASS） |
| P6 | `INV-RENDER-FORMAT`（renderer 去 format/cache） |
| P7 | generic-dir 归零（目录语义化） |
| P8 | 6/6 PASS + generic=0 |

## 4. Compatibility Facade 账本（任务 §18）

| Facade | Owner | 到期 Phase |
|---|---|---|
| `OhEngine`（旧 facade 名） | `ohrengine-engine` | P8（或长期作为 Public API 别名） |
| `OhEngineCore` | `ohrengine-engine` | P8 |
| `PageManager` / `PipelineManager` | `ohrengine-engine` | P8 |
| `ReaderHost` | `ohrengine-app` | 长期（Application 入口，非临时） |
| 各 `XxxParser` 名 | `ohrengine-format` | 长期（Format Public） |
| `common` 的 re-export | `ohrengine-engine` | P3→P8 逐步收口 |

## 5. 风险与回滚

- **风险**：P3/P4/P6/P7 涉及跨 HAR 移动与 `oh-package`/`build-profile` 变更 → 每 Phase 保留旧 HAR 直至 P8；缓存磁盘格式（`meta.json`/`chapter_*.json`/`pgcount.json`/`.parsed.json`/`txt-index-v2.json`）需迁移或双读。
- **回滚**：每 Phase 单独提交/备份；旧 HAR 在 P8 前始终存在 → 回滚 = 恢复 `build-profile.json5` 模块表 + `oh-package` 依赖。
- **验证基线**：EPUB/TXT golden（TXT 已有 G1 逐字节）、`check_boundaries.mjs`、回归测试类（TxtLazy/Phase7/PageCache/…）。

## 6. Deferred

DocumentIR 实现、Layout/Pagination/Renderer 重写、PDF/MOBI/AZW 实现、大规模移动（本轮与 P0–P1 之外均暂不执行）。
