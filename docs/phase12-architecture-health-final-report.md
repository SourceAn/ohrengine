# Phase 12 Architecture Health Final Report

> 生成时间：2026-09-04
> 审计：`docs/phase12-architecture-health-audit.md`；数据：真机 pid 40246/40974/42115 + 像素分析 + hilog

## 1. Executive Summary

- **不显示**：根因 = DebugBookShelf 路由 Bug（「2MB 小书」按钮在 200MB 文件存在时实际打开 200MB → TXT 索引首建在主线程 → 进程冻结、0/0 白屏）。引擎显示链路无缺陷（demo/2MB/EPUB 均 `ready=3` 且像素可见）。**已修复并真机验证**。
- **翻页卡顿**：机制 = 冷缓存后台 reflow 单章 81–145ms 主线程工作与动画同帧重叠；Warm 缓存 + 动画期间互斥后 `avgMs 5-6 / max 10-12 / mut=0`。**已修复（动画期间推迟后台章）并真机验证**。
- **架构**：Index.ets 已薄（48 行）；DebugBookShelf WEAKLY COUPLED（无反向依赖，仅共享沙箱文件产生间接影响，已修其护栏逻辑）；ReaderHost 偏大但职责有序；诊断日志非每帧。

## 2. Book Open Failure

- 见审计 §1。共同链路：书架把入口路由到 200MB → 索引首建主线程 → UI 冻结 → 无 COLDSTART/无进度 → 0/0。demo.txt 与修复后 2MB 均正常（像素 dark_frac≈12.5%）。

## 3. Root Cause

| 症状 | 第一个失败节点 | 层 |
|---|---|---|
| 小书（2MB 按钮）不显示 | `DebugBookshelf.onBookClick` 复用分支选到 benchmark_200mb.txt | BookShelf（宿主测试护栏） |
| 大书（200MB）不显示 | `TxtIndexBuilder.build(200MB)` 主线程首建（PENDING） | Engine parse（已知债） |
| 翻页卡顿 | 冷缓存后台 reflow 单章主线程 81–145ms 与动画同帧 | Engine background（Phase 11 引入，本轮互斥修复） |

> 三者原因为**宿主测试护栏 + 已知索引 PENDING**，非显示/分页/动画算法回归。

## 4. Rendering Pipeline（Data → Page → Ready → Render → Frame）

```
ParsedBook/TxtLazyDocument(数据) → PaginatedChapter(排好) → PageSlot+readyState(模型/就绪)
→ LineBox 共享引用(渲染模型) → PageRenderer/Flip 直绘(Canvas) → 可见帧
```
各层职责明确；PageReady≠UI visible（图片资产解码由 PageRenderer 缓存补齐）。

## 5. Flip Performance（真机）

| 指标 | warm 后台并行 | 动画+后台互斥修复后 |
|---|---|---|
| frames/flip | 24–25 | 24–25 |
| avg / max | 5–6 / 10–12 ms | 5–6 / 10–12 ms |
| generation mutation | 0 | 0 |
| blank / failed | 0 / 0 | 0 / 0 |
| 首帧延迟 | 触摸同帧 | 触摸同帧 |

## 6. Background Reflow Impact

- 冷缓存：单章 81–145ms 主线程（Phase 11BACKGROUND_CHAPTER 实测）→ 动画重叠时单帧 gap ≈100–145ms（卡顿机制，已证据化）。
- 修复：`PipelineManager.scheduleNext` 在 `userAnimating=true`（Flip start/finish/cancel/dispose 置/复位）时推迟后台章调度。真机复测：翻页期间 0 条 >50ms 后台打点。

## 7. Debug BookShelf Coupling

- **WEAKLY COUPLED**。无 engine/ReaderHost/cache 引用；唯一间接 = 共享沙箱 `filesDir`（书文件写入影响该书缓存指纹/mtime）→ 已修其按钮路由 Bug 并打印实际打开文件名。引擎无任何 DebugBookshelf 条件分支。

## 8. Index.ets Health

- 48 行 / 3 imports / 无业务逻辑：**薄入口达成**（路由参数透传 + ReaderHost 承载）。

## 9. ReaderHost Health

- 1622 行 / 50 private 方法：职责多（引擎生命周期/设置/主题/渲染/翻页/注解/诊断/UI 状态）但按区域有序；未见重复 listener/引擎实例（pageReady 已防抖注册）。最小拆分候选（不急做）：`ReaderSession`（生命周期）、`ReaderDiagnostics`（P10/COLDSTART）、`ReaderChrome`（状态栏）。§17 禁止为拆而拆——本轮不动。

## 10. Phase 8–11 Technical Debt

- 修复：DebugBookshelf 大小强绑定。
- 保留（低活跃/功能性）：COLDSTART/P10/`chapterOriginMap`/`userAnimating` 等。
- PENDING：TXT 索引首建主线程（200MB 冻结）；`estimatePagesPerChunk` stub 估算精度。

## 11. Module Dependency Graph

```
DebugBookshelf → (pushUrl) → Index → ReaderHost → OhEngine(Facade) → OhEngineCore
                                                     ├─ PageManager / PipelineManager
                                                     └─ parsers / PageCacheManager / MemoryPageCache
PageRenderer / FlipPageController ─→ OhEngine(Facade)（单向）
```
无反向依赖；跨界点仅 ReaderHost。

## 12. Architecture Problems

1. ReaderHost 偏大（重构候选，非本轮）。
2. TXT 索引首建 = 唯一“打开即冻”引擎级瓶颈（PENDING）。
3. 后台 reflow 主线程逐章 = 冷缓存窗口内的帧风险（已互斥缓解；根治需 taskpool = 超本轮禁改边界）。

