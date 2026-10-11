# Phase 17 — Architecture Audit Report（只读 · 审计完成暂停点）

> 生成时间：2026-09-04
> 方式：纯只读（搜索/阅读/调用图/所有权/依赖方向分析）；**本轮未修改任何生产代码**
> 前置：Phase 16.4 PASS

---

## 1. Executive Summary

- 核心状态所有权清晰：`currentGlobalPage / generation / epoch / navigationSerial` 唯一 Owner = PageManager（13 处写入全部位于 PageManager.ets）；ReaderHost 的 `currentPageNum/totalPages` 仅为引擎 getter 驱动的 UI 镜像，无第二事实源。
- 依赖方向单向：ui-render / common / parsers / txt-exclusive 全部**不 import ohrengine-reader**（实证为空）；Worker 边界（纯 JSON in/out，无 UI/PageManager/PageSlot 引用）保持 Phase 16 冻结态。
- 主要债务为 `ReaderHost`（约 1684 行）与 `OhEngineCore`（约 1564 行）的「门面聚合」体量，但**未发现 P0 状态所有权冲突 / 反向依赖 / 越权写入**。
- **本阶段建议：不进行强制拆分**；可选项（充分证据后的最小迁移）列于 §10。
- 指标：总行数 7868（6 个重点模块）；ReaderHost 私有方法 ≈55 个、OhEngineCore 公共方法 ≈60 个。

## 2. Module Responsibility Matrix（代码事实）

| 模块 | 当前职责 | 状态所有权 | 外部依赖 | 被谁调用 | 越界 |
|---|---|---|---|---|---|
| ReaderHost（op-Reader 宿主） | UI 容器+编排：生命周期、设置、渲染协调、选择/批注/书签/TOC、Chrome、诊断 | 仅 UI 镜像态（pageNum/totalPages/pull/selection/annotations）；无 canonical 冲突 | OhEngine(facade)、feature、reader 子件 | Index 唯一 → 本模块根 | 无 P0（体量聚合，P2） |
| OhEngineCore（engine core） | Session/文档/排版/导航/缓存协调/pipeline 调度/Lazy 几何/诊断 | publication/state/txtLazyDoc/pageCacheContext/userAnimating/lazyGeometryRebuildCount | parsers/common/ui-render 内部 | OhEngine facade、PageManager/Pipeline host hooks | 诊断字段与核心同置（P2，观察性） |
| PageManager | PageSlot/pageSlots/currentGlobalPage/generation/导航/阅读位置 | currentGlobalPage、pageSlots、chunkToPages、chapterParagraphs… | PipelineManager、host(interfaces) | OhEngineCore | 无 UI 概念（§13 满足） |
| PipelineManager | 章内容/layout/队列/后台/commit 协调/paginatedChapters | layoutEpoch/destroyed/queue/memoryPageCache 写入 | host(interfaces)、common | PageManager/OhEngineCore/Worker | 无（§14 满足） |
| FlipPageController | 手势意图→动画→提交；动画窗口 pin/setUserAnimating | 仅自身动画态（phase/refs/geometry） | OhEngine(facade)、PageRenderer | ReaderGestureController、ReaderHost | pin/animating 属动画生命周期协调（边界内；P2 观察） |
| PageRenderer | PageModel→Canvas 直绘、图片异步解码/预取、选择/批注叠加绘制 | 自身 PixelMap 缓存；写 `LineBox.renderedY`（渲染模型坐标回写） | OhEngine、feature | ReaderHost/Flip/Slide | renderedY 回写=渲染模型坐标（边界内） |

## 3. State Ownership Map（逐状态证据）

| State | Owner | Writers（证据） | Readers | Lifecycle |
|---|---|---|---|---|
| currentGlobalPage | **PageManager** | 仅 PageManager（25–33 系列 13 处，clean） | OhEngine nav API→ReaderHost/Flip | engine 生命周期 |
| generation / pageGeneration | PageManager | rebuildPageSlots 单点 | Flip mut 校验、ReaderHost 日志 | 每次 rebuild |
| layoutEpoch / destroyed / cancellationToken | PipelineManager | shutdown/relayout/bump | scheduleNext/worker 校验 | engine 生命周期 |
| navigationSerial | PageManager | commitNavigation/queueStub（单点） | 队列顺序（Latest-Jump） | session |
| userAnimating | OhEngineCore | Flip start/finish/cancel/dispose | Pipeline.scheduleNext（后台推迟） | 动画窗口 |
| readingPosition（L1） | PageManager | updateReadingPosition/persist/FLUSH/RESTORE | ReadingStateStore | session 退出落盘 |
| lazyGeometryRebuildCount / 几何写回 | OhEngineCore | ensureLineGeometry | 选择/批注（读） | engine/session（dispose 即废） |
| pageNum/totalPages（UI） | ReaderHost（镜像） | ReaderHost refreshPage/goToProgress | 状态栏/页码 | 页面 |
| selection / annotations | ReaderHost（UI 会话） | ReaderHost 各处理 | ReaderGesture/渲染叠加 | 页面 |

> 无 `STATE_OWNERSHIP_CONFLICT`。ReaderHost 的 pageNum 是「镜像」（只从 engine getter 读后缓存展示），非第二写入源。

## 4. Dependency Graph（实证）

