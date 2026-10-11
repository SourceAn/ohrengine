# Phase 0：代码分析、Baseline 与 Architecture Decision Gate

> 依据《00-总控架构与执行规则.md》完成 Phase 0。本报告只做分析与基线记录，
> 不修改核心代码，未进入 Phase 1。

## 0. 执行摘要

项目是 HarmonyOS Native 多 HAR 工程（entry + 9 HAR），EPUB/TXT 阅读引擎核心在
`ohrengine-ui-render`（OhEngineCore/PipelineManager/PageManager）、
`ohrengine-reader`（ReaderHost）、`ohrengine-common`（PageCacheManager/ParseCacheManager）。

关键结论：

1. **现存两级缓存**：L0 Parse cache（`.parsed.json`，仅 EPUB，整本 JSON）+ L2 Page cache
   （`meta.json` + `chapter_{i}.json`，EPUB/TXT 通用，按布局签名失效）。**没有 L1 ReadingState
   持久化，没有 L3 内存页缓存**。
2. **阅读位置恢复完全缺失**：`ReadingHistoryManager` 是纯内存 LRU，`loadProgress()` 是死代码，
   `ReaderHost.openAndLoad` 从不恢复位置，冷启动永远从第 0 页开始。
3. **打开即整本同步分页**：`OhEngineCore.open → layoutAllChaptersSync` 全书同步
   parse→layout→paginate→写盘，首个可见页也要等全书；大书第一次打开体验差，且
   `pageSlots`/`paginatedChapters` 全书常驻内存。
4. **pagination/char 坐标不一致**：`LineBox.startCharOffset` 是 text-node-local（每个
   RenderNode 从 0 计），`PageSlot.charRange` 混合 node-local offset，全书级 char offset
   另由 `chunkPlainTextLengths` 计算，没有统一 canonical offset unit。
5. **fingerprint 脆弱**：`size+mtime`，`Book.createBookFingerprint` 未使用；`.parsed.json`
   加载从不校验 fingerprint（stale parse cache 风险）。
6. **bookId 不一致**：history 用 `metadata.identifier → title`，annotation/bookmark 直接用
   `metadata.title`。无 schemaVersion/algorithmVersion。
7. **API24**：工程实际 `compatibleSdkVersion = 26.0.0`（已高于 24）。无 `canIUse` 门控。
   memory-pressure 相关 API（`application.onMemoryLevel` / `ProcessInfo.getMemoryPressure`）
   全工程 0 使用。改为使用 `@ohos.app.appAbility` 家族 API 时需注意 API 版本。
8. **TXT**：解析器整本读入内存一个字符串（>5MB 走 256KB 流式解码但最终 join 全文），
   **没有 virtual chapter**（vchapter 概念不存在），章节靠标题正则检测；位置只用
   chapterIndex+charOffset，charOffset 由 stripped plain text 决定。
9. **单线程模型**：全工程无 taskpool/Worker；并发=setTimeout(50ms) 排版队列 +
   layoutEpoch 代数失效 + 手写 RequestCanceller。缓存读写全部同步 fileIo 在主线程。

## 1. 代码结构与模块依赖（Phase 0 确认）

- `entry`（HAP）→ 9 HAR。依赖方向见 `docs/ai/architecture.md`。
- 引擎核心 `ohrengine-ui-render`：`OhEngineCore.open`（门面）、`PipelineManager`
  （排版队列/章节缓存读写）、`PageManager`（页槽/导航/阅读历史端口）、`LayoutEngine`、
  `TextBreaker`、`PageSplitter`。
- `ohrengine-reader`：`ReaderHost`（解压/打开/面板/Canvas 渲染）。
- `ohrengine-common`：`PageCacheManager`（磁盘分页缓存）、`ParseCacheManager`、
  `SecureArchive`、类型模型；零 OS 依赖外模块。
- `ohrengine-feature`：`ReadingHistoryManager`（内存）、`AnnotationStorage`(SQLite)、
  `BookmarkStorage`(preferences)、主题等。

## 2. 数据流（Phase 0 实测）

