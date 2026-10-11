# Phase 5 报告：AssetCache — SKIP（Optimization Gate）

> 依据《05-Phase5-AssetCache.md》：仅当 profiling 明确证明图片、字体或 CSS
> resource 是瓶颈时执行。

## Gate 决策：SKIP

### 架构证据（Phase 0 已核查）
1. **图片**：PageRenderer 已有 `remoteImageCache` + `localImageCache` 双缓存；
   图片解码仍按页序异步预取（`prefetchNextPageImages`）。无整书图片解码或
   未回收 bitmap 的证据。
2. **远程资源**：`RemoteResourceLoader` 已有 64MB 总量 / 128 条目 / 16MB 单响应
   上限 + in-flight 去重 + `RequestCanceller` 取消。网络资源已有严格内存帽。
3. **字体**：`FontLoader` 已有 `pendingLoads`（去重）+ `weightCache`；
   `FontFallbackChain` 有 `FontFallbackCache`。字体文件按需加载，无泄漏证据。
4. **CSS**：`CssImportResolver` 已有 import 去重；`compiledSheet` 全书一份复用。
5. 阅读引擎当前无**解码 Bitmap 无限制常驻**路径（图片页按 `PageSlot` 渲染，
   与页面同生命周期）。

### 运行时
demo.txt / EPUB 阅读会话无图片大量加载、无字体切换瓶颈；未发现资产相关停顿或
内存异常。**无需为"架构完整"新建 ImageManager/FontManager/CSSManager**。

### 若未来需要
- Image：metadata 缓存 + thumbnail LRU + full Bitmap strict budget（预留设计）。
- 优先级低于缓存正确性/配额/调度（Phase 6）与迁移验收（Phase 7）。

## 结论
- **不实现 AssetCache**；现有分散缓存 + 静态 cap 已满足。
- 进入 Phase 6：Scheduler / BookLayoutState / Quota / CacheIndex。