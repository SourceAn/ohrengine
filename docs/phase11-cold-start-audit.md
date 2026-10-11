# Phase 11.0 — 冷启动审计（Anchor-first 前置设计依据）

> 生成时间：2026-09-04
> 审计对象：工作区源码（Phase 10 终态） + Phase 8/9/10 docs
> 结论均带 file:line。

---

## 1. 字号恢复发生在哪里？

`ReaderHost.restoreSettings`（ReaderHost.ets:361-383，由 `initEngine → setupThemeAndListeners` 末尾调用，ReaderHost.ets:424/651）：
```
applyFontSizeLevel(loaded.fontSizeLevel, false)   → ReaderHost.ets:380
  → FontSizeController.setUserFontSize(size)+applyUserFontSize()   ReaderHost.ets:1077-1078
applyLineSpacingLevel(loaded.lineSpacingLevel, false)   ReaderHost.ets:381
  → engine.setLayoutProfile({lineSpacing})   ReaderHost.ets:1089
applyTextAlign(loaded.textAlign, false)               ReaderHost.ets:382
```

## 2. 为什么字号恢复会触发全书 reflow？

- `FontSizeController.applyUserFontSize()` 无条件调用构造回调 `onFontSizeChanged`（FontSizeController.ets:40-42；构造点 OhEngineCore.ets:363-365）。
- `OhEngineCore.onFontSizeChanged`（OhEngineCore.ets:1140-1155）：`setBaseFontSize + setLineSpacing + loadAndCompileCss + refreshPageCacheForSettingsChange + pageManager.reflowAllChapters()`。
- `PageManager.reflowAllChapters`（PageManager.ets:909-930）→ `layoutAllChaptersSync(全书章数)`（PipelineManager.ets:909-981）——**同步、全书、主线程**。
- `refreshPageCacheForSettingsChange`（OhEngineCore.ets:1126-1138）：signature 变 → `PageCacheManager.invalidate` 全量作废 L2。
- `applyLineSpacingLevel` 与 `applyTextAlign` 同样无条件走 `setLayoutProfile`（OhEngineCore.ets:1157-1221）→ affectsPagination → 同样的全量 reflow + 全量 invalidate。
- 三者无等值短路；**每次冷启动即使设置没变也会重放一遍全量 reflow**。

## 3. 哪些 layout signature 会因此失效？

`computeLayoutSignature(config, layoutProfile, baseFontSize)`（PageCacheManager.ets:272；调用点 OhEngineCore.ets:733-735/1130-1131）：
- `userFontSize`（本次恢复必变，17≠16）
- `layoutProfile.lineSpacing` / `letterSpacing` / `wordSpacing` / `textIndent` / `margins`
- `layoutProfile.textAlign`
- 恢复设置后 signature ≠ open 时写入的 signature → 全量 invalidate。

## 4. 哪些 cache 可以直接复用？

- **L2 磁盘分页缓存**（chapter_{i}.json）：open 时 signature 与持久化设置一致即可直接命中（`layoutRangeSync` 热窗 + 后续按需 ensure）。
- **L3 MemoryPageCache**：章节一旦命中即驻留（LRU bound 5 章）；动画窗口 pin 已就位（Phase 10/MemoryPageCache.ets:265-283）。
- **TXT Lazy**：`txt-index.json` + chapter JSON（Phase 9），`txtLazyIdxMs=0`（命中）。
- **L0 解析分块缓存**（EPUB parse/chapter_{i}.json）：与字号无关，始终可复用。
- 复用前提 = **open 前就把持久化排版参数应用到引擎**（本 Phase 11.1 的核心改动），使 open 时 signature 与磁盘写入一致。

## 5. 哪些 cache 必须重新布局？

- signature 变化涉及参数的**所有章节**（font-size/line-height/margins 影响每页断行）；但无需同一瞬间全量重建——只强制 Anchor 章±2 热窗（layoutRangeSync），其余进后台队列（P4_BACKGROUND），翻到时已缓存或按需同步。

## 6. ReadingAnchor 当前什么时候确定？

- `OhEngineCore.open` 内 `restoreLastReadingState`（OhEngineCore.ets:798-802 → 294-307）→ `PageManager.restoreReadingState`（PageManager.ets:1203-1269）→ `navigateToChapterCharOffset`（PageManager.ets:1279）设 `currentGlobalPage`。
- 时序：open() 中 `[D] layoutRangeSync(target章±2)`（OhEngineCore.ets:765-785）**之后**才恢复 → 热窗中心 = `peekReadingStateChapter()`（OhEngineCore.ets:313-324）已锚定恢复章。**热窗已经是 anchor-first 的**，瓶颈只在后续字号恢复的全书 reflow。

## 7. 当前页什么时候真正达到 RENDER_READY？

- 文本页：`rebuildPageSlots` 时标注 ready=3（PageManager.ets:674-689 区域，`pageImgCount===0 → RENDER_READY`）。
- 图片页：ready=2（LAYOUT_READY），需 `describePageImages` imgDec==total（PageRenderer.ets:822-861）才视为渲染就绪。
- 冷启动真机实测（小书）：open 后 ~70ms 即 RENDER_READY（Phase 10 Benchmark A）；**2MB 书被字号恢复全量 reflow 冻死在 T3→T4 之间（THREAD_BLOCK_6S 杀进程）**。

