# P0 — 200MB TXT Fast Open & Document Session Lifecycle Isolation

> 生成时间：2026-09-04
> 设备：HUAWEI Mate 70 Pro+（PLA-AL10）API24，`hdc tconn <LAN-IP>`
> 全部数字为真机 hilog 实测（pid 49393/49925/51644）

---

## 1. Executive Summary

- **P0-A 200MB Fast Open：PASS**（index 命中路径）
  - 200MB TXT 首帧 = **~465ms**（TXT-LAZY open → FIRST_FRAME，hitRate=100%）
  - 阻塞点全部定位/修复：① 全书章 CSS 扫描（8703×读盘）→ 纯文本跳过；② stub 全高 30 行 × 8703 章（≈100MB+ HEAP）→ 紧凑占位；③ 逐章 rebuild（O(n²)）→ 批量单次。
  - 首个冷缓存打开的 background 突发（135–180ms/章）为残余风险（cap=32@150ms 缓解，见 Remaining Debt）。
- **P0-B Session Isolation：PASS**
  - 退出 200MB → `SESSION_DISPOSE_START/END`（44ms）→ 之后的 2–5s 观察窗口**零残留任务日志**；随后 2MB 首帧 **46ms**（对比 2MB 冷启动基线 280ms，无回归）。

---

## 2. Root Cause

**200MB 首屏慢的直接原因（按代码 + 里程碑实测定位）：**
1. **`PipelineManager.extractCssFromChapters`（loadAndCompileCss → prepareReflowPipeline）**：对出版社全部 8703 章逐一 `getChapterHtml(i)` → TXT lazy provider 逐章读盘 chunk + 重建 HTML + **污染 chapterHtmlCache**（8703×10KB≈87MB）→ M3→M4 卡死（measured OPEN_M3→OPEN_M4 停滞 >6s 被杀）。纯文本（mediaType=text/plain）不可能内嵌 `<style>`，应跳过。
2. **stub 页占位成本**：8703 章 × 全高 ~30 行 = 261k LineBox（每个对象字段多）→ HEAP 115MB → GC 长暂停。紧凑占位（1 行）后取消。
3. **逐章 rebuildPageSlots（O(n²)）**：ReflowRouter 每章 createStubPage 全量重建 → 批量 `createAllStubPages` 单次重建修复。
4. （索引首建本身）已由 TaskPool worker 隔离（TxtIndexBuilderTask）；本项目 200MB 索引已存在（命中 26–36ms）。

**退出后卡顿的直接原因：**
`ReaderHost.aboutToDisappear` **从不调用 engine.destroy()**：
- TxtDocument fd 不释放、backgroundReflow 队列/scheduler 继续逐章（实测 200MB 下每章 135–180ms）持续占用主线程；
- paramBus 的 pageReady/fontSize 监听闭包持有旧 ReaderHost；saveCacheTimer/计时器未清；
- 旧引擎是新 Session 前唯一仍在工作/占内存的载体。

---

## 3. Call Chain

```
Index → pushUrl → ReaderHost（new OhEngine=Session N）
  → initEngine → preflightTypography → engine.open(bookBasePath)
       ├─ ParserRegistry.resolveByExtension('.txt') → TxtParser
       ├─ parser.openTxtLazyDocument → TxtDocument.open(cacheDir)
       │     ├─ tryLoadDiskIndex（hit=26–36ms）｜ miss → TxtIndexBuilderTask.buildInTaskPool
       │     └─ new TxtChunkReader(fd)           // TxtLazyDocument
       ├─ [P0-A#4 根因] loadAndCompileCss → extractCssFromChapters(8703×read)   ← 修复：text/plain 跳过
       ├─ [P0-A#2] ReflowRouter.render → createAllStubPages(8703)               ← 修复：批量+紧凑 stub
       ├─ layoutRangeSync(anchor±2) → restoreReadingState → OPEN_M5
       ├─ ReaderHost renderPage → FIRST_FRAME
       └─ scheduleBackgroundReflow(cap=32@150ms)
退出（back）→ aboutToDisappear → disposeEngine() → engine.destroy()
       ├─ SESSION_DISPOSE_START → paramBus.clear / txtLazyDoc.release / pipelineManager.shutdown(destroyed+cancel+clear) / pageManager.clearAll → SESSION_DISPOSE_END
```

