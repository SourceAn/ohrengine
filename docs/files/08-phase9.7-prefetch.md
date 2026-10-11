# Phase 9.7 — 首屏与预读优化

> 前置阅读：`00-overview.md`、`07-phase9.6-memory-bound.md`（须已完成）

## 目标

确认加载顺序不倒置：

```
First Page
 ↓
Next Chunk
 ↓
Previous Chunk
 ↓
Background Cache
```

## 要求

- 首屏渲染完成之前，不允许有任何 next/previous chunk 或整本 L0
  预生成任务抢占主线程资源。
- Background Cache（L0 写入等）必须在空闲时段执行，且遵循 9.6 中定义
  的并发保护机制。
- 若设备内存紧张导致预读被抑制，应有明确的降级策略（例如仅保留
  Current Chunk，暂停 Next/Previous 预读），而不是静默失败或崩溃。

## Gate

- 用 Benchmark A（见 `09-phase9.8-benchmark.md`）验证 T2（target chunk
  ready）到 T3（first page ready）之间没有被无关的预读任务拖慢。
