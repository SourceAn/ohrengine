# Phase 9.4 — Reader 接入

> 前置阅读：`00-overview.md`、`04-phase9.3-virtual-chapter.md`（须已完成）

## Parser 改造策略：最小侵入式改造

如果现有 `TxtParser.parse(file)` 返回 `WholeBookModel`，**不要**立即把
整个阅读引擎改成完全异步流式架构。

优先尝试：

```
TxtParser
    ↓
TxtSource / TxtDocument
    ↓
Index + ChunkReader
```

例如：

```
TxtDocument
 ├── getChapter(id)
 ├── getChunk(id)
 ├── getParagraph(...)
 └── resolveAnchor(...)
```

让上层 Reader 尽量继续使用原有模型，把 `TxtParser → WholeBook` 逐步变成
`TxtDocument → Lazy Chunk`。

## 兼容现有分页链

最终输入仍然应该是现有分页系统能接受的数据：

```
Chunk Text → Existing TextBreaker → Existing Layout → Page
```

**不要**为了 lazy loading 修改 TextBreaker 本身。

如果分页链要求连续文本：可以建立 `Current Chunk + 必要的 Boundary
Context`，但必须证明不会导致整本 TXT 被拼接进内存（可用 RSS 曲线证明）。

## 首次打开流程（理想）

```
Open TXT
   │
   ├── read metadata
   │
   ├── load existing index
   │
   ├── if index missing:
   │      build lightweight index
   │
   ├── restore ReadingAnchor
   │
   ├── locate target virtual chapter/chunk
   │
   ├── load target chunk
   │
   └── paginate visible page
```

### 首屏必须优先

**禁止**：打开 TXT → 后台任务先生成整本 L0 → 等待整本完成 → 显示第一页。

**应该**：首屏 → 立即读取目标 chunk → 完成首屏 → 后台逐步预热。

## 随机跳转

随机跳转必须支持：

```
进度条 → target position → Index lookup → 对应 chunk → load → paginate
```

**禁止**：`target page → 从文件头开始重新解析`。

如果现有分页是动态计算的，可以从目标 chunk 附近重新分页，但不能从整个
TXT 开始。

## Gate

- 用中型 TXT（如 50MB）实测随机跳转到 10% / 50% / 90% 位置，确认没有
  从文件头重新解析的路径被触发。
- Reader 层的调用方代码改动应尽量局限在数据获取层，TextBreaker /
  Layout / 动画相关代码 diff 应为零或接近零。
