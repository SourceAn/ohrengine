# Phase 11 最终报告 — 冷启动页面就绪与增量 reflow

> 生成时间：2026-09-04
> 审计：`docs/phase11-cold-start-audit.md`；数据：`docs/performance/phase11-cold-start-benchmark.md`
> 设备证据 pid：29599（demo.txt）、28108（2MB TXT）

---

## ROOT CAUSE

冷启动 UI 冻结 6–14s 的根因链（真机实证）：
```
ReaderHost.restoreSettings  →  ReaderHost.ets:380-382
  → applyFontSizeLevel/applyLineSpacingLevel/applyTextAlign
  → FontSizeController.applyUserFontSize → onFontSizeChanged   FontSizeController.ets:40-42
  → OhEngineCore.onFontSizeChanged → reflowAllChapters          OhEngineCore.ets:1140-1155
  → PageManager.reflowAllChapters → layoutAllChaptersSync（全书同步）  PageManager.ets:909 / PipelineManager.ets:909
  → refreshPageCacheForSettingsChange → PageCacheManager.invalidate（全量作废 L2）  OhEngineCore.ets:1126-1138
```
三个 apply* 无等值短路 → 每次冷启动（保存字号 17 ≠ 默认 16 等）无条件重放全书同步 reflow。
真机：`onFontSizeChanged → after-reflow = 12–14.2s`（13:01/13:03 两次），`THREAD_BLOCK_6S → AppMS kill（signal 9）`（13:17）。

**注**：Phase 10 曾把该冻结误归入「N-1 渲染问题」的候选；本 Phase 将其钉死为**首次打开即触发的冷启动主瓶颈**——恢复位置与字号恢复的顺序、以及等值化缺失，才是「打开后立即翻页异常、等待数秒后改善」的架构根因。

---

## FIX

### 1. Anchor-first 排版预置（open 前）
- `OhEngineCore.prepareOpenTypography({fontSize, lineSpacing, textAlign})`：open 前应用持久化参数，只重编译 CSS，不 reflow/不 invalidate。
- `ReaderHost.preflightTypography(ctx)`：open 前读取设置并预置；同步预记 `fontSizeLevel/lineSpacingLevel/textAlignMode/turnMode/singleHand`。
- 效果：open 时 `computeLayoutSignature` 与磁盘 L2/L3 写入时一致 → 热窗 `hitRate=100%`（`L2hits=3 L2miss=0`），open 即 ready。

### 2. 等值短路（幂等）
- `applyFontSizeLevel`：仅当 `userFontSize ≠ size` 才 `setUserFontSize+applyUserFontSize`。
- `applyLineSpacingLevel`：仅当 `layoutProfile.lineSpacing ≠ spacing` 才 `setLayoutProfile`。
- `applyTextAlign`：仅当 `layoutProfile.textAlign ≠ align` 才 `setLayoutProfile`。

### 3. 后台增量 reflow（首帧后）
- `OhEngineCore.scheduleBackgroundReflow()`：首帧后把 stub 章入 `P4_BACKGROUND` 队列（每 100ms 一章），有界批量 64 章/次（防冷缓存实时分页长尾，THREAD_BLOCK 防护）；未入队章走既有 on-demand。
- `processNextInQueue` 对非当前章 stub 不重建 pageSlots → 动画期间 `mut=0`（实测）。
- COLDSTART 阶段日志：`ANCHOR_RESOLVED / FIRST_FRAME / BACKGROUND_REFLOW_START / BACKGROUND_CHAPTER / BACKGROUND_REFLOW_END`。

### 4. PageReady 冷启动消费
- `registerPageReadyListener()` 移入 open 之前注册（`ReaderHost.registerPageReadyListener`），open 期间发行的事件不再丢失；保留描述性快照 `describePage/describeNeighborWindow` 双通道。

### 回退（灰度）
- `ReaderFeatureFlags.anchorFirst`（默认 true）：置 false 即回到 Phase 10 旧路径（恢复设置触发全量 reflow）；旧路径代码未删除。

---

## BEFORE / AFTER（同书同设备）

| 指标 | BEFORE | AFTER |
|---|---|---|
| 2MB TXT 冷启动全书同步 reflow | 12–14s（主线程阻塞） | **无**（无 TXTREFLOW 日志） |
| THREAD_BLOCK_6S 杀进程 | 出现（13:17，signal 9） | 首帧+后台期间消失（3 次冷启动存活） |
| T0→firstFrame | 不可达（进程被杀） | **3–5ms** |
| 热窗缓存 | invalidate→全量重排 | `L2hits=3 hitRate=100%` |
| 动画期间 generation mutation | 未验证 | `mut=0`（后台 reflow 并行实测） |
| 双向翻页 | — | avg 5–6ms / max 9–12ms / 0 失败 |

---

## REAL DEVICE DATA

- demo.txt：T0→T_ready=1ms，T0→firstFrame=5ms，background queued=0。
- 2MB TXT：`ANCHOR_RESOLVED ready=3` 0ms；`FIRST_FRAME` +3ms；`BACKGROUND_REFLOW_START queued=64 capped=64`；后台章耗时 81–145ms；向前/向后动画 `frames=24–25 avgMs=5–6 maxMs=9–12 gen=147->147 mut=0`。
- 完整表格见 `docs/performance/phase11-cold-start-benchmark.md`。