```text
Bookshelf.pushUrl('pages/Index', { bookPath })        // 只传文件路径
  → Index.ets → ReaderHost({ bookPath })
  → resolveBookSource            // EPUB: 拷贝+SecureArchive 解压; TXT: 直接用源文件
  → openAndLoad                  // engine.open(basePath, {sourcePath, cacheDir})
  → OhEngineCore.open
      ├─ ParserRegistry.resolve(ext)
      ├─ ParseCacheManager.loadParsedBook(dir)         // EPUB 仅命中 (FR-005)
      ├─ parser.parse(...)（全书 eager：spine 全部 XHTML 在内存）
      ├─ 填充 chapterHtmlCache + chunkPlainTexts/Lengths
      ├─ StrategyRegistry.resolve → router.render
      │    └─ ReflowRouter.render → createStubPage×N + prepareReflowPipeline
      ├─ PageCacheManager.computeLayoutSignature
      ├─ PageCacheManager.isCacheValid / invalidate  // size+mtime+signature
      └─ pipelineManager.layoutAllChaptersSync(N)    // ★ 全书同步分页+写盘
  → ReaderHost 拿当前页渲染 Canvas（currentGlobalPage 恒为 0）   // ★ 不恢复位置
```

- 翻页：`PageManager.goToNext/Previous/Page/Chapter/TocItem` → 更新 `currentGlobalPage`，
  stub 页触发 `ensureChapterReady(chunkIndex)`（同步 relayoutSingleChunk）。
- 字体/布局变化：`OhEngineCore.onFontSizeChanged / setLayoutProfile` →
  `refreshPageCacheForSettingsChange`（重算 signature + invalidate 全盘缓存）→
  `pageManager.reflowAllChapters()` → **全书同步重分页**，位置按 chapter+charOffset 恢复。
- 旋转：`recompileCss → reflowFromCurrentPage`（当前章起重排，仅 clamp 页码）。

### 2.1 缓存生命周期（现状）

| Cache | 载体 | 键 | 写入时机 | 读取位置 | 失效 |
|---|---|---|---|---|---|
| L0 Parse | `.parsed.json`（整本 ParsedBook JSON） | 目录路径 + .fingerprint.json(size+mtime)；**加载时不校验 fingerprint** | open 时同步 write；之后不更新 | OhEngineCore.open:349 | 仅结构损坏；无版本号 |
| L2 Page | `meta.json` + `chapter_{i}.json` | `PAGE_CACHE_VERSION=5` + size/mtime + layoutSignature(JSON) | `layoutAllChaptersSync` 同步 write-through；排队路径也写 | `PipelineManager.processNextInQueue` / `layoutAllChaptersSync` | meta 三元组不符即整库 invalidate（删目录） |
| L1 ReadingState | 无（`ReadingHistoryManager` 纯内存 LRU 50） | bookId | 翻页 500ms 防抖 recordPosition | `loadProgress()` 死代码无人调用 | 进程重启即失 |
| L3 内存页 | 无独立模块；`pageSlots[]`/`paginatedChapters[]` 全书常驻 | — | — | — | reflow 全量重建 |

- 所有缓存 IO 都是同步 fileIo（`statSync/readTextSync/openSync/writeSync`），没有异步写队列。

## 3. 身份与坐标（Phase 0 结论）

