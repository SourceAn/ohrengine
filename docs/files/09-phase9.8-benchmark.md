# Phase 9.8 — Benchmark

> 前置阅读：`00-overview.md`，以及 9.1-9.7 已全部完成

## 总原则

本阶段不能继续使用 `<1s / 立即 / 正常 / 感觉明显更快` 这类定性描述。
**必须输出真实数字**，并生成文档：

```
docs/phase9-txt-lazy-benchmark.md
```

---

## Benchmark A：TXT 首次打开

至少测试文件大小：`10MB / 50MB / 100MB / 200MB / 500MB`
（若设备无法稳定承受 500MB，至少测到 200MB）。

记录：

```
T0 Open
T1 metadata/index ready
T2 target chunk ready
T3 first page ready
```

输出 `Open → First Page` 总耗时。

---

## Benchmark B：RSS

必须记录以下时间点的 RSS：

```
Before open
After open
After first page
After 10 pages
After 100 pages
After random jump
After leaving reader
```

重点观察 `RSS_peak` 与 `RSS_after_idle`。

目标不是"内存越低越好"，而是：**内存不应随着阅读进度持续线性增长。**

---

## Benchmark C：Main Thread Block

重点确认 `THREAD_BLOCK_6S` 是否消失，记录 `Main-thread longest block`。

目标：大型 TXT 首屏阶段不得出现数秒级同步阻塞。具体阈值以现有项目
baseline 为准，但必须给出数字。

---

## Benchmark D：随机跳转

测试跳转到 `10% / 50% / 90%` 位置，记录 `Jump Request → Target Page
Ready` 耗时，同时记录 `RSS_peak`。

**不能**为了随机跳转速度重新把整本 TXT 加载进 RAM。

---

## Benchmark E：连续阅读

测试连续翻页 100 页，记录：

```
page latency p50
page latency p95
page latency max
RSS start
RSS peak
RSS end
```

重点：`RSS end ≈ RSS start + bounded cache overhead`，而不是持续增长。

---

## Cache ON / OFF 对照

必须验证 Cache ON / Cache OFF 逻辑页面结果一致，**不能只比较截图**，
至少比较 Page content hash（或项目已有等价的 deterministic
representation）。测试范围：首页、中间页、随机跳转页、恢复位置页。

---

## 回归测试清单

### TXT 文件覆盖

小 TXT / 中型 TXT / 大型 TXT / 空文件 / 单段落 / 超长段落 / 多章节 /
无章节 / CRLF / LF / 混合换行 / UTF-8 / UTF-8 BOM / UTF-16（如原项目
支持）。

### 阅读行为覆盖

首次打开 / 冷启动恢复 / 热启动恢复 / 下一页 / 上一页 / 随机跳转 /
进度条 / 字号变化 / 行距变化 / 字体变化 / 主题变化。

### 并发压力（来自 9.6 的补强要求）

渲染当前页 + 预读 + 淘汰并发场景，必须包含在本轮回归中，不能只在
9.6 阶段测一次就默认长期有效。
