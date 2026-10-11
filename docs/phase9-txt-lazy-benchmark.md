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

| 文件大小 | T0 Open | T1 metadata/index ready | T2 target chunk ready | T3 first page ready | Open→First Page 总耗时 |
|---|---|---|---|---|---|
| 10MB | PENDING | PENDING | PENDING | PENDING | PENDING |
| 50MB | PENDING | PENDING | PENDING | PENDING | PENDING |
| 100MB | PENDING | PENDING | PENDING | PENDING | PENDING |
| 200MB | PENDING | PENDING | PENDING | PENDING | PENDING |
| 500MB（若设备承受力不足至少测到 200MB） | PENDING | PENDING | PENDING | PENDING | PENDING |

> 注意：索引构建 T0→T1 为流式顺序扫描（不整本常驻）；此后二次打开走磁盘索引命中。

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
| THREAD_BLOCK_6S 是否消失 | PENDING（首屏阶段禁止数秒同步阻塞） |
| Main-thread longest block | PENDING |

## Benchmark D：随机跳转

| 目标位置 | Jump Request → Target Page Ready | RSS_peak |
|---|---|---|
| 10% | PENDING | PENDING |
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

**判定**：`RSS end ≈ RSS start + bounded cache overhead`。

## Cache ON / OFF 对照

- 用 `PageManager.getChapterParagraphs` / `computeCurrentPageLogicalTextHash`（Phase 7 已有）比较首页、中间页、随机跳转页、恢复页的逻辑文本 hash。
- 状态：PENDING（设备就绪后执行）。

---

## 结论

- 本阶段代码与 instrumentation 已完成；**所有实测数字 PENDING**，原因：无设备/模拟器。
- 连接设备后按上述流程即可复跑并回填。报告口径遵循 `10-phase9.9-final-report.md` 的 PASS/PARTIAL/FAIL/PENDING。