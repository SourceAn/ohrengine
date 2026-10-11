# Phase 9.8 — TXT Lazy Benchmark

> 目标：9.1–9.7 全部完成后跑真实数字（Benchmark A–E），输出本文件。
> 当前环境：**无已连接设备/模拟器**（`hdc list` / `devecocli device list` / `emulator list` 均空）。
> 因此本文件的「实测」列全部标记 **PENDING**，并附上可复现方法；一旦接入设备即可按本文件流程填数。
> 已按附录反作弊第 2 条：不使用任何定性描述代替数字。

## 前置：如何制造测试文件

- 200MB+ TXT 生成（设备内）：
  - 文学类章节结构：`第N章` + 固定段落模板重复拼接（可参考 `Phase9TxtLazyOHOSTest` 的 `writeLongSample`）。
  - 无章节结构（fallback 页模式）：纯长段落文本无任何标题命中。
  - CRLF / UTF-8 with BOM / GB18030 各一份（复用 `TxtEncodingDetector` 支持范围，不扩大）。
- 路径：`ctx.filesDir + '/books/'`，与 ReaderHost `resolveBookSource` 读取路径一致。

## 数据采集方式

- 应用内：`OhEngineCore.benchTxtLazyIndexMs`（T0 到 T1）、`benchOpenMs`/`benchRestoreMs` 已打点，destroy 时 `logCacheHitSummary` 输出。
- 补充 T2/T3：建议在 ReaderHost `.refreshPage()` 首次渲染回调处打点（首帧可见）。
- RSS：设备连上后用 `hdc shell dumpsys meminfo <pid>` 或不借助额外 SDK API（项目当前无进程内存 API，Phase 8 同样用外部采样）。

---

## Benchmark A：TXT 首次打开（Open → First Page）

**真机（<LAN-IP>, HUAWEI Mate 70 Pro+, API24）实测（2026-09-04）：**

| 文件大小 | T1 索引就绪（首次/缓存命中） | T3 首屏渲染 |
|---|---|---|
| 2MB (2,097,152 B) | 首次 build / 命中后 `txtLazyIdxMs=0` | ✅ `totalPages=1307` 可渲染 |
| 10MB | 首次 ~12.4s（触发 THREAD_BLOCK_6S） | ✅ 渲染到 `onFontSizeChanged` |
| 50MB / 200MB | 索引成功持久化（txt-index.json） | ⏳ 首开 build 耗时导致 6S 卡杀 |
| 500MB | 未运行（设备承受力评估前先解决 build 慢） | PENDING |

**关键确认：**
- ✅ **缓存命中路径**：`TXT-LAZY openLazy ... doc=1`，`chapters=146 vchs=146`，
  `CacheStats[open] ... txtLazyIdxMs=0`（磁盘索引复用 O(0ms)）。
- ⚠️ **首次索引构建**：2MB 也 >6s（触发 THREAD_BLOCK_6S），是当前最主要待优化点。

> 反作弊说明：下表不包含定性描述；数字来自 hilog `XmlaCache/OhEngine` 埋点，RSS 采用 `dumpsys meminfo` 外部采样（本会话主要验证功能，完整 RSS 表仍 PENDING）。

## Benchmark B：RSS

| 时间点 | 10MB | 50MB | 100MB | 200MB |
|---|---|---|---|---|
| Before open | PENDING | PENDING | PENDING | PENDING |
| After open | PENDING | PENDING | PENDING | PENDING |
| After first page | PENDING | PENDING | PENDING | PENDING |
| After 10 pages | PENDING | PENDING | PENDING | PENDING |
| After 100 pages | PENDING | PENDING | PENDING | PENDING |
| After random jump | PENDING | PENDING | PENDING | PENDING |
| After leaving reader | PENDING | PENDING | PENDING | PENDING |
| RSS_peak / RSS_after_idle | PENDING | PENDING | PENDING | PENDING |

**判定目标**：RSS 不随阅读进度线性增长（`RSS_end ≈ RSS_start + bounded cache overhead`）。

## Benchmark C：Main Thread Block

| 指标 | 值 |
|---|---|
| 首次索引构建阻塞 | ⚠️ 2MB >6s，10MB ~12s → THREAD_BLOCK_6S（设备被 AppMS kill） |
| 缓存命中后打开 | ✅ `txtLazyIdxMs=0`，open+CacheStats 即时完成（无 THREAD_BLOCK）。引擎热窗布局仍可达 6S（既有瓶颈，非 lazy 引入） |

## Benchmark D：随机跳转

| 目标位置 | Jump Request → Target Page Ready | RSS_peak |
|---|---|---|
| 10% | PENDING（跳转由 stub→provider 单 vch 读取；API 层面已实现） | PENDING |
| 50% | PENDING | PENDING |
| 90% | PENDING | PENDING |

> 禁止为跳转重新整本加载（`goToProgress` → stub → `ensureChapterReady` → 单 vch 读取）。

## Benchmark E：连续阅读 100 页

| 指标 | 值 |
|---|---|
| page latency p50 | PENDING |
| page latency p95 | PENDING |
| page latency max | PENDING |
| RSS start | PENDING |
| RSS peak | PENDING |
| RSS end | PENDING |

## Cache ON / OFF 对照

- 用 `PageManager.getChapterParagraphs` / `computeCurrentPageLogicalTextHash` 比较。
- 状态：PENDING（本轮未逐项跑；Phase 8 的 CacheOnOffOHOSTest 覆盖章节级 hash）。

---

## 结论

- **lazy 数据流真机可用**：索引+provider+vch+分页完成，磁盘索引命中后打开 O(0ms)，
  首屏可渲染（`totalPages=1307`）。
- **唯一未收敛的实测问题**：首次索引构建在主线程跑 >6s 触发 THREAD_BLOCK_6S。
  修复方向明确：将 index build 移入 taskpool/Worker（异步线程）或显著提升行扫描性能；
  已完成行级正则/裁剪优化（`quickHeadingTest`/`trimEdges`/`isBlank`），仍不足，需线程化。
- 剩余 Benchmarks（B/D/E 与 Cache ON/OFF、200MB/500MB）在 build 线程化后即可复跑。