# Phase 12.0 — Reader Engine 架构健康审计

> 生成时间：2026-09-04
> 审计对象：entry(Index/Bookshelf/DebugBookshelf) + ohrengine-reader + ohrengine-ui-render + ohrengine-common
> 证据型结论（真机 pid：40246/40974/42115；像素分析 dark_frac；hilog 时间戳）

---

## 1. P0 — “小书/大书打开后不显示”根因（已复现并修复）

### 1.1 复现
- 点击「TXT — Lazy 小书 (2MB)」→ 进程 39126 卡死在 14:05（无 COLDSTART 日志、无任何 TXT-LAZY 日志），UI 冻结、页面指示 **0/0**，big.jpeg 内容区 `dark_frac=0.00000`（全空）。
- 沙箱盘点：`benchmark_200mb.txt = 209,715,200 B`（200MB）存在。

### 1.2 根因（DebugBookShelf 测试护栏逻辑 Bug，非引擎显示链路）
```
DebugBookshelf.onBookClick('txt_lazy2')   entry/.../debug/DebugBookshelf.ets:123-162
  └─ txtPath = benchmark_2mb.txt
  └─ candidates = [benchmark_200mb.txt, benchmark_50mb.txt]
       if stat.size > 10MB → txtPath = benchmark_200mb.txt   ← 200MB 存在即命中！
  └─ pushUrl(Index, bookPath=benchmark_200mb.txt)
       → ReaderHost → OhEngineCore.open → TxtDocument.open
       → TxtIndexBuilder.build(200MB) 主线程首建索引（分钟级）→ UI 冻结 → 0/0 白屏
```
**「小书 2MB」按钮实际打开 200MB 文件**；「200MB 大书」按钮同样冻结（同一 PENDING：TXT 索引首建在主线程）。

### 1.3 修复（最小、可回滚）
- DebugBookshelf：按钮与目标大小强绑定——只复用同尺寸文件（`stat.size === target*1024*1024`），不再回退到 >10MB 候选；statusText 打印实际打开文件名。
- 验证：点击 2MB 按钮 → `openLazy path=.../benchmark_2mb.txt`，`COLDSTART FIRST_FRAME ready=3 lines=24`，big3.jpeg `dark_frac=0.125`（密集文字）；进程存活（40246）。

### 1.4 结论
> 小书/大书「不显示」共同根因 = **调试书架的路由 Bug 把入口错误地导到 200MB + TXT 索引首建主线程冻结**。引擎数据→分页→渲染→首帧链路本身在 demo/2MB/EPUB 均产出 `ready=3` 并渲染可见（像素证据）。读阅读引擎核心无显示回归。

---

## 2. 打开链路分层（数据流 vs 显示流）

```
Document Data  → ParsedBook/TxtLazyDocument（parse 层；索引 0-2ms 命中 / 首建 PENDING）
      ↓
Paginated Page → PaginatedChapter（PipelineManager.layoutRangeSync / 后台队列；热窗缓存命中）
      ↓
PageSlot       → PageManager.rebuildPageSlots（chunkIndex/pageNumber/lines/readyState）
      ↓
ReadyState     → PageReadyState（PageManager 标注；PageRenderer.describePageImages 补图片解码）
      ↓
Render Model   → LineBox[]（绘制模型，共享引用）
      ↓
Canvas Render  → PageRenderer.renderPage / FlipPageController.render（直绘）
      ↓
Visible Frame  → Canvas.onReady + renderPage（验证：shot2/big3 dark_frac≈12.5%）
```
分属：数据=Parser/LazyDoc；排好=PaginatedChapter；资源=PageRenderer 图片缓存；可见=Index Canvas。

---

## 3. 翻页卡顿分层定位（真机）

| 阶段 | 实测 | 主线程 | 是否阻塞帧 |
|---|---:|---|---|
| Input | P10 intent = 触摸同帧 | ✓ | 否 |
| Target readiness | 热窗/后台页 `ready=3` | — | 否 |
| Page lookup | pageSlots 直取 | ✓ | 否 |
| Layout（后台章） | **81–145ms/章**（冷缓存实时分页） | ✓ | **是**（动画期间重叠时） |
| Image decode | 异步；FlipSession 冻结更新 | ✗ | 否 |
| 后台 reflow | Phase 11：64 章 @100ms cadence | ✓（逐章） | 动画期间曾被阻断（已修复） |
| PageSlot | 动画持引用；后台不替换 | ✓ | 否（mut=0 实测） |
| Canvas | renderMs total 2-9ms | ✓ | 否 |
| Animation tick | frames=24-25 avgMs=5-6 maxMs=10-12 | ✓ | 否 |

验证样本（pid 40974 与 42115，2MB 书翻页）：
- Warm 背景并行翻页：`finishFlip avgMs=5-6 maxMs=10-12 mut=0`。
- 冷缓存后台章 81–145ms（Phase 11 BACKGROUND_CHAPTER 实测）是“翻页卡顿”的机制来源：动画正巧与后台章同帧 → 单帧 gap 100-145ms。

**修复**：`PipelineManager.scheduleNext` 在 `backgroundReflowActive && userAnimating` 时推迟后台章（Flip start→true，finish/cancel/dispose→false，OhEngineCore.userAnimating ← flip session）。真机验证：动画期间无 >50ms 后台打点、flip 依旧 avg 5-6ms / max 10-12ms / mut=0。

---

## 4. DebugBookShelf 解耦判定（§11/§12）