| 项 | 现状 | 结论 |
|---|---|---|
| ReadingAnchor | 无此类型。最近似：`Page.startPosition/endPosition`（章内 0-1）、`PageSlot.charRange:[num,num]`、`RecordPosition{chapterIndex,charOffset,progress}`、`Locator{paragraphIndex,wordIndex}` | 需新建 `{chapterId, paragraphIndex, paragraphHash, charOffset}` |
| charOffset 单位 | **UTF-16 code units**（`String.length`/`text[i]`）；但 `LineBox.startCharOffset` 是 text-node-local（LayoutEngine.ets:756-761 每节点从 0 累计）；`PageSlot.charRange` 在 node-local 与全局之间混合 | canonical logicalOffset 必须定义为 **stripped plain text 内的 UTF-16 全局 charOffset**（现有 `chunkPlainTexts`），或架构上新增 paragraph-global 坐标；Phase 1 必须统一 |
| paragraphIndex | 布局粒度是「text node」(RenderNode)，无稳定 paragraph 对象/索引 | 需在 parse 或 layout 阶段建立稳定的 paragraph 序列与 hash；HTML 多样式段需要每 text node 一个 anchor 候选 |
| contentFingerprint | `size+mtime`（PageCacheManager/ParseCacheManager 各自重复实现）；`Book.createBookFingerprint`（path+size，未用） | 保持轻量：size+mtime+maybe path-hash；`.parsed.json` 必须补校验 |
| bookId | history: `metadata.identifier||title`；annotation/bookmark: `metadata.title` | 统一为稳定 id；在 ParseCacheManager 持久化一份 |
| CacheKey | `meta.json` 三元组（version+size/mtime+layoutSignature） | 需扩展为 `{bookId, contentFingerprint, layoutSignature, layoutAlgorithmVersion, schemaVersion, pageRangeHash}` |
| layoutSignature | `JSON.stringify({viewWidth,viewHeight,density,baseFontSize,lineSpacing,...})`（已排除 theme/rubyColor） | 已存在且语义正确，直接复用；作为阅读状态保存的 signature |
| layoutAlgorithmVersion | 无 | 新增常量（TextBreaker/Knuth-Plass 结构性改版本号） |
| schemaVersion | 无 | 新增（ReadingState/Pagination 结构） |
| pageIndex | `currentGlobalPage` 全局槽下标 + `PageSlot.pageNumber`（章内） | 只作 UI/导航/±N 预取；禁入 CacheKey，禁作唯一恢复依据 |
| 连续性 | 相邻 Page 无 anchor 校验 | Phase 2 需校验 endAnchor↔startAnchor |

## 4. TXT 专项（Phase 0 结论）

- `TxtParser` 永远整本进内存：≤5MB `readTextFileSync`（ArrayBuffer(全文件)），>5MB
  `readTextFileChunked`(256KB 流式) 但仍 `parts.join('')`。6.2M 字小说 = 单个大字符串 +
  `.split('\n')` 数万行 + 每章 `<p>` HTML 副本 + `chunkPlainTexts` 副本，多处冗余。
- 无 virtual chapter：章节 href 为 `chapter-{i}` / `page-{i}`。
- 方案（Phase 1+ 落实）：采集大 TXT 时构造 `vchapter_XXXXX`（每 5000–10000 char、
  尽量在段落/换行边界），全部缓存/位置统一用 virtual chapter ID；`chapterIndex` 语义
  在 TXT 下即 virtual chapter index。canonical offset unit = 全局 UTF-16 char offset。

## 5. API24 与 Memory Pressure（Phase 0 结论）

- 工程 config：`targetSdkVersion=26.0.0, compatibleSdkVersion=26.0.0`（高于 spec 的 24，
  满足"兼容 API24"；未用任何 26 专属 API）。
- **Memory pressure 能力为空**：`application.onMemoryLevel` / `ProcessInfo.getMemoryPressure`
  等 0 使用。HarmonyOS API 24 提供 `application.on('memoryLevel')`/`MemoryLevel` 事件。
  Phase 3 将使用 `application.onMemoryLevel`（API 14+，兼容）。
- 现有静态内存帽：RemoteResourceLoader 64MB/128 条目、SecureArchive 解压上限、
  history LRU 50。L3 memory budget 需新增：按章节数 + 字节双约束。

## 6. Baseline（Phase 0 实测）

### 6.1 基准书目（真实样本）

| 样本 | 类型 | 规模 |
|---|---|---|
| 《一念永恒》（校对版全本）.txt | TXT | 7.4MB，≈626 万字符，≈6.77 万行 |
| The_Adventures_of_Sherlock_Holmes*.epub | EPUB | 308KB / 372KB |
| 妹妹人生_上卷.epub | EPUB | 2.2MB |
| 微舆.pdf | PDF | 5.3MB |

> 仓库内暂无 50–200MB / >200MB EPUB 样本与 100k/1m/5m 字 TXT 系列，Phase 7 验收前需补造样本。

### 6.2 现状关键路径成本（代码级推断，未真机计时）

