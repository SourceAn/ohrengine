# Phase 6 报告：后台任务与缓存基础设施

> 依据《06-Phase6-Scheduler-State-Quota-Index.md》完成。Phase 0 Decision Table：
> TaskScheduler/BookLayoutState → MERGE PipelineManager；DiskCacheQuotaManager →
> NEW（common）；CacheIndex → SKIP。

## 1. Task Scheduler（MERGE→ PipelineManager）

- **优先级模型**：新增 `LayoutPriority`（P0_VISIBLE/P1_NEXT/P2_PREVIOUS/P3_CACHE_WRITE/
  P4_BACKGROUND）。`queueChunkLayout(index, priority)` 兼容数字优先级与既有 'high'/'low'
  字符串；high（P0–P2）unshift 插头，low（P3/P4）push 尾。
- **Worker 上限**：沿用单线程 setTimeout 队列（Layout=1 语义），不引入新 Worker（Phase 0
  确认全工程 0 Worker；spec 允许布局单个并发）。
- **Debounce/Cancel**：既有 `layoutEpoch` 代数 + `destroyed` 标记；Phase 6 新增
  `CancellationToken`（协作式，任务边界检查）。

## 2. Cancellation（新增 CancellationToken）

| 点 | 覆盖 |
|---|---|
| `scheduleNext()` | token cancelled → 丢弃新任务 |
| `processNextInQueue()` | 入口检查 |
| `layoutRangeSync` / `layoutAllChaptersSync` | 逐章循环边界检查 |
| `shutdown()/clearAll()` | cancel + epoch 作废 |

约束落实：CancellationToken 仅做任务边界协作检查，不插入 Knuth-Plass/分页算法内部
（算法段短促，且 spec 禁止修改算法语义）。

## 3. BookLayoutState（MERGE→ PipelineManager）

已有 `layoutEpoch/isProcessing/destroyed` + `EngineState` 表达布局任务生命周期，
未新建状态机。概念状态 ↔ 现有映射：
- IDLE → `layoutQueue.length===0 && !isProcessing`
- LOADING_ANCHOR → `restoreReadingState` 执行中
- LAYOUTING_VISIBLE → `layoutRangeSync`/`ensureChapterReady`
- PREFETCHING → `queueChunkLayout(P4)` 后台队列
- CHANGING_LAYOUT → `reflowAllChapters`/字体变更（bump epoch）
- ERROR → `EngineState.ERROR`

## 4. Disk Quota（NEW: DiskCacheQuotaManager, common）

- 全局配额：默认 512MB，`enforceGlobalQuota(baseDir)` 遍历 `cache/books`、
  `reading_state` 根目录，超配按 LRU（access 升序）淘汰"可重建缓存"目录。
- 单书配额：默认 128MB，`enforceBookQuota(dir)` 超限即整书缓存淘汰。
- 不删源书；失败静默。
- 接线：`ReaderHost.resolveBookSource` 每次打开书籍前 `enforceGlobalQuota(filesDir)`。

## 5. CacheIndex（SKIP）

meta.json 已是 per-book 的粗粒度索引（version/fingerprint/layoutSignature/
bookId/contentFingerprint/schema/layoutAlgorithmVersion）；CacheIndex 用于 startup
lookup/size/quota 时才需要。目前 startup 只需 stat meta + 逐章文件验证（`loadChapter`
已优先），故**不加独立 CacheIndex**；损坏可 lazy 重建，不触发整书重建（Phase 7 落实）。

## 6. 写入（P0 不等待）

- Critical state（ReadingState）：`ReadingStateStore.save` 原子替换（tmp+rename）。
- 可重建缓存（L2/L3）：安全原子替换，不强制每次 fsync。
- P0（可见页导航）与 CacheWriter/Quota/prefetch 解耦：翻页不等待写盘（页面渲染在
  layoutRangeSync/ensureChapterReady 内完成；写盘在 processNextInQueue 或独立调用）。

## 7. 修改文件

| 文件 | 变更 |
|---|---|
| `ohrengine-common/.../service/DiskCacheQuotaManager.ets` | 新增 |
| `ohrengine-common/.../service/CancellationToken.ets` | 新增 |
| `ohrengine-common/index.ets` | 导出以上 |
| `ohrengine-ui-render/.../core/PipelineManager.ets` | LayoutPriority 枚举；queueChunkLayout 支持优先级；CancellationToken 贯穿 schedule/process/sync-loops/shutdown/clearAll |
| `ohrengine-ui-render/index.ets` | 导出 LayoutPriority |
| `ohrengine-ui-render/.../OhEngineCore.ets` | open() 重置 token |
| `ohrengine-reader/.../ReaderHost.ets` | open 前执行全局配额 |

## 8. 测试与验证

- compile：BUILD SUCCESSFUL；ohosTest 编译通过（未新增 Phase 6 专项用例——
  Quota/Cancel 为纯 IO/线程模型，兼容既有 runner）。
- 真机运行验证待 Phase 7 一并做（配额/取消不改变功能正确性路径）。

## 9. 风险

1. Quota LRU 依赖 atime 可靠性（模拟器 filesystem 可能不更新 atime），已退化用
   mtime + size 排序兜底。
2. CancellationToken 覆盖任务边界而非算法内部——长章单次 layout 不可中断，但
   P0 不等待该类后台任务本身（单章 layout 短促）。
3. 全局配额 512MB / 单书 128MB 为首次估值，需按 library scale 真机校准。

## 10. 下一步

Phase 7：Migration + ImportCheckpoint + Cleanup + 最终验收（cache ON/OFF 一致性、
memory pressure、200MB+ EPUB、DoD 清单）。