| 问 | 证据 | 结论 |
|---|---|---|
| 直接控制 Engine 生命周期？ | 无 engine 引用；只 `pushUrl(pages/Index)`（DebugBookshelf.ets:121/129/161/169/176） | NO |
| 注入测试配置（font/theme/turnMode/position）？ | 无；ReaderHost 由自身 settings 恢复 | NO |
| 改变 book path / cache 环境？ | 共享 `filesDir`（沙箱），书文件写入即影响该书的 L2 缓存指纹/mtime | **弱耦合（文件系统级间接）** |
| 持有 Engine/ReaderHost/PageManager/Cache？ | 无任何引用 | NO |
| 页面退出 dispose？ | DebugBookshelf 无资源；ReaderHost 由 Index 承载 | N/A |
| 重复 init/listener/open/render？ | 无 | NO |
| 导致 ReaderHost 重复创建？ | pushUrl 每次新建 Index/ReaderHost 实例（栈式路由），无复用 | **弱耦合（路由语义）** |

**判定：WEAKLY COUPLED。**
- 反向依赖：Reader Engine 无任何 DebugBookshelf 引用（rg 无结果）。
- 但存在**间接污染**：调试书文件写入共享沙箱 → 影响该书 open（2MB 按钮曾打开 200MB 即由此产生）。属“宿主侧测试护栏责任”，已修复按钮路由；引擎未因 DebugBookShelf 增加条件分支。

---

## 5. Index.ets 健康度

- **48 行 / 3 imports / 0 业务逻辑**——已是薄入口（仅透传 bookPath/barMode 给 ReaderHost）。
- 结论：**NOT God Object**；目标形态已达（App 路由 + 顶层组件）。

## 6. ReaderHost 健康度

- 1622 行 / 31 imports / 50 private 方法。
- 职责清单：Engine 生命周期、设置/排版应用、主题、阅读状态、渲染编排、翻页控制器、图片预取、注解/书签装载、诊断日志（P10/COLDSTART）、UI 状态（页码/状态栏/控制层）。
- 判定：**职责偏多但按区域有序**；下一步最小拆分候选（见 §8）不是本轮改动对象（避免“为了拆分而拆分”）。

## 7. 复杂度量化（§30）

| 文件 | 行数 | imports | public 方法 | private 方法 | 诊断行 |
|---|---:|---:|---:|---:|---:|
| pages/Index.ets | 48 | 3 | 0 | 0 | 0 |
| debug/DebugBookshelf.ets | 273 | 2 | 0 | 3 | 0 |
| ReaderHost.ets | 1622 | 31 | 0 | 50 | 24 |
| FlipPageController.ets | 962 | 6 | 1 | 16 | 12 |
| PageRenderer.ets | 877 | 7 | 4 | 3 | 1 |
| OhEngineCore.ets | 1430 | 44 | 56 | 6 | 19 |
| PageManager.ets | 1550 | 10 | 41 | 10 | 0 |
| PipelineManager.ets | 1032 | 17 | 22 | 2 | 4 |

Architecture Complexity Score（可解释指标）= 大型引擎类（OhEngineCore/PageManager）方法面大但职责内聚；ReaderHost 大但单一功能域；Index 已薄；诊断日志 55 处均非每帧（renderMs 每 15 帧节流、P10/COLDSTART 每翻页/每次 open）——**不存在每帧/每节点日志**（§20 检查通过）。

## 8. Phase 8–11 技术债盘点

| 债 | 位置 | 状态 |
|---|---|---|
| COLDSTART/BACKGROUND_CHAPTER/BACKGROUND_REFLOW_END 日志 | OhEngineCore/PipelineManager | 保留（低活跃度，可后移 Diagnostics 模块） |
| P10 intent/flipTurned/finishFlip(mut) | FlipPageController/ReaderHost | 保留（每次翻页 2-3 条，非每帧） |
| `chapterOriginMap`、`backgroundDelayMs/backgroundReflowActive/userAnimating` | PipelineManager | 保留（功能性，非 workaround） |
| DebugBookshelf 200/50MB 回退复用 | DebugBookshelf.ets | **已修复**（Phase 12） |
| `estimatePagesPerChunk`/stub 估算 | PageManager | 遗留但非本轮暴露项 |
| TXT 索引首建主线程（200MB 分钟级） | TxtIndexBuilder | **PENDING**（真机复现，200MB 按钮仍会冻结） |

---

## 9. 依赖方向

```
DebugBookshelf → pushUrl → Index → ReaderHost → OhEngine(Facade) → OhEngineCore
                                                              → PageManager/PipelineManager
                                                              → parsers/cache
PageRenderer/FlipPageController → OhEngine(Facade)（单向）
无：Cache→UI、Parser→ReaderHost、PageManager→BookShelf、Renderer→Index、Debug→Engine 内层
```
整体单向、分层清晰；唯一跨界点为 ReaderHost（宿主编排），符合规划。

---

## 10. 本阶段最小改动

1. **DebugBookshelf.ets**（P0）：小书/大书按钮与目标大小强绑定（修 200MB 冻结路径）；status 显示实际文件名。
2. **PipelineManager/OhEngineCore/OhEngine/FlipPageController**（P0 卡顿）：动画进行中推迟后台 reflow 章（`userAnimating` gate），不污染动画帧。
   - 回退：两处改动各自独立可还原（bookshelf 回退 = 改回 candidates 复用；anim-gate 回退 = 移除 scheduleNext gate 3 行）。