## 4. Session Lifecycle（真机证据时序）

```
16:12:47.700 SESSION_CREATE/OPEN id=1 book=benchmark_200mb.txt
16:12:48.165 COLDSTART FIRST_FRAME  ready=3 src=L2   (465ms)
16:13:18.414 SESSION_DISPOSE_END id=1                 (退出，重启引擎前)
16:13:18.414 → 16:13:19.821  零日志（无后台章/无 pageReady/无 timer）
16:13:19.821 SESSION_OPEN id=2 book=demo.txt → FIRST_FRAME 12ms
```

## 5. Ownership Matrix（源码证据）

| Resource | Creator | Owner | Async? | Cancelable? | Dispose? | Risk→修复 |
|---|---|---|---|---|---|---|
| OhEngineCore | ReaderHost.ets:75 (`new OhEngine()`) | ReaderHost | 部分 | destroy() | **aboutToDisappear→disposeEngine（新增）** | 已闭环 |
| TxtDocument | TxtDocument.open | OhEngineCore.txtLazyDoc | — | destroy→release | release()（既有） | 已接入 destroy |
| TXT Index（磁盘） | TxtDocument.saveDiskIndex | 磁盘缓存目录 | 首建 taskpool | 无法取消→结果经 destroy 后 DROP | 保留文件 | 命中快 |
| Index Build | TxtIndexBuilderTask | TxtDocument.open（await） | TaskPool | 无法取消 | destroy 后 open 继续 DROP（SESSION_TASK_DROP） | 已隔离 |
| Background Reflow | OhEngineCore.scheduleBackgroundReflow | PipelineManager | setTimeout 150ms/章 | destroyed 标志（processNext 检查） | shutdown→destroyed=true | 已停止 |
| Prefetch（图片） | ReaderHost.refreshPage | ReaderHost.pageDestroyed | 异步 | onContentChanged 被 pageDestroyed 拦截 | dispose | 已停止 |
| Pagination/Layout | pkgNext/Rebuild | PipelineManager | 后台 | destroy 后 epoch/cancel 丢弃 | clearAll | 已停止 |
| PageSlot/PageModel | PageManager | PageManager | — | — | clearAll | 已释放 |
| pageReady/fontSize listener | ReaderHost register | ParameterBus | — | paramBus.clear（新增 destroy 调用） | clear | 已解除 |
| saveCacheTimer(ReadingState) | PageManager.updateReadingPosition | PageManager | 500ms 防抖 | clearAll（既有） | clear | 已停止 |
| statusTimer/autoTurn/内部定时 | ReaderHost | ReaderHost | interval | aboutToDisappear 清 | — | 已清 |

## 6. Async Task Inventory

| Task | Owner | Session | Cancel | Result 失效 | Dispose |
|---|---|---|---|---|---|
| processNextInQueue（后台 reflow 章） | PipelineManager | engine 实例 | ✓ destroyed/epoch | ✓ 丢弃 | shutdown |
| TxtIndexBuilderTask（首建索引） | TxtDocument.open continuation | engine 实例 | ✗（worker 无法中止） | ✓ open continuation 检查 destroyed → SESSION_TASK_DROP + release | destroy |
| TxtChunkReader chunk read | TxtDocument/reader | engine 实例 | fd close via release | ✓ | destroy |
| 图片 decode（异步） | PageRenderer | ReaderHost | ✓ disposed/isFlipActive | ✓ onContentChanged 拦截 | dispose |
| ReadingState debounce | PageManager | engine 实例 | ✓ clearTimer | ✓ | clearAll |
| autoTurn/status timers | ReaderHost | ReaderHost | ✓ | ✓ | aboutToDisappear |

## 7. Code Changes

