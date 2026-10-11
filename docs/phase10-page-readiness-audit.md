# Phase 10.0 — 冷启动页面恢复与双向翻页稳定性 审计

> 生成时间：2026-09-04（库存根 ↔ Phase 9 完成态）
> 审计对象：工作区源码（深度读取 ReaderHost / OhEngineCore / PageManager / PipelineManager / ReflowRouter / FlipPageController / SlideTurnController / PageRenderer）
> 审计结论均带 `文件:行号` 证据。本文档描述**当前代码真实发生的时序**，不是设计意图。
> 结论：ROOT CAUSE = PENDING，已定位 6 个高概率候选（S1–S6），全部可通过 instrumentation 一次区分。

---

## 1. 冷启动真实时序（含 file:line 证据）

```
ReaderHost.initEngine (ReaderHost.ets:403)
 └─ prepareWindowAndViewport (ReaderHost.ets:415) → resolveBookSource (ReaderHost.ets:419)
 └─ openAndLoad (ReaderHost.ets:562)
     └─ engine.open(bookBasePath, {sourcePath, cacheDir, readingStateDir}) (ReaderHost.ets:570)
         └─ OhEngineCore.open (OhEngineCore.ets:498)
             ├─ [A] 解析章节（解析缓存命中 / 全量 parse / TXT Lazy provider）(OhEngineCore.ets:550-671)
             ├─ [B] Router.render → ReflowRouter.render (ReflowRouter.ets:38)
             │    每章 createStubPage(i,1) → 每次 rebuildPageSlots()（O(章数²) 构建 1 页/章 stub）
             │    + prepareReflowPipeline → loadAndCompileCss (ReflowRouter.ets:48, PipelineManager.ets:793)
             ├─ [C] pageCacheContext 解析（L2 磁盘目录/signature/bookId/fingerprint）(OhEngineCore.ets:733-755)
             ├─ [D] layoutRangeSync(target章±HOT_RANGE=2) (OhEngineCore.ets:765-785, PipelineManager.ets:812)
             │    仅热窗 5 章分页：逐章 L3→L2 缓存命中，否则 parse+layout+split 全链路；
             │    结束后 host.rebuildPageSlots() 一次性重建（PipelineManager.ets:889）
             │    ⇒ 此刻 pageSlots = 热窗真实页 + 其余章节各 1 张 stub 页
             ├─ [E] state=READY → restoreLastReadingState (OhEngineCore.ets:797-802)
             │    → PageManager.restoreReadingState (PageManager.ets:1203)
             │      resolveChapterId → getChapterParagraphs(chunk)（TXT Lazy 时 provider 按章建段）
             │      → paragraphIndex+hash 定位 / ±40 邻域搜索 (PageManager.ets:1238-1255)
             │      → navigateToChapterCharOffset（章内逐页找文本片段）(PageManager.ets:1279)
             │      → currentGlobalPage = 命中页（stub 不检查！直接赋值，仅后续 updateReadingPosition）
             ├─ open() 返回（READY）
 └─ openAndLoad 收尾 (ReaderHost.ets:587-596)
     ├─ pageLines = engine.getCurrentPage().lines
     ├─ renderPage() → 绘制当前页 N（静态帧）
 └─ setupThemeAndListeners (ReaderHost.ets:424, 613)
     ├─ 注册 paramBus 'pageReady' 监听（open 之后才注册 → open 期间发行的 pageReady 全部丢失）
     ├─ switchTheme + restoreSettings → applyFontSizeLevel（若与默认不同 → onFontSizeChanged
     │    → reflowAllChapters → 全书 layoutAllChaptersSync（同步！）→ rebuildPageSlots (OhEngineCore.ets:1140-1154)
     └─ 以上全部完成才可交互（用户首帧可见早于此完成点的静态页）

用户点击/滑动「上一页」：
ReaderGestureController.handleTouch → turnPage(BACKWARD) (ReaderGestureController.ets:345-359)
 └─ flip.playFlip(BACKWARD, x, y) (ReaderGestureController.ets:348)
     └─ FlipPageController.start: (FlipPageController.ets:472)
        ├─ [F] turnDir=BACKWARD；首次无 FlipSession → else 分支仅校验 engine.peekPage 非空
        │      （FlipPageController.ets:510-523）——**不设置 flipPageRef / bottomPageRef**
        ├─ peekPage → PageManager.peekPage (PageManager.ets:250) → getPageByOffset(-1) (PageManager.ets:156)
        │      若目标 slot.state==='stub' → ensureChapterReady(slot.chunkIndex)（同步全章重排！）(PageManager.ets:366)
        ├─ [G] 动画帧 render()（FlipPageController.ets:298）
        │      flipPageRef 存在 → 静止层整页直绘 + 折叠页 clip+rotate 直绘
        │      bottomPageRef 存在 → bottomClip 区域绘制目标页
        │      ⇒ N-1 以「底页」角色出现（BACKWARD 翻回场景）；其内容 = slot.lines 直绘
        ├─ finishFlip → onPageTurned(BACKWARD) (FlipPageController.ets:677-699)
        │   → ReaderHost.onPageTurned → engine.turnPage (ReaderHost.ets:185-195)
        │   → PageManager.goToPreviousPage（stub 时 ensureChapterReady 同步；随后 preload 前 3 章 low 入队）(PageManager.ets:424-463)
        └─ refreshPage → renderPage（静态帧）(ReaderHost.ets:1422-1447)
            仅 prefetch 当前页图片 + prefetchNextPageImages（**没有 prev 页图片预取**）
```

