# Phase 23 Audit Report

> 审查模式：只读（未修改任何代码）  
> 审查范围：ohrengine-ui-render / ohrengine-reader / ohrengine-common / 各格式适配模块  
> 所有结论基于当前源码逐行验证，未采信任何历史报告结论。  
> 行号引用格式：`文件:行号`

---

## 1. Executive Summary

**三个问题不是三个独立 bug，它们共享同一个架构级根因，另有两个实现级 bug 使其恶化。**

| 问题                            | 定性                                                                                            |
| ----------------------------- | --------------------------------------------------------------------------------------------- |
| Issue A 进度无法可靠保存/恢复           | 架构语义缺陷（索引空间不稳定被当作稳定坐标）+ 实现缺陷（锚点歧义、hint 覆盖、恢复后回写）                                              |
| Issue B 总页数显示 31/31（实际 318 页） | **纯架构语义错误**：`totalPages = pageSlots.length`（已物化页 + stub 占位页数量），系统**不存在** `documentTotalPages` |
| Issue C 大量空白页                 | 架构后果（stub 页被导航进且不触发重建）+ 一个明确的实现 bug（`ensureChapterReady` 提前返回不重建）                             |

**核心架构事实**：`pageSlots` 是一个**物化缓存**（哪些章已排版就含哪些页，未排版章只有 1 页压缩 stub），但系统把它同时当作四样东西使用：

1. 总页数（`getTotalPages()` = `pageSlots.length`，PageManager.ets:151-153）
2. 导航目标空间（`goToPage/goToProgress` 直接按索引落点）
3. 进度分数（`currentGlobalPage / (pageSlots.length - 1)`，PageManager.ets:517）
4. 恢复提示坐标系（`visualPageIndex` 存的就是这个随时会变的索引，PageManager.ets:1216）

这四个用途都假设索引空间稳定且等于全书，而它两者都不是。**最小修复层级在 PageManager/core 层，不是 UI 层。**

---

## 2. Issue A — Reading Persistence

### 2.1 保存链路（实际状态）

```
翻页 turnPage/goToPage
 → currentGlobalPage 变更（PageManager.ets:406-407）
 → updateReadingPosition()（PageManager.ets:508-533）
    ├─ readingHistory.recordPosition（进度分数 = 物化相关，见 2.5）
    └─ setTimeout 500ms 防抖 → saveProgress()（PageManager.ets:526-533）
        → persistCurrentReadingState()（PageManager.ets:994-1012, 1226-1231）
            → buildCurrentReadingState()（PageManager.ets:1201-1221）
                → buildCurrentAnchor()（PageManager.ets:1146-1195）
            → host.saveReadingState → ReadingStateStore.save（原子写，ReadingStateStore.ets:47-100）
退出 destroy()
 → pageManager.persistCurrentReadingState() 兜底 flush（OhEngineCore.ets:1093-1094）✅ 存在
 → pipelineManager.shutdown() → pageManager.clearAll()
```

结论：**保存链路机械上是通的**（destroy flush 存在、原子写可靠、防抖窗口有兜底）。失败点全部在"保存的内容是什么"这一层。

### 2.2 实际失败点 ①：锚点片段首匹配歧义（P2）

`buildCurrentAnchor` 取页面首行文本前 12 字符（`PAGE_FRAGMENT_CHARS=12`，PageManager.ets:56, 1167），在章节段落列表里做 `indexOf` **取第一个命中段落**（PageManager.ets:1168-1179）。

- 中文小说中重复短行（对白、口头禅、章节套语）极常见 → 命中**更早的同文段落**；
- 锚点随后保存的是错误段落的 hash，恢复端 hash 校验"一致通过" → **静默错位**，无任何日志可查（hash 本来就是按错误段落算的）。

### 2.3 实际失败点 ②：空白/图片页退出 → 锚点降级为章首（P2，与 Issue C 直接耦合）

`buildCurrentAnchor` 在以下情况回退到"章起始（paragraphIndex=0, charOffset=0）"（PageManager.ets:1181-1194）：

- 当前页是 **stub 页**（首行 text=''——Issue C 的空白页正是这种页）；
- 当前页首行是**图片行**（text 为空）；
- 章节段落列表为空。

即：**用户在空白页上退出 → 保存的锚点 = 章首 → 恢复到章开头**。这是"恢复到错误位置"最常见的一条路径，且它把 Issue C 直接转化为 Issue A。

### 2.4 实际失败点 ③：恢复时 visualPageIndex 提示覆盖精确片段搜索（P1）

类型契约（ReadingStateTypes.ets:55）明确写着：

