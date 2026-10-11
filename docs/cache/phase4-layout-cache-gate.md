# Phase 4 报告：LayoutCache — SKIP（Optimization Gate）

> 依据《04-Phase4-LayoutCache.md》：**仅当 profiling 证明仍有明显 layout
> bottleneck 时执行**；"不要为了架构完整而实现"；收益不明显允许删除/简化。

## Gate 决策：SKIP

### 架构证据
1. **L2 分页缓存已等价于布局结果缓存**：`chapter_{i}.json` 持久化每一章的
   `PaginatedChapter`——即最终 LineBox（layout 输出）。layout 后文本行与
   分页结果全部在 L2，重复 layout 已被热窗命中短路。
2. **L3 进一步消除重复反序列化**（Phase 3）：内存 LRU 命中连磁盘读都不需要。
3. **Type A（Measurement Cache）价值≈0**：本引擎 TextBreaker 是**确定性估算**（CJK/
   全角/标点=1em，半角=0.55em），不使用 OS MeasureText；没有"测量结果"需要缓存，
   也无须 `textEngineVersion`（无引擎测量 API）。Phase 0 已指出该点。
4. **Type B（Paragraph Layout）与 L2 重复**：L2 存的正是逐行 LineBox；再建
   段落级 lines 缓存属重复存储，违反"能合并就合并"。
5. 现有路径在 Phase 2/3 后：**热窗 cache-first → L3 → L2 → layout** 已有完整
   hit 链路，layout 只发生在真正未缓存章节。

### 观测（spec §Observability 已落地）
- `PipelineManager.getCacheHitSummary()`：L3/L2/L2miss/liveLayout 计数 + 命中率。
- `statsLayoutMs`：layout 累计耗时采样。
- `OhEngineCore.logCacheHitSummary(tag)`：open/destroy 打点。

### 运行时采样说明
真机场景（demo.txt 5 页）翻页期间 hit rate 由 debug 日志携带；因 device log
缓冲轮换，无法在会话后提取精确数值。**无 layout-hotspot 的业务证据**（正常阅读
流程未出现明显重排卡顿）。若未来出现（如大章首分页耗时），再按 Phase 4 设计补
Type B。

## 结论
- **不实现 LayoutCache**；保留 Observability 基础设施供后续 profiling 复用。
- 持续推进 Phase 5 → 6。若 Phase 5 也无资产瓶颈证据则一并 SKIP。