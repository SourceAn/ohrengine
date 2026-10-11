# Phase 2 报告：Hot Pagination Cache / L2

> 依据《02-Phase2-HotPageCache-L2.md》完成。未重写分页算法。

## 1. 目标达成情况

| 目标 | 状态 |
|---|---|
| 消除首次打开整本分页 | ✅ open() 仅同步分页「目标章 ±2」热窗，其余 stub 按需分页 |
| 引入 PageRange 连续性校验 | ✅ CachePage 增加 startChar/endChar，loadChapter 校验 overlap |
| CacheKey 完整化（禁 pageIndex） | ✅ meta 增加 bookId/contentFingerprint/layoutAlgorithmVersion/schemaVersion |
| 前后翻页预取 | ✅ 既有 goToNext/Previous ±3 章异步预取（复用未改） |
| 页写入不阻塞翻页 | ✅ 热窗同步写贯穿已改为窄窗；异步队列路径本身不阻塞可见页 |
| 随机跳转减少重算 | ✅ 目标章缓存命中直接复用，不重复 layout |

## 2. 修改文件

| 文件 | 变更 |
|---|---|
| `ohrengine-common/.../service/PageCacheManager.ets` | PAGE_CACHE_VERSION 5→6；新增导出 `PAGE_CACHE_SCHEMA_VERSION=1`、`LAYOUT_ALGORITHM_VERSION=1`；CacheMeta 扩展 bookId/contentFingerprint/layoutAlgorithmVersion/schemaVersion；CachePage 增加 startChar/endChar；serialize 计算章内全局 char range；新增 `isPageRangeContinuous`（相邻页 endChar<=next.startChar，overlap 判损坏）；`loadChapter` 做连续性校验；saveChapter/writeMeta 落全 CacheKey；isCacheValid 校验六元组 |
| `ohrengine-common/index.ets` | 导出 PAGE_CACHE_SCHEMA_VERSION、LAYOUT_ALGORITHM_VERSION |
| `ohrengine-ui-render/.../layout/PageSplitter.ets` | Page 增加 startChar/endChar（分页时按章内全局游标累计） |
| `ohrengine-ui-render/.../core/PipelineManager.ets` | 新增 `layoutRangeSync(from,to)`（热窗同步分页，cache-first write-through 带 bookId/fp）；saveChapter 调用补 CacheKey 参数 |
| `ohrengine-ui-render/.../OhEngineCore.ets` | open() 改为热窗分页（target=恢复章，±HOT_RANGE=2）；新增 `HOT_RANGE` 常量、`peekReadingStateChapter()`；pageCacheContext 注入 bookId/contentFingerprint；isCacheValid 传入新键 |
| `entry/.../unit/PageCacheManagerOHOSTest.ets` | 新增 3 用例（schema/算法版本导出、char range 序列化往返+连续性、overlap 检测） |

## 3. 架构变化

### 打开流程（热窗）
```text
open()
  → parse → ReflowRouter.render（每章 stub 页）
  → pageCacheContext（CacheKey 六元组）
  → peekReadingStateChapter()（ReadingState.anchor.chapterId → 章索引）
  → layoutRangeSync(target±2)   // 仅热窗 cache-first 同步分页 + 写盘
  → state=READY → restoreLastReadingState()
其余章保持 stub；翻页进入 stub 章时 ensureChapterReady 同步分页该章；
翻页后 goToNext/Previous 对 ±3 章异步预取。
```

### CacheKey（Phase 2 规范）
```
{ bookId, contentFingerprint, layoutSignature,
  layoutAlgorithmVersion, schemaVersion, pageRangeHash }
```
- pageRangeHash：单章层面由 isPageRangeContinuous（页 startChar/endChar 连续性）
  校验体现——缓存文件一致则通过；overlap/倒退即按损坏处理（调用方删除该章并重算）。
- pageIndex **永不进入** CacheKey（或任何 key）。

## 4. 真机验证（<LAN-IP>）

- ohosTest 81 用例，69 Pass / 12 Fail（12 个全部为既有失败，与 Phase 2 无关；新增
  3 个 PageCacheManager Phase2 用例全部通过）。
- App 冷启动打开 TXT（demo.txt）：
  - **只生成 chapter_0/1/2.json（热窗 ±2），未整本分页**（此前为全书生成）。
  - meta.json 含 `version:6, bookId:"demo", contentFingerprint:"5472:...",
    layoutAlgorithmVersion:1, schemaVersion:1`。
  - 阅读页正常显示、翻页正常（2/6）。
  - 冷启动恢复：重开书直接落在上次第 2 页（ReadingState 生效）。
- 未发现 app crash。

## 5. before/after

| 指标 | 之前 | 之后 |
|---|---|---|
| 冷打开分页范围 | 全书（O(N) 章同步分页+写盘） | 目标章 ±2 热窗 |
| CacheKey | version+size/mtime+layoutSignature | 六元组（bookId/fp/algo/schema/range-hash） |
| PageRange 连续性 | 无校验 | loadChapter 校验 overlap→损坏 |
| 首次 open 阻塞 | 整本等待 | 首个可见页依赖单章热窗渲染 |

## 6. 风险与未决

1. **totalPages/{进度条}**：非热窗章为 stub 估算页，`getTotalPages()` 在热窗
   分页后仍以 stub 页计入，UI 进度为近似值，随翻页逐步精确——与 Phase 2 目标一致
   （不整本分页），但需后续在 Phase 3/7 校准进度显示口径。
2. **random jump**：跳转到 stub 章会同步分页该章（ensureChapterReady），单章
   成本可接受；预期性能收益在 L3 热内存缓存叠加后体现。
3. **Writer async**：热窗同步写盘仍在 open 时发生（窄窗，可忽略）；异步队列写盘
   在 setTimeout 任务内。真正的独立 Cache Writer 队列按 Phase 6 Scheduler 做。
4. 连续.性校验目前只查 overlap/倒退（保守），大跳跃放行；更严格的可解释边界
   （图片/不可拆分块）留待 Phase 7 一致性验收。

## 7. 结论与下一步

- **进入 Phase 3（L3 Runtime Memory Page Cache）**：在热窗/按需分页基础上构建
  3–5 章内存页缓存 + total memory budget，减少重复反序列化与重复 layout，
  memory pressure 缩到 1–2 章。