> `visualPageIndex`：派生态：视觉页码（**可 stale，禁止作为唯一恢复依据**）

但 `navigateToChapterCharOffset`（PageManager.ets:1343-1376）的实现把 hint 放在 **Priority 1**：

```
hintGlobalPage >= 0
 → 在目标章的页里找 == hint 的页；找不到 → 取与 hint 最近的页 → 直接 return
 （片段搜索根本不会执行）
```

问题：`visualPageIndex` 保存的是**上一次 session 物化拓扑下的全局页索引**。重新打开时热窗外全是 1 页 stub，全局索引拓扑完全不同——同一章的页全局起始号已漂移。于是：

- hint 精确命中 = 纯巧合；
- 否则钳制到章内"离 stale 值最近的页"= 首页或末页，**把本可由片段搜索准确定位的恢复变成错误恢复**，且发生在 hash 校验已通过（语义锚正确）的情况下。

这是 Phase 22 为修"降级锚"引入的补丁，反向覆盖了主路径，违反了自家 schema 注释的契约。

### 2.5 实际失败点 ④：恢复后立即回写，错误位置被固化（P1，退化棘轮）

`restoreReadingState` 成功路径末尾调用 `updateReadingPosition()`（PageManager.ets:1331-1332）→ 500ms 后 `saveProgress` → `persistCurrentReadingState`。即：**任何一次降级恢复（章首/错页）都会在打开后立刻覆盖磁盘上原本更好的锚点**。错误位置随打开次数单调恶化，无法自愈。

### 2.6 实际失败点 ⑤：ReflowRouter 清空了引擎刚填充的定位数据（P1）

`open()` 时序（OhEngineCore.ets）：

1. 解析后填充 `chunkPlainTextLengths`（EPUB chunked: 796-799 / eager: 916-917；TXT lazy: 865-868）与 `oldChapterToVchapterStart`（TXT: 870-871 / eager: 1160-1161）；
2. `router.render(parsedBook)`（:948）→ `ReflowRouter.render` → **`this.pageManager.clearAll()`**（ReflowRouter.ets:44）；
3. `PageManager.clearAll()` 清空 `chunkPlainTextLengths/chunkPlainTexts/oldChapterToVchapterStart/oldChapterVchapterCounts`（PageManager.ets:1485-1488）。

后果（本 session 全程生效）：

- `navigateToCharOffset` 的跨章累计恒为 0（PageManager.ets:616-621）→ **书签/标注/搜索跳转全局定位失效**；
- 恢复兜底路径 `getChapterGlobalCharStart` 恒为 0（PageManager.ets:1432-1439）；
- TXT 旧格式锚点 `chapter-N` 的 vchapter 映射为空 → `resolveChapterId` 把旧章号当 vchapter 序号直用（PageManager.ets:1131-1133）→ **TXT 迁移锚点解析到错误章**。

这同时是分层违规：Router（策略层）调用 PageManager 的**生命周期清理**方法，顺手抹掉了 engine 层刚建立的全书索引。

### 2.7 恢复链路全景

```
文件内容 ReadingStateStore.load（空 chapterId/anchor → 返回 null → 首页）
 → schemaVersion 校验（不等 → 恢复失败 → 首页）
 → contentFingerprint 校验（不等 → 恢复失败 → 首页）
 → resolveChapterId（失败 → chapterIndex=0 → "第一页"）
 → paragraphIndex + hash 验证（±40 邻域；失败 → goToChapter → 章首）
 → navigateToChapterCharOffset：
     ① visualPageIndex hint（stale，P1 问题，见 2.4）
     ② 段落片段逐页首匹配（12→20 字符，短片段同样有首匹配歧义）
     ③ charRange 中点近似（依赖被清空的 chunkPlainTextLengths，见 2.6）
 → restore 后 updateReadingPosition → 500ms 后回写（见 2.5）
```

任何一级失败都"安全回退"到章首/首页且 hash 可能自洽——**不 crash、不报错、静默错位**，与用户反馈"回到第一页或错误位置"完全吻合。

---

## 3. Issue B — Total Page Model

### 3.1 当前 totalPages 来源

```
UI ReaderHost.totalPages = engine.getTotalPages()（ReaderHost.ets:475/702/757/1234/1557）
 → PageManager.getTotalPages() = this.pageSlots.length（PageManager.ets:151-153）
```

`pageSlots` 构成（rebuildPageSlots，PageManager.ets:662-737）：

