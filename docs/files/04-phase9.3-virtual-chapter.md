# Phase 9.3 — Virtual Chapter 改造

> 前置阅读：`00-overview.md`、`03-phase9.2-chunk-reader.md`（须已完成）

## 目标

当前项目的 vchapter 如果已经存在，**不要删除**。

需要将其从：

> "内存中已经存在的全文切片"

变成：

> "可以通过 offset 定位到源文件范围的虚拟章节"

## 数据结构

```
VirtualChapter {
    id
    startByte
    endByte
    startCharOffset
    endCharOffset
    title
}
```

**不要**让 `VirtualChapter` 直接持有 `huge plaintext String`。

## 与现有 L0 Cache 的关系

不要重复造轮子。现有 L0 Content Parse Cache 应该继续存在。本阶段只
改变 TXT 首次解析和数据读取方式。推荐最终形成：

```
Source TXT
   │
   ├── Lightweight Index
   │
   └── Lazy Chunk Reader
           │
           ├── L0 Chunk Cache
           │
           └── Reader Session
```

### 关键原则

L0 缓存**可以**缓存 chunk。但**不能**因为 L0 存在，就在第一次打开时
把所有 chunk 全部生成——这只是换了个名字的 eager loading（参见附录
反作弊清单第 2 条）。

## Current Chunk Loading

Reader Session 只应该持有有限数量的 TXT chunk，例如：

```
Current Chunk
Previous Chunk
Next Chunk
```

具体数量由 benchmark 决定（见 `09-phase9.8-benchmark.md`）。

必须存在明确的释放策略：

```
current chunk → becomes cold → remove strong reference → allow GC
```

**不能**让 `chunkMap` 从第一章一直增长，最终整个 TXT 全部进入 RAM。

## Gate

- VirtualChapter 结构体审查：确认不包含全量文本字段。
- 抽查任意一个 vchapter，验证其可以仅凭 offset 信息重新定位并读取内容，
  而不依赖任何常驻的全文缓存。