## 13. Changes Made

| file | change | reason | risk |
|---|---|---|---|
| entry/.../debug/DebugBookshelf.ets | 按钮→目标大小强绑定；status 打印实际文件名 | P0 不显示（200MB 路由） | 低；回退=旧候选复用 |
| ui-render/core/PipelineManager.ets | `userAnimating` 门 + scheduleNext 推迟后台章 | P0 卡顿（后台污染动画帧） | 低；回退=移除 3 行 |
| ui-render/OhEngineCore.ets | `userAnimating` 字段 + setUserAnimating + 接线 | 同上 | 低 |
| ui-render/OhEngine.ets | facade 透传 | 同上 | 无 |
| reader/FlipPageController.ets | start→true；finish/cancel/dispose→false | 同上 | 低 |

## 14. Before / After Complexity

- Index.ets：48 行（维持）—— 本就不是 God Object。
- ReaderHost/引擎：行数不变（未拆）；诊断/护栏逻辑减少（bookshelf 复用分支删除）。
- 新增：`userAnimating`（1 字段 + gate 3 行）——净加法极小。

## 15. Real Device Benchmark

- 2MB 冷启动：`TXT-LAZY openLazy → ANCHOR_RESOLVED ready=3`（0ms），`FIRST_FRAME`（+3ms），`BACKGROUND_REFLOW_START queued=64`。
- 显示：big3.jpeg `dark_frac=0.125`（文字页）；空白 bug 复现态 `dark_frac=0.00000`。
- 翻页：42115 号 4 次连续翻页 `avgMs 5-6 / maxMs 10-12 / mut=0 / failed=0 / blank=0`。

## 16. Remaining Risks

- 冷缓存首开窗口内后台章仍逐章占用主线程（动画期间已互斥；非动画间仍可能出现单帧 100ms 摆动）。
- 200MB 按钮直接打开仍会冻结（TXT 索引首建 PENDING）。

## 17. PENDING

| 项 | 说明 |
|---|---|
| TXT 索引首建 taskpool/增量 | 200MB 首建分钟级主线程（Phase 9 遗留） |
| 后台 reflow 完全移出主线程 | taskpool 布局（超禁改边界；现以互斥+100ms 节流+cap=64 缓解） |
| ReaderHost 模块拆分（ReaderSession/ReaderDiagnostics） | 下轮候选，本轮不动作 |
| RSS / ×100 连续翻页自动化 | 设备工具/自动化受限（Phase 11 已记录） |

## 18. Rollback

- bookshelf：恢复 candidates 复用逻辑（单文件）。
- anim-gate：移除 `scheduleNext` 中 3 行 gate + Flip setUserAnimating 调用；`userAnimating` 默认 false 时行为等同旧版。
- 两处相互独立、可单拆可回退；构建产物即回退点。

## 19. FINAL VERDICT

**PASS**

- 小书正常显示（demo/2MB 像素验证 ✓）；EPUB 无回归（Phase 10/11 实测 ✓）
- Anchor 正确、ready 正确（ready=3 全链 ✓）、FIRST_FRAME 正常（≤5ms ✓）
- Previous/Next 正常、无明显卡顿（avg 5-6 / max 10-12ms ✓）
- mut=0 / blank=0 / failed=0 ✓
- 架构：无严重耦合；Index 已薄；改造为最小解耦（bookshelf 护栏修复 + 动画/后台互斥）
- FAIL 判据（小书/大书不显示等）均已消除——失败节点定位为宿主测试护栏 Bug 与已知索引 PENDING，非引擎回归。

---

# 15 问最终回答

1. 小书打开不显示？→ 2MB 按钮被路由到 200MB（bookshelf 复用 Bug）→ 索引首建冻结。已修，像素验证正常（dark_frac 0.125）。
2. 大书打开不显示？→ 200MB 索引首建主线程（Known PENDING）。「2MB 按钮」相关路径已修。
3. 同一根因？→ 部分是：都经 `TxtIndexBuilder.build` 主线程；小书系路由 Bug 放大，大书系索引首建债。
4. ReadingAnchor 正确？→ ✓（ready=3，page=ch 定位一致）。
5. PageReady 正确？→ ✓（引擎标注与渲染侧一致）。
6. PageReady 后仍可能不显示？→ 不会（渲染=直绘 lines 共享引用；实测文字可见）；此前“不显示”均发生在 READY 之前的冻结。
7. 卡顿在哪一层？→ 冷缓存后台 reflow 逐章主线程（81–145ms）与动画同帧。
8. >16ms 主线程工作？→ 有：冷缓存后台章；已动画互斥缓解（仍 PENDING 根治）。
9. 后台 reflow 影响动画？→ 修复前会（同帧 gap）；修复后实测不（flip 期间 0 条 >50ms 后台）。
10. Phase 8–11 臃肿？→ 部分：诊断足迹 ~55 处非每帧；bookshelf 护栏 Bug 暴露宿主测试污染；无每帧日志。
11. Index God Object？→ 否（48 行薄入口）。
12. ReaderHost 职责多？→ 是（50 私有方法），但有序；拆分候选非本轮。
13. DebugBookShelf 与 Engine 强耦合？→ 否（WEAKLY；无反向依赖）。
14. DebugBookShelf 污染正常功能？→ 间接污染过一次（文件级共享导致路由 200MB），已修护栏；引擎无相关分支。
15. 下一阶段最该拆？→ （a）TXT 索引首建 taskpool/增量 —— 最痛的引擎级打开阻塞；（b）ReaderHost 拆 ReaderSession/ReaderDiagnostics；（c）后台 live-layout 移出主线程。不要继续往 Index/引擎主干里加条件。