- 已排版章：真实页数；
- 未排版章：**1 页压缩 stub**（`createAllStubPages`/`buildCompactStubChapter`，PageManager.ets:1524-1565，单章 1 页 1 空行）。

打开 EPUB（31 章）：热窗（目标章 ±2）物化出真实页，其余 26+ 章各 1 个 stub → 总页数 ≈ 31。**答案：当前系统的 totalPages = A（当前已生成页面数量，含 stub 占位），B（整本书理论总页数）不存在。**

### 3.2 谁错误承担职责

- **PageManager/core 层**：从未定义 `documentTotalPages`。`PaginatedChapter.totalPages` 只有章级真值（stub 章 = 1），无全书聚合；`estimatePagesPerChunk`（PageManager.ets:742-750）存在但只服务旧 stub 路径，未用于全书估算。
- **UI 层无罪**：ReaderStatusBar（TOTAL 模式）、ReaderScrubBar、ReaderInfo.progress/seekInfo/tocPageNumbers 全部忠实消费 `engine.getTotalPages()`——修 UI 显示不解决问题，因为 `goToProgress`（PageManager.ets:302-321）同样按物化空间取整跳页、进度百分比随后台物化**漂移**（ReaderInfo.ets:36, 44-49）。

### 3.3 架构缺陷表述

物化缓存（pageSlots）与文档分页空间（documentTotalPages）两个概念被合并成一个字段。正确模型必须拆分：

```
materializedPages = Σ 已排版章真实页数（当前 pageSlots 减去 stub）
documentTotalPages = Σ 已排版章真实页数 + Σ 未排版章估算页数（或全书廉价预分页计划）
```

---

## 4. Issue C — Blank Page

### 4.1 PageSlot 实际状态机

用户设想的 `EMPTY/STUB/LAYOUT_PENDING/READY/FAILED` 五态**不存在**。实际：

- `PageSlot.state: 'stub' | 'ready'`（EngineTypes.ets:34）；
- `PageReadyState` 枚举（NOT_READY/DATA_READY/LAYOUT_READY/RENDER_READY/FAILED/INVALIDATED，EngineTypes.ets:18-25）——注释自述"仅诊断可见，**不驱动行为**"。

stub 页内容 = 1 个空行 LineBox（text=''）→ **渲染结果即整页空白**。

### 4.2 空白触发链（主因，P0 实现 bug）

后台 pipeline 完成某章排版后的提交点（PipelineManager.ets:692-702）：

```
仅当「当前页恰好是该章的 stub」时才 rebuildPageSlots
其他章节排版完成 → 只写 paginatedChapters[k]，pageSlots 里的 stub 原样保留（stale）
```

用户随后翻进该章（goToNextPage，PageManager.ets:406-412）：

```
slot.state === 'stub' → ensureChapterReady(chunkIndex)
 → pc.isStub 已为 false（后台早已排版完）→ 提前 return，不 rebuild（PageManager.ets:360-366）
 → currentGlobalPage 停留在 stale stub 槽位 → 显示空白页
 → 该空白持续到下一次偶发的 rebuild 事件（期间 saveProgress 还会把此页的"章首锚"存盘，见 2.3）
```

**这是"部分页面为空白、等待也不加载"的第一主因**：内容其实已经排好，只是页槽没换、导航没触发重建。

### 4.3 空白触发链（次因）

| 路径                                            | 位置                                        | 结果                                                                                                                  |
| --------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| goToPage / goToProgress（进度条/拖拽）落点为 stub       | PageManager.ets:269-280, 302-321, 385-394 | 异步 P0_USER_JUMP 入队，空白直到 pageReady；**若该章 HTML 缺失**（processNextInQueue 早退，PipelineManager.ets:552-557）→ **永久空白 stub** |
| 章节内容为空章                                       | PipelineManager.ets:611-628               | 生成 1 页空白页（语义上"正确"，但观感为空白）                                                                                           |
| 翻页预取入队（'low'）完成后不 rebuild                     | PipelineManager.ets:692-702 同一条件          | 加剧 4.2 的 stale 窗口                                                                                                   |
| 后台 reflow 150ms/章 + cap 32 + userAnimating 推迟 | PipelineManager.ets:489-501               | stub 消化慢，快速翻页必然撞上空白 stub                                                                                            |

### 4.4 结论

导航与物化**耦合但不完整**：翻页路径有同步 ensure，跳转路径是异步 queue，二者共享一套"stale 页槽不强制重建"的提交策略；`request page → layout → commit → display` 链路存在，但 `display` 依赖一个不被保证新鲜的 `pageSlots`，且 stub 页无加载态渲染（空白 = 加载中 = 加载失败 = 空章，四者不可区分）。