结论：真实时序 = 同步热窗分页（D）→ 快捷恢复（E）→ 渲染当前页（Rend）→ **跳过了 N-1/N+1 的准备验证**（F）→ 动画直绘（G）。设计上"N±1 应该就绪"成立的前提（N 在热窗且非 stub、目标页非 stub、目标页资产已解码）没有任何一处被校验或保证。

---

## 2. 20 项审计清单

| # | 审计项 | 文件:行号 | 结论 |
|---|--------|-----------|------|
| 1 | Reader 打开入口 | ReaderHost.ets:562 `openAndLoad`；OhEngineCore.ets:498 `open` | open 期间无任何页就绪回调给 UI；P0 首帧由 renderPage 一次性直绘 |
| 2 | ReadingAnchor 恢复入口 | OhEngineCore.ets:798-802 → PageManager.ets:1203 `restoreReadingState` | 恢复在热窗分页**之后**；恢复页不检查 stub（navigateToChapterCharOffset 直接赋值 currentGlobalPage，PageManager.ets:1305/1333）；恢复失败静默回退 chapter 0/不跳页 |
| 3 | 当前页 N 创建流程 | layoutRangeSync → rebuildPageSlots（PipelineManager.ets:889；PageManager.ets:642） | N=热窗内真实页时 OK；N=热窗外 → N 是 stub，动画源页无内容 |
| 4 | Previous N-1 创建流程 | 无独立流程；仅「同一章分页」+ 动画前 getPageByOffset 触发 ensureChapterReady | **不保证前章就绪**；N-1 所在章不在热窗（±2）时必为 stub |
| 5 | Next N+1 创建流程 | 同上，但 ReaderHost.refreshPage **额外预取 N+1 图片**（ReaderHost.ets:1445） | 图片资产上 N+1 ≠ N-1（不对称，见 S3） |
| 6 | PageManager | PageManager.ets:69 | pageSlots 整数组替换（无 splice）；currentGlobalPage 下标钳制在 rebuild 末尾（:700-702）；getPageByOffset 对 stub 同步 ensure（:156-167） |
| 7 | L2 HotPageCache | PageCacheManager.loadChapter/saveChapter（PipelineManager.ets:335-355, 564, 883） | 只缓存整章分页（PaginatedChapter JSON）；按章粒度。热窗外章無缓存时页面为 stub |
| 8 | L3 MemoryPageCache | MemoryPageCache（PipelineManager.ets:129, 341-350） | LRU+byte budget；**无 pin 机制**；内存压力 shrink 到 1–2 章（OhEngineCore.ets:212-220）可把动画中页逐出 |
| 9 | LayoutCache | PageCacheManager.computeLayoutSignature（OhEngineCore.ets:734, 1126-1138）；signature 改变即 invalidate 全缓存 | 字号/行距/边距变化 → 全缓存失效 + 全量重排（reflowAllChapters 同步，OhEngineCore.ets:1152/1217）→ 窗口内页面 ALL 换新 Page 对象 |
| 10 | AssetCache | PageRenderer.localImageCache/remoteImageCache（PageRenderer.ets:51-52）；异步解码 + onContentChanged 回调（:666-759） | FlipSession 冻结纹理更新（isFlipActive → reader 端 PageRenderer 不 set cache，:678/:744）；资产解码完成时机与动画无联动 |
| 11 | ReflowRouter | ReflowRouter.ets:38-49 | 每章 1 张 stub；之后**没有任何章节被加入异步队列**——热窗外章节保持 stub，直到用户翻入（ensureChapterReady 同步重排）或 font 变化触发全量重排 |
| 12 | `layoutRangeSync` | PipelineManager.ets:812-890 | 同步；cache-first；结束后一次 rebuildPageSlots。热窗 ±2 章。**反向（N-1）与正向（N+1）对称**——页本身对称，资产不对称（S3） |
| 13 | `reflowAllChapters` | PageManager.ets:909-930 → layoutAllChaptersSync（PipelineManager.ets:909) | 同步全书重排；此期间当前页/动画输入全部被阻塞（THREAD_BLOCK_6S 风险，Phase 9 实测 2MB 首次 build 索引 >6s / 10MB≈12.4s；text reflow 同理）。动画期间 font 变化不会发生（主线程阻塞）——若动画期间 reflow 完成，**FlipSession 持有的旧 slot.lines 指向旧布局对象**（共享引用），内容为新页面替换后的旧度量 → 视觉错乱（S1/R1） |
| 14 | 翻页动画入口 | ReaderGestureController.ets:345-359；FlipPageController.start/playFlip（:472/:262） | **无就绪门禁**：动画直接接收 peekPage 返回的任何 PageSlot（stub/旧度量皆可）；首次 BACKWARD 无会话时干脆不设置页面引用（S2）；翻页占用时快速点击排队（pendingFlip）不检查目标状态 |
| 15 | 页面 Render Node 创建 | 阅读器为 Canvas 直绘：**不存在 RenderNode 依赖** | 动画依赖的是 `PageSlot.lines: LineBox[]`（PageRenderer.drawPageContent:242）与 PageRenderer 内 PixelMap 缓存 |
| 16 | 页面 Render Node 回收 | N/A（无 RenderNode）；PageRenderer.dispose 清 PixelMap（PageRenderer.ets:88-95） | 页面销毁（aboutToDisappear）后动画回调被 pageDestroyed 拦截（ReaderHost.ets:170-177, 186-200, 212-222） |
| 17 | 页面复用机制 | rebuildPageSlots 全量重建 slot 对象（PageManager.ets:642-703）；成功复用旧 Page.lines 引用（共享） | **旧 slot 对象在动画中被持有，其 lines 与最新 pageSlots 的 lines 可能不同代**（排版/重排后）。动画期无快照校验（无 pageGeneration 校验） |
| 18 | 后台预读 | goToNext/Previous 翻完后 queueChunkLayout(±3章, low)（PageManager.ets:406-415, 451-459）；ReaderHost.refreshPage 图片预取（:1432-1446） | 预读 = 翻页之后才发生；open 后热窗外章**零预读**；低优先级任务 50ms 间隔逐章执行（PipelineManager.scheduleNext:407-426），动画期间可能仍在跑 → 每章完成触发 rebuildPageSlots（替换 slot） |
| 19 | Scheduler 优先级 | LayoutPriority（PipelineManager.ets:69-75）；queue unshift（urgent） | P1_NEXT / P2_PREVIOUS 定义存在但**从不被使用**：翻页只调用 queueChunkLayout('low')（PageManager.ets:413, 457）；ensureChapterReady 是同步阻塞而非优先级调度 |
| 20 | 页面状态更新回调 | 'pageReady' 经 paramBus 发行（PipelineManager.ets:501, 532, 577, 581）；ReaderHost 在 open 后注册（ReaderHost.ets:644-649） | open 期间/之前的 pageReady 丢失；回调只触发 refreshPage 重绘当前页，不更新"目标页就绪"状态机 |