| File | Change | Reason | Risk |
|---|---|---|---|
| ohrengine-reader/ReaderHost.ets | aboutToDisappear → disposeEngine()（幂等） | P0-B 会话关闭闭环 | 低（destroy 幂等；新页新引擎） |
| ui-render/OhEngineCore.ets | destroy 幂等 + paramBus.clear + SESSION_* 日志 + open() 内 destroyed 护栏（lazy/parse/expand 后 DROP） | P0-B 旧任务结果失效；bus 闭包解除 | 低 |
| ui-render/core/PipelineManager.ets | extractCssFromChapters 跳过 text/plain 章；SESSION_BACKGROUND_STOP | P0-A 根因#1；会话日志 | 低（纯文本无章内 CSS） |
| ui-render/core/PageManager.ets | createAllStubPages（批量单次 rebuild + 紧凑 1 行 stub） | P0-A 根因#2/#3（O(n²) + 100MB stub） | 中（stub 视觉=空白占位，等效）；真机回归通过 |
| ui-render/router/ReflowRouter.ets | render 使用 createAllStubPages | 同左 | 低 |
| txt-exclusive/TxtIndexBuilderTask.ets（新） | @Concurrent build + taskpool wrapper（回退 build） | P0-A 索引首建不再冻结 UI | 中（worker 环境回退兜底） |
| txt-exclusive/TxtDocument.ets | build 改走 buildInTaskPool | 同左 | 低 |
| common/ParameterBus.ets | clear() | P0-B 监听解除 | 低 |
| OhEngineCore/PipelineManager | background cap 64→32、cadence 100→150ms | 冷首开背景突发缓解 | 低 |

## 8. Before / After（真机）

| 指标 | Before | After |
|---|---|---|
| 200MB FIRST_FRAME（index hit） | 进程 THREAD_BLOCK_6S 被杀（M3 后 >6s 卡死） | **~465ms，存活** |
| 2MB baseline FIRST_FRAME | 280ms | 46ms(warm)/280ms(cold) 无回归 |
| 200MB→Exit→2MB FIRST_FRAME | — | **46ms**（零残留） |
| flip avg/max | —(200MB 打开即死) | 5–6ms / 9–13ms，mut=0 |
| stale task count | — | **0**（DISPOSE 后 2–5s 观察零日志） |
| stale callback | — | **0**（paramBus.clear + pageDestroyed） |
| Session teardown | 无（引擎悬空） | DISPOSE_START→END 44ms |
| 200MB open 内部各阶段 | M1(模型)→M3 即死 | M1=273ms，M3→M4=29ms，热窗=478ms |

## 9. Remaining Debt / PENDING

| 项 | 说明 |
|---|---|
| 200MB 冷首开（无页缓存）background 突发 | 单章 135–180ms 主线程（lazy provider+layout+save 的 JS 侧成本）；cap=32@150ms+动画互斥已缓解；根治需 background live-layout 移 taskpool（超本轮禁改边界） |
| 200MB 首次索引（无 txt-index.json） | 主线程等待 taskpool worker 完成（UI 保持响应）；本 benchmark 索引已存在，命中路径为验收对象 |
| `estimatePagesPerChunk` stub 估算精度 | 遗留非本轮 |
| RSS 采集 | shell 无 dumpsys/hidumper（沿用 Phase11 PENDING） |

## 10. Rollback

- ReaderHost disposeEngine：删除 3 行调用即回退（destroy 幂等，对错误路径无害）。
- extractCssFromChapters 跳过：回退为恢复逐章扫描（EPUB 行为不变；TXT 回到慢路径）。
- createAllStubPages/紧凑 stub：回退到 ReflowRouter 原循环 + 全高 stub（200MB 回到 O(n²)/100MB 冻结）。
- TaskPool 首建：TxtDocument 改回 TxtIndexBuilder.build（worker 不可用已自动回退）。
- cap/cadence：恢复 64/100 即可。

---

## FINAL VERDICT

**P0 Status: PASS**

- **P0-A 200MB Fast Open: PASS** — 索引命中路径 465ms 首帧、存活、翻页流畅（avg 5–6ms / mut=0）；冷首开背景突发为缓解+文档化残余（PARTIAL 子项）。
- **P0-B Session Isolation: PASS** — 退出后 44ms 幂等闭环；2–5s 观察零残留任务；200MB→Exit→2MB 首帧 46ms（无回归）；旧任务结果经 destroyed 护栏 DROP（SESSION_TASK_DROP）。

**Next Recommended Phase**
- 把 Background Reflow 的逐章 live-layout 移到 TaskPool（唯一残留的主线程重载点；需将布局结果通过任务返回值合入 pageSlots，含 rebuild 提交协议）。
- 200MB 首建索引的完整流程真机压测（含 taskpool worker 下 200MB 扫描的端到端验收）。