---


## 5. Root Cause Ranking

| 级别           | 根因                                                                                                                                                            | 影响                                 |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| **P0-A（架构）** | 物化缓存 pageSlots 被当作：总页数 / 导航空间 / 进度分母 / 恢复提示坐标系；无 documentTotalPages，全局页索引随 rebuild 漂移且无身份重映射（currentGlobalPage 是裸下标，rebuild 后仅钳制不重定位，PageManager.ets:734-736） | B 全部；A 的 hint 失效与位置漂移；C 的空间语义      |
| **P0-B（实现）** | pipeline 提交仅当"当前页=该章 stub"才 rebuild；`ensureChapterReady` 对已物化章提前 return 不 rebuild                                                                             | C 主因；C→A 联动（空白页存章首锚）               |
| **P1-C（实现）** | ReflowRouter/ImageRouter.render 调用 PageManager.clearAll()，清空 open 刚填充的 chunkPlainTextLengths / TXT vchapter 映射                                                | 全 session 全局字符定位失效；TXT 旧锚解析错章；分层违规 |
| **P1-D（实现）** | 恢复时 stale visualPageIndex 提示优先于精确片段搜索（违反自身 schema 契约）；恢复后立即回写降级位置（退化棘轮）                                                                                       | A 的"错误位置"与"越用越差"                   |
| **P2-E（实现）** | 锚点片段 12 字符首匹配歧义（hash 自洽 → 静默错位）；图片/空白页锚点降级章首                                                                                                                  | A 的错位路径                            |
| **P2-F（实现）** | 阅读历史 progress = currentGlobalPage/(materialized-1)，随物化漂移                                                                                                      | 历史记录/续读列表位置失真                      |
| **P3-G（实现）** | ImageRouter 逐章 createImagePage 各做一次全量 rebuild（O(n²)）；PDF 链路（Parser→REFLOW→ReflowRouter）已统一但被 ReaderHost 入口硬编码拦截（ReaderHost.ets:617-620）"PDF 暂不支持"             | 性能；能力不一致                           |

**统一链路审查结论**：核心层无重复实现——EPUB/TXT/PDF(文本提取) 均走 `ReflowRouter → PageManager/PipelineManager` 同一分页核；CBZ 走 ImageRouter 产出图片页章，但页槽消费同源。发现的三处格式分叉：① 内容供给三路径（EPUB chunked / TXT lazy / eager）填充的索引被统一清空（P1-C）；② TXT vchapter 与 EPUB href 两套 chapterId 语义在 resolve 处汇合（正确）；③ PDF 被 UI 入口拦截而非核心层不支持。

---


## 6. Minimal Fix Direction（只给层级与原则，不含代码）

1. **totalPages（修在 PageManager/core，禁止只改 UI）**
   - 在 PageManager 引入 `documentTotalPages` 派生量：已物化章取真实页数和 + 未物化章取确定性估算（已有 `estimatePagesPerChunk` 可升级为按章纯文本长度估算；TXT lazy/EPUB chunked 均有 plainTextLength 索引可用）。
   - UI 状态条/进度条/`goToProgress` 全部改读 documentTotalPages；`goToProgress` 先映射到文档空间，再解析到 (章， 章内页) 按需物化。
   - 不持久化估算值（避免 L2 schema 变更）；物化推进时增量修正即可。
2. **导航与页槽（修在 PageManager.ensureChapterReady + PipelineManager 提交点）**
   - `ensureChapterReady` 的判定依据改为"**当前页槽本身是否 stub**"，而非"章是否已物化"——是 stub 就 rebuild（已物化则 rebuild 即得真页，未物化才 relayout）。
   - rebuildPageSlots 后必须按**页身份**（chunkIndex + 章内 pageNumber）重映射 currentGlobalPage，禁止只做数值钳制。
   - 中期方向：currentGlobalPage 由 (chapterIndex, chapterPageIndex) 二元组派生，全局索引只作展示。
3. **持久化（修在 PageManager 恢复/保存两端）**
   - 恢复主依据 = 语义锚（chapterId + paragraphIndex + hash + charOffset）；visualPageIndex **只在锚降级**（savedOffset=0 或 hash 落章首）时作为 tie-break，或校验 `savedLayoutSignature == currentSignature` 相等才可用——把 Phase 22 的优先级倒转回来。
   - 恢复结果为降级（回退章首/首页）时**禁止回写** ReadingState（抑制 restore 后那一次 updateReadingPosition 触发的 saveProgress）。
   - 锚点片段歧义：片段匹配从"第一个命中"改为"全部命中取离 paragraphIndex 最近者"，或利用页首行必然落在某段落**边界后**的性质缩小候选。