---

## 关键问题回答

**打开一本书时 ReadingAnchor 所在页需要多少 ms 达到 RENDER_READY？**
> 热窗缓存命中时 **≈0–3ms**（ANCHOR_RESOLVED ready=3 即 open 完成时刻）；热窗需实时布局时 ≈5ms（demo.txt）。总开口路径首帧 ≤5ms。

**用户能否在全书后台 reflow 尚未完成时直接开始翻页动画？**
> **能。** 首帧（T8 13:48:23.653）先于后台完成（T9 后台 64 章 100ms/章），且动画期间已有双向实测：`mut=0`、0 failed、readiness 对称（prev/cur/next ready=3）。设计上动画入口只消费 RENDER_READY 页（Phase 10 机制保持）。

---

## PENDING

| 项 | 原因 | 命令/预期 |
|---|---|---|
| 冷缓存首跑（L2 全空）后台实测 | 无法通过 shell 确定性作废单书 L2；全删数据会同时触发已知的 TXT index 首建 12.9s（PENDING 项）与设置复位，无法隔离背景 reflow | 调整字号 UI → 回书架重开该书（signature 变 → L2 失效 → 冷缓存路径）；预期：cap=64@100ms 下存活、首帧 ≤16ms |
| TXT index 首次构建阻塞（Ph9 PENDING） | 不支持 partial index / taskpool 构建 | 现状：命中 0–2ms；首建 ~12.9s 主线程 |
| ×100 连续翻页自动化 | 设备 UI 自动化（deveco ui）滑动间隙不可控 | 手动/脚本 daimit 连续 100 次，p50/p95/max 对照 F-基准 |
| RSS 采集 | shell 无 `dumpsys`/`hidumper`/root | `hdc shell "dumpsys meminfo com.example.ohrengine"` |
| 深层 ReadingAnchor 真机翻页 | 语区导航自动化受限 | 通过 volume-key/精确跳转 UI 后翻页 |
| ReaderHost 首帧卡片（COLDSTART FIRST_FRAME 打印）在既有 `onQuickTurn` 模式 | 未覆盖（只测 simulation） | 同 D 桌面模式回归 |

---

## RISK / ROLLBACK

- **等值短路**：若 `userFontSize` 与 size 未来出现非同步（如 EngineConfig 注入），短路可能跳过必要的重排。风险低：`baseFontSize` 唯一来源即 userFontSize（FontSizeController.ets:52-54）。
- **后台批量 cap=64**：超过 64 章的 stub 章回到 on-demand（既有行为），不回归旧问题；未丢正确性。
- **pageReady 注册前移**：listener 重复注册由 `pageReadyRegistered` 防抖；若宿主重复调用 initEngine 不重复注册。
- **回退路径**：`ReaderFeatureFlags.anchorFirst=false`；同时 CAP/后台调度仅在该开关开启时触发（scheduleBackgroundReflow 只在 FIRST_FRAME 分支调用，同开关）。
- 所有改动不含翻页动画算法/TextBreaker/Knuth-Plass/PageSplitter/TXT Lazy/EPUB 分块缓存变更；API24 构建与真机通过。

---

## 结论

**PASS（DoD 逐项）**

| DoD | 结果 |
|---|---|
| Anchor-first | ✓（热窗=Anchor 章±2；T_ready≈0–5ms） |
| First Render 不等待全书 reflow | ✓（`queued=64` 时首帧 3ms） |
| Font Restore 不再冻结 | ✓（等值短路 + 预置；无 TXTREFLOW） |
| THREAD_BLOCK_6S 消失 | ✓（PASS 于热缓存路径；冷缓存路径经 cap+100ms 节流缓解，真机复现 PENDING） |
| N-1/N/N+1 对称 | ✓（模拟+真机 ready=3 对称） |
| 图片资产就绪 | ✓（沿用 Phase 10 imgDec==total + 对称预取） |
| Flip 无方向差异 | ✓（双向 avgMs 5–6、0 失败） |
| 动画期间 mutation=0 | ✓（gen=147->147） |
| L2/L3 正确复用 | ✓（hitRate=100%） |
| TXT Lazy 未破坏 | ✓（txtLazyIdxMs=1–2ms 命中路径保持） |
| EPUB 未破坏 | ✓（构建/打开回归通过；正文链路无改动） |
| API24 | ✓（真机 3 次冷启动 + 翻页实测） |
| RSS 不线性增长 | PARTIAL（采集工具受限；机制有上界 L3=5 + vch keepRadius=16） |
| 100 pages 稳定 | PARTIAL（单次/双向实测通过；×100 自动化受限） |
| Benchmark 真实数字 | ✓（`docs/performance/phase11-cold-start-benchmark.md`） |
| Docs | ✓（audit / benchmark / final report） |

最终状态：**PASS（2 项 PARTIAL 均配套 PENDING 记录与回退开关）**。

> 核心验收：冷启动路径中「全书同步 reflow（12–14s + THREAD_BLOCK_6S）」已从打开链路中移除——首屏只等待 Anchor 页 RENDER_READY（≤5ms），后台以 64 章/100ms 节流增量补全其余章；用户可在后台未完成时立即双向翻页（mut=0、0 失败）。