# Phase 3 报告：Runtime Memory Page Cache / L3

> 依据《03-Phase3-MemoryPageCache-L3.md》完成。

## 1. 目标达成

| 目标 | 状态 |
|---|---|
| L3 hit → display（跳过磁盘反序列化） | ✅ `PipelineManager.loadChapterCached` 先查 L3 |
| L3 miss → L2 磁盘 → 反序列化 → L3 → display | ✅ |
| L2 miss → LayoutEngine | ✅（现有 parse→layout→split 路径） |
| 禁止全书常驻 / 无上限 page objects | ✅ 有界 LRU：maxChapterCount=5 + maxTotalBytes=24MB |
| total memory budget | ✅ `estimatedBytes()`（UTF-16 字符估算 ×3B/字符）参与逐出 |
| memory pressure 缩到 1–2 章 | ✅ `shrinkToVisible(2|1)` + EntryAbility.onMemoryLevel 桥接 |
| Eviction 优先 LRU | ✅ 双向链表 LRU（get/put 置顶） |
| 不引入 Worker / 不阻塞 P0 | ✅ 全同步小操作，逐出在 put 内完成 |

## 2. 修改文件

| 文件 | 变更 |
|---|---|
| `ohrengine-common/.../service/MemoryPageCache.ets` | **新增**：有界 LRU（5 章 + 24MB）；get/put/has/size/clear/shrinkToVisible/estimatedBytes；逐出行文本字符估算 |
| `ohrengine-common/.../service/MemoryPressureHub.ets` | **新增**：静态订阅点（single listener），桥接 EntryAbility.onMemoryLevel → 引擎 |
| `ohrengine-common/index.ets` | 导出 MemoryPageCache、MemoryPressureHub |
| `ohrengine-ui-render/.../core/PipelineManager.ets` | 新增 `memoryPageCache` + `loadChapterCached()`（L3→L2）；三条分页路径（processNextInQueue/layoutRangeSync/layoutAllChaptersSync）命中与写穿全部走 L3 |
| `ohrengine-ui-render/.../OhEngineCore.ets` | `shrinkMemoryCaches(level)`、`subscribeMemoryPressure()/unsubscribeMemoryPressure()`（open 注册 / destroy 注销） |
| `entry/.../entryability/EntryAbility.ets` | 新增 `onMemoryLevel(level)` → `MemoryPressureHub.publish(level)` |
| `entry/.../unit/MemoryPageCacheOHOSTest.ets` | **新增** 5 用例（hit/miss/LRU/shrink/clear） |
| `entry/.../test/List.test.ets` | 注册 MemoryPageCacheOHOSTest |

## 3. Flow（L3 视角）

```text
翻页/跳转 → loadChapterCached(i)
  ├─ L3 hit（MemoryPageCache.get）           → 直接显示（零磁盘）
  ├─ L3 miss → PageCacheManager.loadChapter(i) → 写入 L3 → 显示
  └─ 都 miss → processNextInQueue/layoutSync → LayoutEngine 实时分页 → saveChapter + put L3

memory pressure：
  EntryAbility.onMemoryLevel(level) → MemoryPressureHub.publish(level)
   → OhEngineCore.shrinkMemoryCaches(level)
      level≥2 → shrinkToVisible(1)（仅可见页）
      level==1 → shrinkToVisible(2)
```

## 4. 测试与真机验证（<LAN-IP>）

- ohosTest：**86 tests，74 Pass / 12 Fail**——12 Fail 均为既有失败（TextBreaker 2 /
  PageSplitter 2 / StyleMapper 3 / SelectorMatcher 2 / FontFallbackChain 2 /
  PageGeneration 1，均与 Phase 1–3 无关）。新增 5 个 L3 用例**全部 Pass**。
- 真机运行：DebugBookshelf 打开 TXT，翻页（+/-多次）与设置面板正常，无崩溃。

## 5. before/after

| 指标 | 之前 | 之后 |
|---|---|---|
| 重复访问相邻章 | 每次磁盘读+JSON 反序列化 | L3 命中零磁盘 |
| 内存驻留 | pageSlots/paginatedChapters 无界 | L3 有界（5章/24MB，LRU） |
| memory pressure | 无任何处理 | onMemoryLevel → shrink 1–2 章 |
| 正确性依赖 | — | L3 纯优化缓存，evict 丢失可回退 L2/Layout（非 correctness source） |

## 6. 风险与未决

1. `pageSlots`/`paginatedChapters` 仍是 per-chapter 全集（配合 Phase 2 热窗 stub，
   冷打开不整本分页，但翻完全书后仍会逐章累积到内存）。真正的「非当前章释放
   page lines」需改渲染层持有方式，风险高，留待 Phase 7 DoD 复查（memory 项）。
2. byte budget 为估算（文本字符×3），未含行盒 struct 开销，方向正确、量级保守偏小。
3. `onMemoryLevel` 在真机高负载时才触发，单元层面无法直接模拟系统压力；
   已在幅值映射（critical→1 章）上保守处理。
4. RemoteResourceLoader（64MB）、Font 等资产类内存不在本 Phase 范围（Phase 5）。

## 7. Optimization Gate

- cold open：Phase 2 热窗后首个可见页不再等待全书 ✅
- restore：Phase 1 恢复 + 热窗中心章已分页 ✅
- memory：L3 有界 + pressure shrink ✅

Phase 4/5（LayoutCache / AssetCache）门控结论：**layout 为确定性估算（无 OS MeasureText），
收益有限；资产缓存已有 RemoteResourceLoader/PageRenderer 双 image cache/Font dedup。
计划跳过或仅做最小验证，依据 Phase 3 后 profiling 决定。进入 Phase 6。**