| 路径 | 成本 | 说明 |
|---|---|---|
| 冷打开 EPUB/TXT | O(全书 chapters) 主线程同步分页+写盘 | `layoutAllChaptersSync`；首个可见页等待全部章 |
| 位置恢复 | 无（恒从第 0 页） | `loadProgress` 未接线、无持久化 |
| 字体改变 | 全书同步重排+全盘 cache invalidate+重写 | `reflowAllChapters` |
| 旋转 | 当前章起重排，clamp 页码 | 不按 charOffset 恢复 |
| 翻页 | 同步；目标章未布局则同步 relayout | `ensureChapterReady` 同步 relayoutSingleChunk（可能卡顿） |
| to-push 排版队列 | setTimeout 50ms 逐章 | 历史注释：30 章连跑 ~3.6s 阻塞（已改进为 50ms 让步） |
| ParseCache 命中 | `readTextSync` 整本 JSON 反序列化 + 全书 HTML 进内存 | 200MB+ EPUB 会整本反序列化，违反 L0 spec |
| TXT 内存 | 单大字符串+分章副本+plain text 副本 | 6.2M 字 ≈ 9–12MB+ 多副本 |

### 6.3 已有测试基线

- hypium 8 suites：TextBreaker、PageSplitter、StyleMapper、SelectorMatcher、
  FontFallbackChain、SecureArchive、PageCacheManager（纯函数 serialize/signature、
  disk IO 注明需真机）、PageGeneration（6 个 reflow 入口的 pageGeneration 递增）。
- 无 L2/L3 hit-rate、restore、open 计时的 benchmark；Phase 7 前需建立计时框架。

## 7. Architecture Decision Gate — Module Decision Table

> 依据《00-总控》"能复用就复用，能合并就合并，只有实际需要才新建模块"。

| Candidate | Decision | Existing Module | Reason |
|---|---|---|---|
| ReadingStateManager | **MERGE→ 演化 ReadingHistoryManager** + 新增 ReadingState 持久化 | `ReadingHistoryManager`(feature) + `ReadingHistoryTypes`(common) | 已有 LRU 收位置、端口已是 common 依赖；补 schemaVersion/ReadingAnchor/layoutSignature/lastReadTime 持久化 + `loadProgress` 接线即可；不新建空壳模块 |
| HotPageCacheManager (L2) | **REUSE/EVOLVE PageCacheManager** | `PageCacheManager`(common) | 已有 chapter_{i}.json + signature key；补 CacheKey 字段/PageRange/异步写/不再全书 paginate 的消费逻辑（在 PipelineManager/OhEngineCore 改） |
| MemoryPageCache (L3) | **NEW（小模块，放 common）** | 无 | 需独立 bounded LRU（3–5 章 + byte budget）+ memory-pressure shrink；`pageSlots` 是扁平数组不适合直接做 eviction key。新建 `MemoryPageCache`（纯逻辑、可测），PageManager 此为唯一持有者 |
| LayoutCache (Type A/B) | **SKIP（门控）** | 无 | Phase 4 仅在 Optimization Gate 证明仍瓶颈时做；测量为确定性估算（无 MeasureText），Type A 价值低；Type B 需 paragraph 化，Phase 1 后评估 |
| AssetCache | **SKIP（门控）** | `RemoteResourceLoader` / PageRenderer image caches / FontLoader pendingLoads | 已有 RemoteResourceLoader(64MB)、PageRenderer 双 image cache、font dedup；不重复造 ImageManager/FontManager |
| BookLayoutState | **MERGE→ PipelineManager** | `PipelineManager`（layoutEpoch/isProcessing/destroyed + EngineState） | 已有代数+队列+destroy 表达任务生命周期；不新建状态机，仅补优先级/取消即可（Phase 6） |
| TaskScheduler | **MERGE→ PipelineManager** | `PipelineManager.layoutQueue/scheduleNext/layoutEpoch` | 已有高/低优先级队列 + 50ms 让步 + epoch 失效；Phase 6 补 P0–P4 优先级与 Worker 上限即可 |
| DiskCacheQuotaManager | **NEW（小模块，common）** | 无 | 现有两缓存无配额/LRU；phase 6 需 per-book + global + LRU。放 common 供 L0/L2 共用 |
| CacheIndex | **SKIP（先不做）** | `meta.json` | 现有 per-chapter 文件已验证优先；Index 只在 startup lookup/配额确实需要时加，损坏可重建 |
| ImportCheckpoint | **MERGE→ ReaderHost 导入流程** | ReaderHost.resolveBookSource | 现有指纹跳过重解压近似 UNZIP_DONE；补 stage 标记（UNZIP/PARSE/INDEX/CACHE_DONE）落在 ReaderHost，不新建模块 |
| PageIndex→PageRange | 不建模块，新增类型+PageManager 演化 | PageManager/PageSplitter/EngineTypes | 新增 PageRange/ReadingAnchor 类型、PageSlot 扩展 endAnchor/startAnchor；禁 pageIndex 进 Key |

