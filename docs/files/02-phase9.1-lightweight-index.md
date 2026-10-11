# Phase 9.1 — 建立 Lightweight Index

> 前置阅读：`00-overview.md`、`01-phase9.0-audit.md`（须已完成）

## 目标

实现 `TxtIndex` / `ChunkEntry`，只负责"如何快速找到 TXT 中某一段数据"，
**不负责保存正文**。

## 数据结构

```
TxtIndex {
    version
    fileSize
    encoding
    newlineMode
    contentFingerprint
    chunkSize
    chunks[]
}

ChunkEntry {
    id
    startByte
    endByte
    startCharOffset
    endCharOffset
    hash(optional)
}
```

如果现有阅读位置恢复需要 `paragraphIndex`，可以进一步建立：

```
ParagraphEntry {
    paragraphIndex
    startByte
    endByte
}
```

但必须经过 benchmark 证明确有必要，不要提前过度设计。

## 索引构建规则

**允许**：顺序扫描文件 → 发现换行 → 记录 offset → 生成 index
（使用 stream / random-access file read，或项目现有的等价能力）。

**不允许**：`readAll()` → 巨大 String → 扫描巨大 String → 生成 index。
这是"第二次整本内存加载"，等于没解决问题。

如果 HarmonyOS 当前 API 能力有限：
1. 先检查项目已有 File / Buffer / IO abstraction。
2. 优先复用现有抽象。
3. 不要为了本阶段引入重量级第三方依赖。
4. 不要为了追求"理论上的零拷贝"破坏 API24 兼容性（见 `appendix` 中 API24 要求）。

## 编码处理

必须实际审计项目当前支持哪些编码（UTF-8 / UTF-8 BOM / UTF-16 LE/BE /
GBK / GB18030 等），**不要凭空扩大编码支持范围**。

### Byte Offset 与 Character Offset 必须区分

绝对禁止混淆 `byte offset`、`character offset`、`UTF-16 code unit offset`。

项目必须明确现有阅读位置系统使用哪一种 offset，最终形成：

```
File Position → Byte Offset → Decoded Text Offset → ReadingAnchor
```

如果现有 ReadingAnchor 是 `chapterId / paragraphIndex / paragraphHash /
charOffset`，**必须保持其语义不变**。

## Chunk 边界设计

不要简单地"每 N byte 强行切割"导致多字节字符被拆断。推荐流程：

```
粗略目标 chunk size
    ↓
向后寻找安全 UTF-8 / 编码边界
    ↓
寻找换行 / 段落边界
    ↓
形成稳定 chunk
```

chunk 的目的不是分页，它只是**限制一次进入内存的数据规模**。

## Chunk 大小

不要拍脑袋定值。第一版优先使用项目现有 chunk size；如果没有，从
`64KB / 128KB / 256KB / 512KB` 中选一个保守范围做实验，再用 Benchmark
（见 `09-phase9.8-benchmark.md`）中的首屏耗时、随机跳转耗时、RSS、GC
次数、页面生成时间、连续翻页吞吐等数据决定最终值。

## Content Fingerprint

保持现有 `contentFingerprint` 语义。**不要每次打开都 hash entire TXT**——
那样虽然解决了 eager parse，却在启动阶段重新完整扫描了整个文件。

优先使用现有文件元数据（size / mtime 等轻量 metadata）；只有必要时才
重新计算 fingerprint。如果项目要求强 hash：必须放后台、不阻塞首屏，
并明确 hash 尚未完成时的缓存策略。

## Gate

用 200MB TXT 验证：建立 index 时**没有 200MB 级巨大 String 常驻**
（用内存 profiler 或 RSS 曲线证明，不接受口头描述）。