---

## 3. 动画实际依赖对象（确认清单）

`FlipPageController.render`（FlipPageController.ets:298-441）与 `SlideTurnController.renderFrame`（SlideTurnController.ets:136-164）实际使用：

- PageModel ⇒ `PageSlot`（chunkIndex / pageNumber / charRange / lines；本工程读器动画页模型 = PageSlot）
- LayoutResult ⇒ `PageSlot.lines: LineBox[]`（忽略 chunkIndex 的 chapter 归属，仅按行直绘）
- 字体/度量 ⇒ `engine.getFontSizeController().userFontSize`、`layoutProfile.letterSpacing`、`FontFallbackChain`（PageRenderer.ets:247-258）
- PixelMap（图片资产）⇒ PageRenderer.localImageCache / remoteImageCache（PageRenderer.ets:360-379）
- Canvas ⇒ CanvasRenderingContext2D 直绘（无离屏位图/纹理/Component）
- 覆盖层 ⇒ annotations / selection / mediaOverlay highlight

**不依赖**：RenderNode、ArkUI Component、PageSplitter 的 Page 结构本身（仅其 lines）。故审计项 15/16 的"RenderNode 生命周期"在本工程语境 = **LineBox 数组代际（slot.lines 引用）+ PixelMap 解冻时机**。