```
pages/Index (48 行, 3 imports)
   │ pushUrl / 渲染宿主
   ▼
ohrengine-reader/ReaderHost
   │ imports ohrengine-ui-render(facade OhEngine) + ohrengine-feature + common + kit.*
   ▼
OhEngine (facade, 薄)
   ▼
OhEngineCore ──► PageManager ──► PipelineManager ──► Layout/Cache/Parser
       └────────► Worker(LayoutChapterWorker)（JSON in/out，纯函数）
```
- **反向依赖：0**（ui-render/common/parsers/txt 不含 `from 'ohrengine-reader'`）。
- **Worker 隔离**：LayoutChapterWorker @Concurrent 仅 import 格式类与纯计算；无 PageManager/PageSlot/UI 引用（冻结不变式保持）。
- 依赖方向：UI → ReaderHost → Facade → Core → {PageManager, PipelineManager} → Layout/Cache/Document → Worker。单向。

## 5. Boundary Leak List

| ID | Severity | Module | Problem | Evidence | Risk | Recommendation |
|---|---|---|---|---|---|---|
| B1 | P2 | ReaderHost | 门面聚合体量大（~1684 行 / ~55 私有方法） | §1 行数与清单 | 修改面广；无状态冲突 | 暂不拆；若后续频繁改同区块再按区域抽 ReaderDiagnostics/ReaderChrome |
| B2 | P2 | OhEngineCore | 诊断字段/日志与核心同置（benchMs/describePage/COLDSTART…） | publics 清单 | 仅可读性 | Observation-only 满足 §17；不迁移 |
| B3 | P2 | FlipPageController | 动画生命周期内协调 session（pin/setUserAnimating） | 源码 555/658/755 | 语义=动画窗口保护 | 保留（符合 Phase 10/16 冻结） |
| B4 | P2 | PageRenderer | `line.renderedY` 坐标回写渲染模型 | drawPageContent:274 | 单行坐标缓存 | 保留（渲染模型内部） |
| B5 | — | Diagnostics（GEOM_*/SESSION_*/P10） | 低频生命周期日志 | 打点采样 | 低 | 维持；无每帧日志 |

无 P0/P1 泄漏。

## 6. ReaderHost Audit

- 职责分类（按方法清单）：UI 生命周期（about*）、引擎生命周期（initEngine/doInitEngine/disposeEngine）、设置（restore/persist/preflight/applyFont*/Align）、导航（goToProgress/turnPageBy）、渲染协调（refreshPage）、选择/批注/书签/TOC、Chrome（statusTimer/pageNumberText/syncSystemBarContentColor）、自动翻页、诊断（logPageTurnSnapshot）。
- 判定：**是「按区域有序的宿主编排门面」，非杂乱 God Object**；独立子领域（设置/书签/TOC/自动翻页）各自内聚。**KEEP AS IS**（§9/B：虽体量大，但拆分对「独立生命周期/依赖方向」收益有限，且触动静置 API）。

## 7. OhEngineCore Audit

- 职责：session/lifecycle、typography、navigation 委托、cache/pin、pipeline 调度、lazy geometry、诊断。
- 判定：核心职责边界清晰；Page State/Pipeline/Ownership 均下行委托；**KEEP AS IS**（§11：无高独立性模块需外提）。

## 8. FlipPageController Audit

- 方法清单：动画几何（start/animate/finish/clip/shadow/fold）＋会话协调（preparePages/logReadyCheck/pin/unpin/setUserAnimating）。
- 判定：职责=手势意图→动画→提交；页面数据经 engine.peekPage/getCurrentPage（读），无解析/布局/UI 越权。**KEEP AS IS**。

## 9. PageManager / PipelineManager Boundary Audit

- PageManager：符合 §13（仅页面/navigation 状态；无 UI 概念；唯一 canonical）。
- PipelineManager：符合 §14（内容/分页/队列/后台/commit；无 UI/ReaderHost）。
- **均 KEEP AS IS**；二者已是边界良好的状态 Owner。

## 10. Migration Changes（暂停点前结论）

**本阶段（审计）：不迁移任何生产代码。**

若后续确认，推荐候选（最多 2，均 P2，非必需）：
1) （低价值）`OhEngineCore` 诊断日志（COLDSTART/SESSION/LOG 常量）抽 `EngineDiag` 常量表——收益可读性，风险零；**建议不做**。
2) （中价值，条件触发式）`ReaderHost` 的「Chrome/状态栏」与「引擎生命周期」两区块若未来 2 个月有 ≥3 次同频修改再抽；当前**不动**。

每项若执行：Move → Compile → arkts_check → build_project → 真机(Open/Back/翻页/jump/选择) 全过才保留。

## 11. Regression（本轮未改代码，故无新回归）

基线（Phase 16.4 终态）冻结：Worker 传输 155KB / JSON.parse 7–10ms / deserialize 11–14ms / commit 5–8ms / flip avg 5–6 · max ≤10 / mut=0 / LazyGeometry 4 对齐 402×4 一致 / Old-L2 兼容 / Session 隔离——本审计复confirm 上述机制源码未变。

## 12. Performance Comparison

N/A（只读，无 Before/After 变更）。保护线：任何未来迁移不得低于 §24 指标；出现回归即回滚。

## 13. Evidence Gaps

- ReaderHost 「归属体量」的主观度量（无硬指标）；以状态事实（无冲突）为准。
- UI 自动化盲区沿用 Phase 16.4（选择跨行/跨页/RSS 等）。

## 14. Final Verdict（审计阶段）

**PASS（只读审计）**：核心状态 Owner 清晰、依赖方向单向、Worker/LazyGeometry/Session 冻结不变式保持、无 P0/P1 边界泄漏、Build 与 Phase 16 关键链路指标不受影响（本轮零改动）。

> 按 Phase 17 启动指令：**本报告为暂停点。未经审计结论确认，不开始任何大规模重构/迁移。** 候选项与触发条件见 §10。