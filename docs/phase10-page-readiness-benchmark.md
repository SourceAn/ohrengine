# Phase 10 — Page Readiness Benchmark（真机实测）

> 生成时间：2026-09-04
> 设备：HUAWEI Mate 70 Pro+（PLA-AL10），API24，`hdc tconn <LAN-IP>`
> 采集方式：hilog buffer 快照（`hilog -x` → grep），时间戳 = 设备毫秒；tag `OhEngine` / `OhEngine-Flip` / `OhEngine-Reader`
> 数据来源代码：`OhEngineCore.describePage` / `describeNeighborWindow`，`FlipPageController.logReadyCheck / finishFlip`，`ReaderHost.logPageTurnSnapshot`

## 就绪状态编码（ready=x）

| 值 | 状态 | 含义 |
|---|---|---|
| 0 | NOT_READY | stub / 无数据 |
| 1 | DATA_READY | 数据就绪（vch/chunk 可读） |
| 2 | LAYOUT_READY | 分页/行盒稳定（含图页在图片解码前停在此态） |
| 3 | RENDER_READY | 文本页直接达到；图片页在 imgDec=total 后达到 |

---

## A — Resume Page Ready（打开→Resume Page 就绪）

### 小型 TXT（demo.txt，5472 B，3 vch，155 页文本实测 5 页）
`13:30:04.939` T0 open 请求（openLazy 进入）
`13:30:04.939` T1 ReadingAnchor 所在章解析 + TXT 索引就绪 `txtLazyIdxMs=0`（索引缓存命中）
`13:30:04.972` T2/T3 数据+布局就绪 `CacheStats[open] L2miss=3 liveLayout=0 openMs=0`（热窗 5 章全部缓存命中）
`13:30:05.001` 恢复字号应用 onFontSizeChanged → 全书 reflow 开始
`13:30:05.004` after-reflow totalPages=5（reflow 3ms，小书无压力）

```
T0 → T4（resume render ready）≈ 65 ms
T0 → T5（首帧 renderPage）   ≈ 70 ms
```

### 中型 TXT（benchmark_2mb.txt，2MB，146 vch，1307 页）
`T0→T1`：`txtLazyIdxMs=0..1 ms`（磁盘索引命中；首次构建 2260 ms）
`T1→T3`：热窗 5 章缓存/实时分页 `openMs=0`
`T3→reflow`：`onFontSizeChanged base=17` 触发**全书同步 reflow**
实测 onFontSizeChanged → after-reflow 间隔：**12–14 s（主线程阻塞）**：
  13:03:06.867 → 13:03:20.995（14.1s）
  13:01:02.312 → 13:01:16.526（14.2s）
  13:17:29.523 → **无 after-reflow**：13:17:40.548 AppMS `faultData … THREAD_BLOCK_6S` → 进程被杀（pid 4812，signal 9）

```
T0 → T4 2MB 冷启动 = PENDING（进程被 THREAD_BLOCK_6S 终止，T4 不可达）
```

**结论 A**：Resume Page First 在小书成立（65ms）；2MB 冷启动被「字号恢复触发的全书同步 reflow」冻结墙阻断（独立性能瓶颈，§13 → PENDING）。

---

## B — Bidirectional Readiness（N-1/N/N+1 同时刻就绪）

### 小型 TXT（demo.txt，文本页 img=0）
```
P10 flipTurned mode=simulation curN=1
  prev=g=0  ch=0  state=ready ready=3 lines=23 tH=1ba2d445 img=0 src=L3 gen=10
  cur =g=1  ch=1  state=ready ready=3 lines=28 tH=63282f4  img=0 src=L3 gen=10
  next=g=2  ch=1  state=ready ready=3 lines=10 tH=c1674724 img=0 src=L3 gen=10
```

| Page | Data | Layout | Render | Cache | Ready Time |
|---|---|---|---|---|---|
| N-1 (g=0) | ✓ | ✓ | ✓ (ready=3) | L3 | open 完成即就绪 |
| N   (g=1) | ✓ | ✓ | ✓ (ready=3) | L3 | open 完成即就绪 |
| N+1 (g=2) | ✓ | ✓ | ✓ (ready=3) | L3 | open 完成即就绪 |