## 8. 一致性观测约定（Phase 0 baseline）

- 正确性判据：Cache ON/OFF 比较 logical page text hash、PageRange、startAnchor、endAnchor；
  禁用 screenshot hash 为主判据。
- 计划记录的 Debug/Benchmark 指标：
  - cold open、first readable page、restore、random jump、font change、翻页中位延迟
  - L2 hit rate、L3 hit rate、layout 次数、deserialize 次数
  - RSS/process memory、加载章节数、生成页数、disk read/write、page cache size
- 固定 hit-rate 分母 = 全书页数（每次 reflow 采样），避免分母漂移。

## 9. Phase 1 建议与前置项

1. **统一 canonical charOffset**：定义「stripped plain text 全局 UTF-16 charOffset」为阅读语义
   的 canonical logicalOffset；IO 如需 byteOffset 另做。建立可复用的 plain-text ↔
   paragraph ↔ chapter 映射（Phase 1 内新增 paragraphIndex/paragraphHash 数据结构）。
2. **接线阅读位置持久化**：ReadingHistoryManager 增加 preferences/JSON 持久化 +
   `loadProgress()` 调用点（ReaderHost.openAndLoad 或 OhEngineCore.open 尾部），恢复时
   禁止 pageIndex-only。
3. **修 stale parse cache**：`.parsed.json` 加载前校验 fingerprint（size+mtime），EPUB 打开
   校验 sourcePath。
4. 保留 `PAGE_CACHE_VERSION` 机制并引入 `layoutAlgorithmVersion`、`schemaVersion` 常量。
5. 大书痛点（整本分页/全线同步）放 Phase 2（L2 hot cache）解决；本 Phase 不碰。

## 10. 风险与未决问题

| # | 风险/未决 | 影响 |
|---|---|---|
| R1 | paragraph 无稳定模型：HTML 段可含多 text node/图片/表格 | ReadingAnchor.paragraphIndex 语义需定；计划以 layout 拍平后的 text-node 序列为 paragraph 单元，图片/块级节点作为独立 anchor 候选 |
| R2 | charRange 当前混合 node-local offset | Phase 1 必须统一坐标，否则 restore 错位 |
| R3 | 全书同步分页 + pageSlots 全书常驻 | Phase 2/3 才能根除；Phase 1 只保证恢复正确 |
| R4 | fingerprint 弱（size+mtime） | 均衡：不 hash 原文件（大书 IO 贵）；记录限制与 path/size 替换风险 |
| R5 | memory-pressure API 未验证 API24 真实行为 | 需用 `application.onMemoryLevel` + 真机验证；保留静态 budget 兜底 |
| R6 | TXT 整本内存 | Phase 1 先引入 virtual chapter 概念（上层），底层内存优化另评 |
| R7 | 现有 8 suites 多为解析/纯函数；cache/restore 集成测试需新增 | Phase 1 需补 restore 相关测试到 ohosTest |

## 11. Phase 0 结论

- 现状可复用：PageCacheManager（L2 基础）、ParseCacheManager（L0 基础）、layoutSignature、
  ReadingHistoryManager（L1 基础）、PipelineManager 队列/代数（调度基础）。
- 必须不做：不引入 Worker/taskpool（单线程模型保持）、不新建空壳模块（LayoutCache/
  AssetCache/CacheIndex 暂时 SKIP）、不重写解析器/TextBreaker/Knuth-Plass。
- Phase 1 起点：统一 charOffset → ReadingAnchor + ReadingState persist → restore 接线 →
  hash mismatch fallback。完成后 compile → test → benchmark → record → 汇报。