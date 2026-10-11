# Phase 9.2 — Lazy Chunk Reader

> 前置阅读：`00-overview.md`、`02-phase9.1-lightweight-index.md`（须已完成）

## 目标

实现 `TxtChunkReader`，职责：

```
readChunk(chunkId)
```

## 要求

- 按 offset 读取（依赖 9.1 中的 `ChunkEntry`）
- decode（遵循 9.1 中确认的编码支持范围）
- chunk 生命周期可控（谁持有、何时释放，必须明确）
- 不自动缓存整个文件
- 支持随机读取（不要求从头顺序读取才能定位任意 chunk）
- 支持释放（chunk 用完后可以被 GC）

## 线程模型（本阶段必须遵守）

延续已有 Scheduler：

```
UI / Main
    │
    ├── P0 visible page
    │
    └── Reader Worker
            │
            ├── TXT Index
            ├── Chunk IO
            └── Decode
```

**不得**在 Main Thread 上做 `read huge TXT → decode huge TXT → split
huge TXT → parse huge TXT` 这一整条链路。

> 特别注意：`readAll()` 即使是异步 API，也不代表后续 decode / split /
> parse 不会阻塞主线程。因此 benchmark 必须观察真正的主线程阻塞
> （见 `09-phase9.8-benchmark.md` Benchmark C）。

## 段落跨 Chunk（本阶段必须重点测试的边界情况）

如果一个超长段落跨越多个 chunk：

**禁止**：为了得到完整 paragraph，把整个 TXT 读进内存。

**应该**：

```
Chunk A
 ↓
检测 paragraph 未结束
 ↓
按需读取 Chunk B（必要时继续读取 Chunk C、D…）
 ↓
拼接当前 paragraph
 ↓
解析
 ↓
释放不再需要的部分
```

### 补充要求（跨多个 chunk 的上限保护）

真实 TXT（尤其是无格式纯文本）经常出现连续几千字不换行，可能跨
3-5 个甚至更多 chunk。必须明确：

1. **向后扩展读取的 chunk 数量上限**（例如最多再读取 N 个 chunk 去寻找段落
   结束边界），超过上限后必须有明确的降级策略（例如：在安全字符边界
   强制截断，并标记该段落为"降级段落"，而不是无限扩展读取）。
2. 降级策略不能导致渲染错误或死循环，必须有对应回归测试（见
   `10-phase9.9-final-report.md` 回归测试清单）。
3. 如果某个 paragraph 极端巨大（如第 `23章` 超长文本行测试中的
   1MB/10MB/50MB 行），必须有单独保护策略，**不能允许
   single paragraph = hundreds of MB String**。

## 超长文本行测试

必须测试：`1MB line / 10MB line / 50MB line`（具体规模可按设备能力调整）。

要求：不崩溃、不无限增长、不产生不可控 RSS、不发生明显主线程冻结。

## 异常情况处理

必须处理：文件不存在、文件被删除、文件被修改、Index 损坏、Index
version 不兼容、encoding 检测失败、chunk offset 越界、UTF-8 截断、
UTF-16 边界问题、文件读取失败、随机访问失败、chunk decode 失败。

处理原则：

```
Index 可以重建
Cache 可以丢弃
Source TXT 才是真实数据源
```

## API24 兼容

本阶段不能引入仅 API26+ 的 TXT IO API。如果必须使用高版本 API，必须
提供 API24 fallback，并**实际在 API24 环境验证**，不要只依赖编译器
warning。
