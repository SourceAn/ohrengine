# Phase 9.9 — 最终验收

> 前置阅读：`00-overview.md`、`09-phase9.8-benchmark.md`（须已完成），
> 以及 `appendix-anti-cheating-and-dod.md`

## 目标

生成：

```
docs/phase9-final-report.md
```

报告必须明确使用以下四种状态之一，**不能用"基本完成 / 整体正常 /
应该没问题"等模糊表述**：

```
PASS
PARTIAL
FAIL
PENDING
```

## 灰度回退要求（补强，正式上线前必须具备）

在标记 PASS 之前，必须确认存在一个可以一键切换的开关（feature flag /
配置项），用于在真机发现问题时：

```
新 lazy 数据流 → 回退 → 旧 eager parse 数据流
```

要求：

1. 开关粒度至少到"按书籍"或"按会话"级别，不需要重新发版即可切换
   （或至少可以通过下一次热更新/配置下发切换，不依赖代码回滚）。
2. 回退路径必须实际测试通过：即从 lazy 模式切换回旧模式后，
   ReadingAnchor 恢复、分页结果与切换前一致。
3. 报告中需注明该开关的当前默认状态（例如：先在少量用户/内测中默认
   打开 lazy 模式，其余保持旧模式）。

## 最终输出格式

### 1. 修改文件列表

```
file / change / reason / risk
```

### 2. 新增数据结构

```
TxtIndex
ChunkEntry
TxtDocument
TxtChunkReader
VirtualChapter（改造后）
...
```

### 3. 数据流变化

```
Before: TXT → readAll → parseAll → vchapter → page
After:  TXT → index → chunk → parse → page
```

### 4. 内存变化

至少给出 `10MB / 50MB / 100MB / 200MB` TXT 的 RSS 数据。

### 5. 首屏变化

```
Before / After / Delta
```

### 6. Main Thread Block

```
Before / After / Max Block
```

### 7. 随机跳转

```
10% / 50% / 90% 的跳转耗时与 RSS_peak
```

### 8. 回归结果

明确 `PASS / FAIL`，附具体失败用例（如有）。

### 9. 尚未解决的问题

如果有 `PENDING` 项，必须列出，**不得为了形成"完整报告"而隐瞒**。

### 10. 灰度回退状态

按上文"灰度回退要求"填写。

## Definition of Done 核对

在提交最终报告前，逐条核对 `appendix-anti-cheating-and-dod.md` 中的
Definition of Done 清单，未满足的一律标记为 `FAIL` 或 `PENDING`，
不允许跳过某一条却整体标记 `PASS`。