---

## 4. 生命周期竞态清单

| # | 竞态 | 证据 | 触发条件 | 动画影响 |
|---|------|------|----------|----------|
| R1 | slot 代际替换 | rebuildPageSlots（PageManager.ets:642）逐章异步完成（processNextInQueue:50ms tick，PipelineManager.ets:418） | open 后/翻页过程中异步章完成；reflowAllChapters/relayout 后 | FlipSession 持有的旧 slot.lines 为旧代数据 → 旧度量绘制（重叠/溢出/空白） |
| R2 | 目标章同步阻塞 | getPageByOffset stub → ensureChapterReady → relayoutSingleChunk 全程同步（PageManager.ets:156-167, 366-372；PipelineManager.ets:675） | 目标章不在热窗/未分页 | 点击后 UI 冻结（parse+layout+split 整章）→ "点击-卡住-动画开始" 违规模式 |
| R3 | N-1 资产缺失 | 仅 refreshPage 预取 next（ReaderHost.ets:1445 PageRenderer.prefetchNextPageImages:785）；N-1 无任何预取；动画中 isFlipActive 冻结缓存更新（PageRenderer.ets:678, 744） | 图片 EPUB + BACKWARD | N-1 图片未解码 → 翻回揭示空白图片区；等待解码完成 → "逐渐改善" ✓ 与症状高度吻合 |
| R4 | 首次 BACKWARD 无会话空白动画 | start() BACKWARD else 分支只 peekPage 非空即进入动画；flipPageRef/bottomPageRef 均 undefined（FlipPageController.ets:510-523）；render() 两处 `if !== undefined` 均跳过（:326/:339） | 打开后首个动作即"上一页" | 动画期画布仅有背景色+阴影（严重空白/错乱画面），动画结束后静态页才正确 |
| R5 | L3 逐出动画中页 | MemoryPageCache LRU byte budget（PipelineManager.ets:129）；shrinkToVisible 1–2 章（OhEngineCore.ets:212-220） | 内存压力 / 远处章入缓存挤占 | 目标页下次重放需 L2 反序列化或全量重排，动画延迟/内容闪变 |
| R6 | pageReady 丢失 / 状态无门禁 | open 后注册监听（ReaderHost.ets:644）晚于 open 内发行；动画入口无 ready 检查（FlipPageController.start） | 任何冷启动 | 动画在页面未达稳定态时启动 |

