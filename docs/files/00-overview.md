# Phase 9 — 大型 TXT 真正 Lazy / Streaming 解析优化

## 总览（所有执行 Agent 必读）

> **定位：本阶段不是继续增加缓存层，而是修复当前架构中最大的真实性问题：
> TXT 虽然已经有 vchapter / chunk / L0 磁盘缓存，但 `TxtParser` 仍然在打开
> TXT 时把整个文件读入内存并完成整本解析。**

核心目标，从：

```
TXT → 整文件读取 → 整本解析 → 全量数据驻留内存 → vchapter → 分页
```

改成：

```
TXT → 轻量索引 → 按需定位 vchapter/chunk → 当前 chunk → 当前页面
```

必须保持现有阅读引擎、TextBreaker、Knuth-Plass、分页算法、页面动画和 UI
行为不变。

---

## 一、背景与已确认问题

Phase 8 的执行结果已经确认：

1. L0 在磁盘层面已经具备 chunk 化能力。
2. L1 阅读位置恢复已经可用。
3. L2 HotPageCache 已实现。
4. L3 MemoryPageCache 已实现。
5. LayoutCache / AssetCache / Scheduler / CacheIndex / ImportCheckpoint 等
   基础设施已经存在。

但是大型 TXT 仍然存在严重问题：

- `TxtParser` 仍然倾向于整文件读取。
- `chunkPlainTexts` / `chapterHtmlCache` 等结构可能继续持有全量文本。
- vchapter 是**后续逻辑切分**，不是源文件级真正 lazy loading。
- 大 TXT 出现 `THREAD_BLOCK_6S`。
- RSS 曾达到约 **349MB**。
- 因此目前 L0 更准确地说是"磁盘分块缓存"，而不是"真正的按需解析"。

**本阶段唯一核心任务：消除 TXT 整本 eager read / eager parse。**
不要因为发现这个问题而继续增加新的 Cache Layer。

---

## 二、最高优先级原则

执行 Agent 必须遵守：

### P0：先证明现状，再修改

在修改任何代码之前，必须定位：

1. 当前 TXT 导入流程
2. `TxtParser`
3. TXT 文件读取 API
4. 全文字符串 / 全量段落 / 全量 HTML 的持有位置
5. vchapter 创建位置
6. 分页入口
7. L0 chunk 的生成和读取路径
8. 阅读位置恢复路径
9. 当前真实数据流
10. benchmark instrumentation 是否存在

**禁止未经审计直接重写 `TxtParser`。** 具体审计任务见 `01-phase9.0-audit.md`。

---

## 三、严格禁止修改的区域

本阶段禁止修改以下核心能力：

- TextBreaker 核心算法
- Knuth-Plass 核心算法
- 分页算法
- PageLayout 核心逻辑
- 页面动画 / 翻页动画
- UI 阅读交互
- 字体排版规则 / 行距算法 / 字号计算逻辑
- 现有 EPUB 解析流程与 L0/L1/L2/L3 架构
- LayoutCache / AssetCache 的既有设计

除非为了适配 TXT lazy 数据接口而进行**极小范围的调用适配**。

**绝对禁止把本阶段变成"重新设计整个阅读引擎"。**
本阶段只解决：**TXT 数据从磁盘进入内存的方式。**

---

## 四、目标架构

### 4.1 最终数据流

```
TXT File
   │
   ▼
Lightweight TXT Index
   │
   ├── encoding
   ├── fileSize
   ├── newline mode
   ├── chapter/chunk offsets
   └── optional paragraph offsets
   │
   ▼
Virtual Chapter / Chunk Locator
   │
   ▼
按需读取当前 chunk
   │
   ▼
当前 chunk 内部解析
   │
   ▼
TextBreaker / 现有分页链
   │
   ▼
Page
```

打开一本大型 TXT 时，**不能**：

```
TXT → readAll() → 巨大 String → split() → 全部 paragraph → 全部 vchapter
```

**应该**：

```
TXT → 读取少量元数据 → 构建/读取轻量索引 → 定位当前 vchapter
    → 读取当前 chunk → 分页
```

---

## 五、实现阶段一览（对应本目录下各文件）

| 文件 | 阶段 | Gate |
|---|---|---|
| `01-phase9.0-audit.md` | 审计 | 未完成审计不允许大规模修改 |
| `02-phase9.1-lightweight-index.md` | 建立轻量索引 | 200MB TXT 建索引时无巨大 String 常驻 |
| `03-phase9.2-chunk-reader.md` | Lazy Chunk Reader | 支持随机读取与释放 |
| `04-phase9.3-virtual-chapter.md` | Virtual Chapter 改造 | 从 Text Holder 变成 Range Descriptor |
| `05-phase9.4-reader-integration.md` | Reader 接入 | TextBreaker/分页/动画不变 |
| `06-phase9.5-reading-anchor.md` | ReadingAnchor 接入 | paragraphHash correction 仍然有效 |
| `07-phase9.6-memory-bound.md` | 内存边界与并发 | 连续阅读 RSS 不线性增长 |
| `08-phase9.7-prefetch.md` | 首屏与预读优化 | 首屏优先，预读顺序不倒置 |
| `09-phase9.8-benchmark.md` | Benchmark | 输出真实数字，禁止定性描述 |
| `10-phase9.9-final-report.md` | 最终验收 | PASS / PARTIAL / FAIL / PENDING |
| `appendix-anti-cheating-and-dod.md` | 反作弊清单 + Definition of Done | 贯穿全程 |

**执行纪律**：每完成一个 Phase → 编译 → 运行相关测试 → 真机验证 →
记录 benchmark → 检查 git diff → 确认没有扩大修改范围 → 再进入下一阶段。

如果某一步失败：**停止扩展改动，先定位原因**，不要"失败→继续堆代码→最后一起修"。

---

## 六、最终目标（校验标准）

完成后，打开 200MB+ TXT 时，理想数据流：

```
Open
 ├── metadata
 ├── lightweight index
 ├── restore anchor
 ├── locate chunk
 ├── read current chunk
 ├── existing pagination
 └── FIRST PAGE
          ├── next chunk prefetch
          └── background cache
```

绝对不能再出现：

```
Open → read entire TXT → decode entire TXT → split entire TXT
     → parse entire TXT → create all virtual chapters → create all L0 chunks
     → FIRST PAGE
```

> 本阶段成功标准不是"缓存更多"，而是让 TXT 真正变成按需读取的数据源。
> 如果 Phase 9 只能完成一件事：**优先彻底消除 `TxtParser` 的
> whole-file eager read / eager parse。** 其他优化全部让位于这个目标。
