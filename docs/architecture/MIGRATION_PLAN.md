# MIGRATION_PLAN — 当前 → 目标 渐进迁移

> 生成：2026-10-11 ｜ 取代旧版 `MIGRATION_PLAN.md`。**本轮不执行迁移**，只给方案。
> 硬约束：不破坏阅读行为 / 不重写 Layout/Pagination/Renderer/EPUB/TXT / 不实现完整 DocumentIR / 不做无边界大迁移 / 旧 API 经兼容壳保留。

## 0. 分阶段（渐进，不可合并）

| Phase | 目标 | 收敛的边界 | 风险 |
|---|---|---|---|
| **Phase 0** | Architecture Freeze：冻结本目录 5 文档；CI 接入 `check_boundaries.mjs` | 规则可执行 | 无（纯文档/脚本） |
| **Phase 1** | Boundary / SPI：新增 `platform/api`（FileSystem/Logger/Clock/TaskScheduler/FontProvider/ImageDecoder/TextMeasurer）**纯接口**；现有 `@kit.*` 调用点改为经接口 | `INV-PLATFORM` | 低（接口 + 转发，零行为变更） |
| **Phase 2** | Directory Cleanup：按 `DIRECTORY_STRUCTURE.md §3` 分批搬桶（`common/service`→`cache/*` 等），保留 `index.ets` 导出 | generic-dir=0 | 中（HAR 内相对 import + index） |
| **Phase 3** | DocumentIR Vertical Slice：先在 EPUB/TXT 双适配产出最小 IR；`ParsedBook` 收敛 | `I1/I2` 雏形 | 中（解析 golden 回归） |
| **Phase 4** | Cache Boundary：`Parse/Page/Memory` 缓存归位 `cache/{document,layout,page,asset,lifecycle}`；缓存键集中 | `I8` | 中（磁盘格式/路径迁移） |
| **Phase 5** | Engine Split：`OhEngineCore`/`PipelineManager`/`PageManager` 按 `engine/{session,layout,pagination,navigation}` 拆分（保留兼容壳） | `I5/I10` | 高（面广，需兼容壳） |
| **Phase 6** | Renderer Backendization：`PageRenderer`/`OhGlass`/`PdfRenderer` → `render/backend/*`；Engine 只依赖 `render/api` | `I3/I9` | 中 |
| **Phase 7** | Platform Implementations：`platform/harmony`（+ 未来 android/desktop）；Engine 零 `@kit.*` | `INV-PLATFORM/UI`=PASS | 中 |

**安全顺序原则**：每 Phase 单独可构建、可回归、可回退；Phase 5（拆分巨型类）必须晚于 Phase 1（SPI）与 Phase 4（缓存归位）。

## 1. 模块映射（摘要）

见 `DIRECTORY_STRUCTURE.md §3`（逐项 OLD→NEW→REASON）。关键动作：`ReaderHost`/`OhEngineCore`/`PipelineManager`/`PageManager`/`OhEngine` = **SPLIT**（+兼容壳）；`PageCacheManager`/`ParseCacheManager`/`SecureArchive` = **MOVE/SPLIT**；`format/*` = **KEEP→MOVE**；`gl/PageRenderer/PdfRenderer` = **MOVE** 到 `render/backend`。

## 2. Architecture Invariants（当前态，据实判定）

| # | Invariant | 现状 | 依据 |
|---|---|---|---|
| I1 | 改 Format 不重写 Layout | **PARTIAL** | Engine→Format 直接依赖=0（PASS），但无稳定 IR，加格式仍可能牵动 `ParsedBook/strategy` |
| I2 | 改 Layout 不重写 Format | **PARTIAL** | 同 I1：边界方向对，缺 IR 契约 |
| I3 | 改 Renderer 不重写 Engine | **PARTIAL** | 有 `StrategyRouter`，但渲染入口散落 `reader`/`pdf`，Engine 与渲染端同模块 |
| I4 | 改 Platform 不重写 Document | **FAIL** | 无 Platform SPI；`common` 直接 `@kit.*` |
| I5 | 改 UI 不重写 Engine | **FAIL** | `ReaderHost` 同时是引擎宿主 + UI |
| I6 | 改 Font 不改 Document | **PASS** | Document/解析缓存不含字体；字体仅影响 Layout/Page 缓存 |
| I7 | 改 Viewport 不改 Document | **PASS** | `computeLayoutSignature` 只影响 Page/Layout 缓存 |
| I8 | 清空全部缓存不改变正确性 | **PASS** | 缓存皆可重建（含 TXT 索引迁 `library/` 后仍可重建） |
| I9 | 去 Renderer 后 Engine 可测 | **PARTIAL** | GL 隔离较好，但 Canvas 渲染在 `reader`；headless 需 Engine 去 ArkUI |
| I10 | 去 UI 后 Engine 可测 | **FAIL** | Engine(`ui-render`) 依赖 ArkUI/Feature |

**汇总**：PASS 3（I6/I7/I8）/ PARTIAL 4（I1/I2/I3/I9）/ FAIL 3（I4/I5/I10）。
（与 `check_boundaries.mjs` 的 3/5 PASS 一致：跨平台与 UI 解耦是主战场。）

## 3. 目录复杂度：Current vs Target

| 指标 | Current | Target |
|---|---|---|
| 顶层"架构"目录 | 10 模块 × 各自子目录 | 1 个 `src/` 下 8 顶层（api/engine/format/cache/render/platform/application） |
| 架构叶子目录 | 40 | 计划 ~30（更少但语义化） |
| 泛名目录（common/utils/service/types/model/core…） | **9** | **0** |
| Engine 内 `@kit.*` 文件 | 37（ui-render 8+common 8+reader 21） | **0** |
| Engine→Format 直接依赖文件 | 0 | 0（维持） |
| 单文件目录 | 11 | 尽量 0 |
| 平均文件/目录 | 4.03 | ~5–8 |
| 模块环 | 0 | 0 |

## 4. 风险

| 风险 | 说明 |
|---|---|
| API 兼容 | `OhEngine`/`OhEngineCore`/`PageManager`/`PipelineManager` 暴露面广 → 保留 compat facade（Phase 5）。 |
| 缓存兼容 | `meta.json`/`chapter_*.json`/`pgcount.json`/`.parsed.json`/`txt-index-v2.json` 磁盘格式与路径迁移（Phase 4）需迁移或双读。 |
| 性能 | SPI 间接层**不得**进热路径（`TextBreaker`/分页）；Phase 5 拆分须保持调用链。 |
| 内存 | `MemoryPageCache`/段落缓存 L4 上界与 LRU 语义须保持。 |
| EPUB/TXT 行为 | 须 golden 逐字节回归（TXT 索引已有 G1 黄金测试）。 |
| 线程语义 | `taskpool` 让步/调度与主线程不同（TXT 索引 profiling 已证）→ `TaskScheduler` 抽象须保语义。 |

## 5. Deferred（明确暂不做）

- 实现 DocumentIR；重写 Layout/Pagination/Renderer；PDF/MOBI/AZW 实现；大规模移动文件；破坏性 API 变更；任何阅读行为/分页结果/缓存行为变更。