---

## 5. 双向不对称性（N-1 vs N+1）

| 维度 | N+1（正向） | N-1（反向） | 来源 |
|------|-------------|-------------|------|
| 热窗分页（章粒度页） | 对称（layoutRangeSync ±2 章） | 对称 | PipelineManager.ets:812 |
| 图片资产预取 | ✅ refreshPage 预取当前+下一 | ❌ 无 prev 预取 | ReaderHost.ets:1432-1446 |
| 动画会话初始化 | ✅ preparePages 设置 from/to | ⚠️ 首次无会话时不初始化（S2/R4） | FlipPageController.ets:494-526 |
| 翻后章预读 | ✅ goToNextPage preload +3 | ✅ goToPreviousPage preload −3 | PageManager.ets:406-415, 451-459 |
| 队列优先级 | 恒 'low' | 恒 'low'（symmetrically bad） | PageManager.ets:413, 457 |
| 目标页就绪检查 | 无 | 无 | FlipPageController.ets:601-616 |

---

## 6. 候选根因（S 假说，按动能排序）

- **S3（资产侧，图片 EPUB）**：N-1 图片零预取 + 动画冻结纹理 → 翻回空白；等待解码完成即"改善"。与用户描述**完全**吻合。纯文本 TXT 不受影响。
- **S2/R4（会话侧，首翻即反）**：冷启动后首个动作=上一页 → 无 FlipSession → 空白动画帧。
- **S1/R1（代际侧）**：目标页 slot 非最新代（异步章完成批量 rebuild / reflow 后旧 lines）→ 旧度量绘制错乱。
- **R2（stub 侧，热窗外章）**：N-1 所在章不在 ±2 热窗 → 点击瞬间同步全章重排（UI 卡死）→ stub 或旧内容进入动画。等待后该章已被 ensure/翻页缓存 → "改善"。
- **R5/R6（无保护侧）**：无 pin / 无 ready 门禁放大以上任意一种。

> 判定策略：**instrumentation 一次区分**。每个目标页输出 {globalPage, chunkIndex, pageIdentity(anchor/hash), state(stub/ready), lineCount, linesTextHash, pixelImageCount/decodedCount, slotGeneration, cacheLayer, readyState}，对比 N-1/N/N+1 冷启动即刻 vs 等待后的差异即可定位主导根因。

---

## 7. 需要修改的事实依据（供 Phase 10.1 决策）

1. **动画就绪门禁缺失**（无 RENDER_READY 等价物）——`FlipPageController.preparePages` 是唯一可加校验的**单一入口**（正向首次与连续翻页均经此；反向复用会话路径经其重建 from/to）。
2. **对称策略缺口**：P1 双向对称 = N-1 与 N+1 同策略。现有不对称点 = 图片预取（ReaderHost.refreshPage）与首翻会话初始化（FlipPageController.start）。
3. **热窗章粒度 ±2 够覆盖 N-1 页本身但不够覆盖"目标章外"与"图片解码"两个维度**；热窗外章保持 stub 直到被 ensure（同步）——这是"等待后改善"的另一来源。
4. **pin/unpin 不存在**：动画期间 L3 逐出/异步 rebuild 无保护。需最小机制（动画起 pin N-1/N/N+1 章 [chunkIndex]，动画毕 unpin）。
5. **不新增缓存层**：L2 承担页准备（已具备），L3 承担 PageModel/LayoutResult 复用（已具备）；Phase 10 只加"就绪状态 + 生命周期保护"。

ROOT CAUSE 正式判定留待真机 instrumentation 结果（Phase 10.1），当前 = PENDING。