### 图片 EPUB（妹妹人生·上卷，318 页，1 图/页）
```
P10 flipTurned mode=simulation curN=3
  prev=g=2  ready=2 img=1 src=L2  cur=g=3 ready=2 img=1 src=L2  next=g=4 ready=2 img=1 src=L2
  → 动画前 imgDec=1/1（图片均在动画开始前解码完成）
```

**结论 B**：存活样本中 N-1 / N / N+1 **完全对称且 RENDER_READY（文本）或 LAYOUT_READY+资产就绪（图）**；不存在「N+1 READY / N-1 NOT_READY」现象（针对 ±1 热窗内页面）。

---

## C — Previous / Next 对比（first-frame latency & 渲染）

| 方向 | intent → finishFlip | 动画时长(ms) | 帧数 | avgMs | maxMs | 渲染错误 |
|---|---|---|---|---|---|---|
| NEXT（滑动左翻） | 13:31:50.506 → 50.909 | 403 | 24 | 5 | 11 | 0 |
| NEXT（点击翻页） | 13:26:03.383 → 03.807 | 424 | 25 | 6 | 10 | 0 |
| PREV（滑动右翻） | 13:24:46.720 → 47.130 | 410 | 24 | 5 | 10 | 0 |
| PREV（滑动右翻） | 13:32:02.850 → 05.304 | ~400* | 25 | 6 | 9 | 0 |

\* 13:32 次间隔含手势结束后动画完成迟滞；核心动画段（animateTo→finishFlip）与其余一致。
首帧延迟 = P10 intent（= 触摸同帧）→ 动画第 1 帧 = 0–16 ms（setInterval 首 tick）；
等待 3s / 10s 后重测结果相同（就绪态已在 open 完成，无「等待后改善」差异可测）。

**结论 C**：存活样本中 Previous/Next 延迟与渲染质量无差异、无失败。冷启动「N-1 严重问题」在本批样本未复现；对应症状归因冷启动冻结墙（A 章）与 S2/S3 代码路径。

---

## D — 连续翻页（×N）

| 指标 | 值 |
|---|---|
| 单次动画帧数 | 24–25 |
| 帧耗时 p50 / p95 / max | 3–6 ms / ~9 ms / 11 ms |
| 动画期间 pageGeneration 变更（mut） | 0（全部 `gen=10->10 mut=0`） |
| 渲染失败 | 0 |
| blank-frame（S2 首次会话路径，代码审计判定） | 修复前：首次反向无会话=整段空白帧；修复后：`{prev,cur}` 会话建立 |

---

## E — Cache ON/OFF

- Cache ON：本章所有测例均为 ON（L3/L2 命中可见；TXT 热窗 `openMs=0`）。
- Cache OFF：应用没有运行时开关（pageCacheContext 由 open 注入）；设备级 OFF 路径 PENDING。
- 逻辑一致性由 `Phase8CacheOnOffOHOSTest` 覆盖（Cache ON/OFF 页内容哈希一致）。
- 本阶段未改动 L2/L3 写读正确性；仅新增 L3 pin（不参与 LRU 逐出/收缩）。

---

## 汇总

| Benchmark | 结果 | 备注 |
|---|---|---|
| A Resume Page Ready | 小书 PASS（T0→T4≈65ms）；2MB 冷启动 PENDING | 冻结墙 THREAD_BLOCK_6S |
| B Bidirectional Readiness | PASS（对称 RENDER_READY/资产就绪） | 存活样本 |
| C Previous/Next 对比 | PASS（双向无差异、0 失败） | 存活样本 |
| D 连续翻页 | PASS（avg 3–6ms，max 11ms，mut=0） | 帧率稳定、代际无变更 |
| E Cache ON/OFF | PARTIAL | 设备 OFF 路径 PENDING；逻辑由既有测试覆盖 |