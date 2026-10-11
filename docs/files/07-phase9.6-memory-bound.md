# Phase 9.6 — Memory Bound（内存边界与并发安全）

> 前置阅读：`00-overview.md`、`06-phase9.5-reading-anchor.md`（须已完成）

## 目标

增加：

```
Chunk eviction
Temporary decode release
Reader Session cleanup
```

验证：连续阅读不会导致 RSS 线性增长。

## 内存预算

必须增加 TXT 专属内存预算，例如：

```
TXT Source Buffer Budget
TXT Decoded Chunk Budget
TXT Parser Temporary Budget
```

不要求照搬具体数字，但必须根据设备 RAM、当前 Reader Session、当前页面、
L3 cache 计算总预算。

重点：**不能因为 L3 + TXT chunk + LayoutCache 同时存在而出现叠加失控。**

## 后台预读

Lazy Loading 完成以后才允许做预读。优先级：

```
P0 当前可见 chunk
P1 下一 chunk
P2 上一 chunk
P3 相邻章节
P4 L0 cache write
```

禁止后台预读导致主线程阻塞，也禁止预读 N 个 chunk 导致内存重新失控。

## 并发与竞态保护（补强要求，必须实现）

审计中经常遗漏的一类问题：**当前页面正在渲染某个 chunk 时，后台预读
或淘汰逻辑并发地释放了该 chunk。**

必须明确：

1. **引用计数或等价机制**：任何 chunk 在被 Main/UI 线程用于渲染期间，
   必须处于"不可淘汰"状态；只有当没有任何活跃引用时才允许 evict。
2. **Reader Worker 与 Main 线程之间的读写协议**：谁负责决定 evict、
   谁负责查询"当前是否正在使用"，必须有清晰的单一决策点，不能两边
   都能独立触发释放。
3. **测试用例**：模拟"渲染当前页 + 同时触发预读 chunk N+2 + 同时触发
   淘汰 chunk N-2"的并发场景，验证不出现：
   - 渲染中的 chunk 被提前释放导致崩溃或空白页
   - 竞态导致同一 chunk 被重复解码
   - 死锁（Reader Worker 等待 Main 释放，Main 又在等待 Worker 完成解码）

## Gate

- 连续阅读 100 页后，RSS 应回落到"start + bounded cache overhead"的
  范围内，而不是持续增长（具体数字见 `09-phase9.8-benchmark.md`
  Benchmark E）。
- 并发压力测试（上文第 3 点）必须跑通且无崩溃、无死锁、无数据错乱。