## 8. 当前 pageReady 回调在哪里发行？

`paramBus.publish('pageReady', chunkIndex)`：PipelineManager.ets:501（async 命中当前章 stub）、:532（空章）、:577（async 实时分页后当前章）、:581（未命中当前章时兜底）。layoutRangeSync / layoutAllChaptersSync 同步路径**不发行**（同步即就绪）。

## 9. 为什么 open 期间的 pageReady 会丢失？

- 监听注册在 `setupThemeAndListeners`（ReaderHost.ets:644-649），发生于 open() 返回之后；open 内/之前发行的事件无人消费 → **丢失**。
- 本 Phase：注册前移 + 就绪快照可查询（见 §11.3 实现），双通道。

## 10. 哪些操作必须留在 UI/main thread？

- 画布绘制、截图、你触摸→`renderPage`、Flip/Slide 动画 tick（16ms 帧循环）、`ensureChapterReady` 的 `rebuildPageSlots`、动画内页面 pin/unpin、`currentGlobalPage` 的读写。
- 任何影响 `pageSlots` 身份/`pageGeneration` 的提交点（buildPageSlots 的唯一调用方约定不变）。

## 11. 哪些操作可以进入 taskpool/Worker？

- 按最小改动原则，本 Phase **不上 taskpool**（现用 setTimeout 50ms 分片串行，PipelineManager.scheduleNext:407-426），仅：
  - 保证**单章单位** ≤ 帧预算（vch ~10KB 成立；超长 EPUB 章标记 PENDING）
  - 不连续占用：后台 50ms 间隔天然节流
- `TxtIndexBuilder.build` 首次索引（Phase 9 实测 ~12.9s 主线程）：当前不支持 partial index + anchor range → **PENDING**（保留现有命中路径，不重写 TXT Lazy）。

## 12. 如何保证 API24？

- 所有新增 API 为普通类方法/Map/数组；不引入新 SDK capability；`fileIo`/`hilog`/`preferences` 均 API24 已用（Phase 1-10 真机在跑）。
- Build: `compileSdkVersion` 不变，`build_project` 校验。

## 13. 如何保证翻页动画期间 PageSlot 不发生代际污染？

- Phase 10 已建立：`getPageGeneration()`（PageManager.ets:95-100）在每次 `rebuildPageSlots` 递增；Flip/Slide 动画持 PageSlot 引用（对象本身不被替换）；`finishFlip` 输出 `mut`（gen 变化）以量化污染（FlipPageController 已加）。
- 本 Phase 追加约束：后台 reflow 只 `paginatedChapters[i]` 替换 + 写缓存，**不重建 pageSlots**（processNextInQueue 非当前章 stub 时无 rebuild，PipelineManager.ets:573-582）；`rebuildPageSlots` 只发生在（a）翻入 stub 章的 ensure（b）font/reflow 显式入口。冷启动首帧后不再有自动全量 rebuild。

## 14. 如何保证 N-1/N/N+1 的 readiness？

- 复用 Phase 10：`layoutRangeSync(target章±2)`＝热窗（N-1/N/N+1 页在窗内就绪）；`describeNeighborWindow` + `PageReadyState` 可验证；动画入口 P10 intent 日志 + `pinChapters/unpinChapters` 保护。
- 本 Phase：读 Anchor-first（含字号恢复前置）后，热窗用与持久化一致的 signature 命中 L2 → 三页同窗就绪时延最短。

## 15. 当前 reflow 是否存在可以局部化的入口？

- **是**：`layoutRangeSync(from,to)`（PipelineManager.ets:812-890）是逐章 cache-first + write-through 的**局部化同步入口**——热窗章用它就地重排即可；其余章用 `queueChunkLayout(LOW)` 后台。
- 唯一需要移除的“局部化”破坏者 = 冷启动时 `onFontSizeChanged/reflowAllChapters/layoutAllChaptersSync` 全量入口（字号恢复前置后自然不触发）。

---

## 结论 → Phase 11.1/11.2/11.3 改动面

| 改动 | 内容 | 位置 |
|---|---|---|
| 11.1 | `ReaderFeatureFlags.anchorFirst`（灰度开关，默认 ON） | common/types/FeatureTypes.ets |
| 11.1 | `OhEngineCore.prepareOpenTypography({fontSize, lineSpacing, textAlign})`（open 前应用，不 reflow/invalidate） | OhEngineCore.ets |
| 11.1 | `ReaderHost.initEngine` open 前置摄录设置并应用排版 | ReaderHost.ets:403-429 |
| 11.1 | `applyFontSizeLevel / applyLineSpacingLevel / applyTextAlign` 等值短路（skip 引擎调用） | ReaderHost.ets:1073-1106 |
| 11.2 | `OhEngineCore.scheduleBackgroundReflow()`（非热窗章 → P4_BACKGROUND 队列） | OhEngineCore.ets / PipelineManager |
| 11.2 | `pageReady` 监听注册前移到 open 之前 + COLDSTART 阶段日志 | ReaderHost.ets / OhEngineCore.ets |
| 11.3 | ReaderHost 首帧只等 Anchor RENDER_READY，随后后台 reflow | ReaderHost.openAndLoad |

**不做**：重写 reflow/TXT Lazy/动画/PageSplitter；不上 taskpool；不实现 partial TXT index（PENDING）。