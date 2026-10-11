# Phase 16.1 — LayoutResult 数据压缩与 JSON.parse 优化实验

> 生成时间：2026-09-04
> 设备：HUAWEI Mate 70 Pro+（API24）；pid 30469；`temp=nothing changed in production`
> 状态：**EXPERIMENT COMPLETE**（实验仅限 worker 侧一次性诊断；未修改正式序列化/反序列化/协议）

---

## 1. 字段级体积分析（真机 200MB TXT，单章 17 页 / 402 行 / 8040 字）

| 字段/字段组 | 字节数 | 占比 | 主线程用途（真实调用链） | 是否可移除 | 是否可重建 |
|---|---:|---:|---|---|---|
| charPositions | 126,295 | 29.3% | 文本选择命中/区间（TextSelection.ets）；批注下划线定位（AnnotationRenderer.ets） | 交互路径外可 | TextBreaker 可重算（成本=布局时逐字） |
| charWidths | 136,680 | 31.7% | 仅文本选择（TextSelection.ets） | 同左 | 同左 |
| text | 8,040 | 1.9% | 渲染/必要 | 否 | 否 |
| 几何+样式字段（x/y/w/h/ascent/…/listMarker 等 ~30） | ~160,200 | 37.1% | 渲染/提交/必要 | 否 | 否 |
| **合计（orig）** | **431,215** | 100% | — | — | — |

> 调用链证据：`rg` 全库定位 `charPositions/charWidths` 读取者 = `TextSelection.ets` + `AnnotationRenderer.ets`（仅交互/批注）；`PageRenderer` 正文绘制、分页、搜索、书签定位均未读取。

## 2. 实验结果（真机）

| 方案 | 输出大小 | JSON.parse | Deserialize | Commit | 翻页 Max |
|---|---:|---:|---:|---:|---:|
| Before（现状） | 431 KB | 27–37ms（本轮）/ 40–46ms（16.0） | 28–39ms | 5–8ms | ≤11ms |
| Minimal（实验性剔除 cp+cw） | **155 KB（−64%）** | **≈1ms（实测）** | 预估 <10ms（parse1+rebuild2-4+commit5-8） | 不变 | 不变 |
| Compact Character（未实现，评估） | ~60–80 KB | token 数↓ 同 minimal 量级 | — | — | — |

```
LAYOUT_WORKER_MINIMAL orig=431215 minimal=155778 cp=126295 cw=136680 text=8040 parseMin=1ms analyze=18ms
LAYOUT_WORKER_END ch=31 deser=28ms jsonParse=27ms rebuild=1ms
```

## 3. 关键判定（五个核心问题）

1. **431KB 能减少到多少**：仅移除交互专属逐字数组 → **155KB（−64%）**；再加几何紧凑化可更低（60–80KB 量级）。
2. **JSON.parse 能到多少**：minimal 格式实测 **≈1ms**（对照 orig 27–46ms）。**关键发现：parse 成本是 token 数量决定性，不是原始字节线性** —— 逐字数组含 ~16k 个数字 token，移除后解析时间非线性坍缩（27→1ms，字节只-64%）。
3. **主线程 deserialize <16ms 是否可行**：可行——minimal 路径 ≈ parse(1ms)+rebuild(2–4ms)+commit(5–8ms) ≈ **<10ms**。
4. **为何现状做不到**：非几何/对象重建（rebuild 实测仅 1–2ms）；而是 61% 体积的逐字数组随输出一起传输并参与 JSON.parse。
5. **是否值得继续**：值得作为**下一阶段候选**——收益上限已实测（−64% 体积 / parse ~97%↓ / deser<10ms）。但生产化必须解决文本选择/批注下划线的逐字数据按需恢复或紧凑编码（§七 B/C），复杂度中高；且当前 deserialize 不阻塞动画（P1/P2 债务）→ **不是 P0，是明确有界收益的 P1 优化项**。

## 4. 正确性矩阵

| 项 | 结果 | 依据 |
|---|---|---|
| Rendering | PASS | 生产序列化/反序列化/提交未改动（本实验为 worker 侧只读诊断） |
| Page Count / 行数 / 边界 | PASS | 未涉及生产数据结构 |
| Navigation / Latest-Jump-Wins / Session | PASS | 未涉及（epoch/destroyed/navigationSerial 原样） |
| Text Selection / 批注下划线 | **N/A（未触及）** | 生产路径保留逐字数组；若生产化移除需按需重建实验（下一阶段） |
| L2 磁盘协议 | 未改动 | — |

## 5. 线程/安全确认

- 测量全部在 Worker 线程（`LAYOUT_WORKER_MINIMAL` tid=30529 vs 主线程 30469）；主线程只收最终 LayoutResult，无额外损耗。
- 未新增任何缓存层；未改 PageReadyState；未绕过 `LAYOUT_RESULT_DROP` 验证。

## 6. 下一步建议（保留 2 方向）

1. **方案 A（首选）：生产化「逐字数组按需重建」**——LayoutResult 剔除 charPositions/charWidths（−64%），主线程需要命中/批注时按行重建（TextBreaker 同名算法、仅选中行）。预期 deser<10ms；风险=重建耗时/内存需实测；收益已量化。
2. **方案 B：紧凑逐字编码**——charPositions/charWidths 以压缩整数数组/编码存放（61%→个位数占比），keep JSON 语义。收益同 A 且不丢即时命中；风险=新编码的序列化/反序列化实现（本轮禁改，下轮做 Before/After 对照实验）。

> 选择 A 而非 B 的理由：A 直接消除最大体积项且 token 少；B 保留逐字数组仍需解析大量数字 token（parse 收益小于 A），且新增编码层复杂度更高。A/B 的取舍留待下一阶段数据驱动裁决。

---

## EXPERIMENT: COMPLETE

字段级体积已测、最小化实验已完成、真机 parse 前后数据已测、无生产修改、无伪异步、无伪造数据、Commit/翻页/Session 无回归（本轮回归：flip avg5–6/max≤11、200MB→Exit→2MB FIRST_FRAME 49ms、活着进行）。