4. **生命周期（修在 Router 层）**
   - ReflowRouter/ImageRouter.render 不得调用 `pageManager.clearAll()`；Router 只负责创建 stub/图片章。open() 中被清空的 `chunkPlainTextLengths` 与 TXT vchapter 映射由 engine 在 router.render 之后重建或恢复（单一 owner：PageManager/engine，Router 无清理权）。
5. **冻结区域（本次均未触碰，修复时同样不得触碰）**
   - PipelineManager 队列优先级/调度语义（只允许改"提交后是否 rebuild"的判定条件，属 host 回调既有调用点）；
   - Worker JSON 边界（LayoutChapterWorker 输入快照/LayoutResult 协议）、Lazy Geometry、Session 校验、L2 兼容（documentTotalPages 不落盘 → 无 schema 变更）。

---

## 7. Frozen Boundary Check

| 冻结项                                        | 状态                                           |
| ------------------------------------------ | -------------------------------------------- |
| PageManager ownership（pageSlots 唯一所有者）     | ✅ 未破坏；修复方案仍在 PageManager 内完成 rebuild+重映射     |
| PipelineManager queue                      | ✅ 未触碰；调度/优先级/epoch/取消令牌语义保持                  |
| Worker JSON boundary                       | ✅ 未触碰                                        |
| Lazy Geometry（Phase 16.3）                  | ✅ 未触碰                                        |
| LayoutResult protocol                      | ✅ 未触碰                                        |
| Session validation（epoch/cancel/destroyed） | ✅ 未触碰                                        |
| L2 compatibility                           | ✅ 未触碰；documentTotalPages 为运行时派生量，不进缓存 schema |

---

## 附：排版质量补充审查

**已具备的能力（质量合格）**：

- 行首/行尾禁则完整（TextBreaker.ets:19-29：全角标点、日文小假名、长音符号等），断行时双向推挤（:281-285）；
- Knuth-Plass DP 最优断行 + 贪婪回退兜底（含 onDpFallback 观测）；
- 首行缩进 2em 随字号联动（fp×2，TextBreaker.ets:95-101），显式设置可覆盖；
- 两端对齐独立引擎（JustifyEngine）+ 0.99 宽度安全系数 + 惰性逐字几何重建兜底渲染偏差；
- 孤行控制 orphanLines=2；图片行独占页。

**发现的问题**：

1. **寡行（widow）处理是空实现**：PageSplitter.ets:185-189 整段注释 `// TODO: 回溯到前一页合并`——页末/章末单行悬置无控制（孤行只做了单向 orphan 合并）。
2. **无标点挤压（punctuation compression）**：禁则只做"推到邻行"，行首行尾全角标点不压缩，两端对齐下标点悬挂与行内空隙均匀性弱于成熟阅读器。
3. **宽度靠系数估算而非字体度量**（CJK 0.55 系数系）：生僻字/全角英数/emoji 场景可能出现实际渲染溢出或提前断行；0.99 safetyMargin 是缓解不是消除。
4. **间距双轨制**：段距固定为 CSS `p{margin-bottom:0.5em}`（PipelineManager.ets:243），行距走 TextBreaker 增量——用户可控行距不可控段距；中文出版惯例（纯缩进零段距）无法通过设置达到。
5. **加载态渲染为纯空白**：stub 页无"加载中"占位，空白页/加载中/空章/失败四种状态视觉不可区分——这是 Issue C 观感被放大的直接原因。
6. **进度百分比随物化漂移**：PERCENT 模式分母是物化页数，后台 reflow 推进时同一页显示的百分比会自行变化（属 Issue B 在排版无关 UI 上的外溢）。

---

## 最终结论

1. 打开后显示真实总页数 → 需要在 core 层建立 documentTotalPages 派生模型（P0-A）；
2. 任意页面可导航并自动生成 → 需要修 ensureChapterReady 判定 + rebuild 后按页身份重映射（P0-B）；
3. 阅读位置可靠恢复 → 需要倒转 hint 优先级 + 禁止降级回写 + 保留全书索引（P1-C/P1-D/P2-E）；
4. 四格式同一核心 → 核心已统一（EPUB/TXT/PDF 同核，CBZ 同消费端），需清除 Router 层生命周期越权与 UI 入口对 PDF 的人为拦截。

**三个用户问题同根：把一个会漂移、不完整的物化缓存，当成了稳定、完整的文档坐标系统在使用。**
