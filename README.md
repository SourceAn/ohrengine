# OhEngine — HarmonyOS EPUB 阅读引擎

自研的 HarmonyOS（ArkTS）原生电子书阅读引擎，提供从"文件解析 → HTML/CSS 解析 → 样式计算 → 排版 → 分页 → 渲染"的完整管线。

参考 crengine（C++）布局算法和 Readium（Kotlin）架构模型，针对 CJK 排版深度优化。

---

## 项目简介

- **架构**：模块化多格式引擎。9 个 HAR 模块（common / parsers / epub / ui-render / feature / txt-exclusive / cbz-exclusive / pdf-exclusive / gl）+ 1 个 entry HAP。
- **管线**：解析器统一输出 `ParsedBook`，渲染器只消费 `ParsedBook`；策略路由器按渲染策略分发，格式扩展零侵入。
- **统一导入（导入即解析）**：所有消费者项目经唯一入口 `ImportService.importBook` 导入图书（接入源文件 +（EPUB/CBZ）解压 + 解析 + 解析结果落盘），导入完成即已解析，再次打开命中解析缓存**热启动**；同时保留原始源文件以支持**可逆导出**（`exportBook`，产物与源逐字节一致，用于分享）。
- **批量导入（多选一次导入多本）**：书架导入入口支持**多选**，经统一入口的批量能力 `ImportService.importBooks` **逐本串行**处理（每本复用单本语义，幂等/去重/失败原子性一致），过程显示「导入中 x/N：书名」进度、结束显示汇总（成功 / 已存在 / 失败 / 不支持）；某项失败或不支持时**跳过并继续**，不中止整批。为**前台顺序批处理**，不引入持久化任务队列/后台服务。
- **极简书架与彻底删除**：正式书架与调试书架统一为同一极简纯文字列表（数据以导入台账为准），点按打开、**长按 + 确认弹窗彻底删除**。删除经唯一入口 `ImportService.deleteBook` 清除该书全部关联数据（源文件、解压目录、解析/分页缓存、持久目录、台账、阅读进度、批注与书签）；跨模块清理（批注/书签）经可注册钩子 `BookAssociatedDataCleaner` 由应用层注入。
- **渲染**：Canvas 自渲染（非 Text 组件），支持 EPUB 2/3、CSS 引擎、字体回退、表格/列表/ruby/float/flex、MathML/SVG。
- **安全**：EPUB/CBZ 解压经 `SecureArchive` 校验（路径穿越/符号链接/数量/大小上限）；远程资源仅 HTTPS 且有超时与响应体/缓存上限。

---

## 快速开始

```typescript
import { OhEngine } from 'ohrengine-ui-render';
import { ImportService, ImportStatus, ParserRegistry } from 'ohrengine-common';
import { EpubParser } from 'ohrengine-epub';

// 注册格式解析器（按需注册：EPUB / TXT / CBZ）
ParserRegistry.register(new EpubParser());

// ① 统一导入入口（导入即解析）：接入源文件 + 解压 + 解析 + 落盘。
//    EPUB / TXT 完整支持；CBZ 透传；PDF / 未知扩展名明确拒绝。
const result = await ImportService.importBook(ctx.filesDir, { sourceUri: uri });
if (result.status !== ImportStatus.SUCCESS && result.status !== ImportStatus.ALREADY_IMPORTED) {
  return; // UNSUPPORTED / FAILED，见 result.error
}
const book = result.record!;

// ② 打开书籍（已导入 → 命中解析缓存，热启动；sourcePath/cacheDir/libraryDir 来自台账）
const engine = new OhEngine();
engine.configure({ viewWidth: contentWidth, viewHeight: contentHeight, density: densityPixels });
const pub = await engine.open(book.extractDir.length > 0 ? book.extractDir : book.sourcePath, {
  sourcePath: book.sourcePath, cacheDir: book.cacheDir, libraryDir: book.libraryDir
});

// 翻页 / 读取当前页
engine.turnPage(TurnDirection.FORWARD);
const page = engine.getCurrentPage(); // page.lines → LineBox[] 供 Canvas 渲染

// 调整字号与排版
engine.fontSizeController.setUserFontSize(18);
engine.fontSizeController.applyUserFontSize();
engine.setLayoutProfile({ lineSpacing: 4, textIndent: 40 });

// ③ 可逆导出（用于分享）：产物与导入源逐字节一致
const art = await ImportService.exportBook(ctx.filesDir, book.bookId);
```

> **批量导入（书架多选）**：`ImportService.importBooks(ctx.filesDir, requests, onProgress?)` 逐本串行复用
> `importBook` 语义，失败/不支持跳过继续，返回 `BatchImportResult`（`succeeded`/`alreadyImported`/`unsupported`/`failed`）。

页面层完整用法见 `entry/src/main/ets/pages/Index.ets`；公共 API 参考见 [`docs/公共API.md`](docs/公共API.md)。

---

## 支持范围

> 统一导入（导入即解析）/ 可逆导出承诺矩阵：**EPUB / TXT** 完整支持（导入即解析 + 热启动 + 可逆导出）；
> **CBZ / CBR** 透传（接入 + 解压，维持现状，不含热启动/导出承诺）；**PDF / 未知扩展名**拒绝。

| 格式 | 状态 | 统一导入 / 热启动 / 可逆导出 | 说明 |
|------|------|------|------|
| EPUB | ✅ 已实现 | ✅ / ✅ / ✅ | EPUB 2.0.1 / 3.2 / 3.3：container → OPF → Manifest → Spine → NCX/nav → 封面；CSS / @font-face / @media / @import |
| TXT | ✅ 已实现 | ✅ / ✅ / ✅ | 大文件**分块异步读取 + 流式 UTF-8 解码**（ENG-004），空行分章；导入即建惰性索引（`library/<bookName>/txt-index-v2.json`） |
| CBZ / CBR | ✅ 已实现 | ✅(透传) / ✗ / ✗ | ZIP 解包 + 图片排序，走 IMAGE 渲染策略；解压经 `SecureArchive` 安全校验 |
| PDF | ✗ 规划中（不可用） | ✗（拒绝）/ — / — | 当前为**桩**：`PdfParser.parse()` 明确抛 "PDF format is not supported yet (planned)"（ENG-006），统一入口返回 `UNSUPPORTED`，不留半初始化产物 |

> 注册解析器时同样注册 PDF 桩，`.pdf` 文件会得到明确的"不支持 PDF"提示，不会落入解压/半初始化路径。

---

## 性能指标（目标值，未实测）

> ⚠️ 下表为**设计目标值**，**尚未在真机/模拟器上实测**，不得当作实测数据引用。
> 实测记录见 [`docs/性能基准.md`](docs/性能基准.md)（当前仅有桌面参考：TXT 分块读取 ~86ms、EPUB 解压 ~10ms；真机基准待设备接入后补充）。

| 操作 | 目标耗时 | 说明 |
|------|------|------|
| 书打开（含 @font-face 加载 + @media 筛选） | <800ms | 含字体加载时间 |
| 翻页（含表格/列表/ruby 渲染） | <16ms | 逐字渲染路径 |
| 字号调整 | <16ms 当前页 / <100ms 前后 5 章 | 涟漪扩散重排 |
| 首行缩进调整 | <5ms | 段落级局部重排 |
| 行间距调整 | <2ms | 纯 Y 坐标变换 |
| 两端对齐计算 | <5ms | 含标点挤压 |
| 全文搜索（30 万字） | <5ms | 逐章 indexOf |
| CSS 规则匹配（100 节点） | <3ms | RuleIndex O(1)+O(k) |
| 查词（在线 API） | 300–800ms | 含网络延迟 |
| SQLite 标注读写 | <5ms | 单条 INSERT OR REPLACE |

---

## 文档入口

- [`docs/README.md`](docs/README.md) — 文档地图
- [`docs/status.md`](docs/status.md) — 模块/能力状态（implemented / partial / proposed / archived）
- [`docs/性能基准.md`](docs/性能基准.md) — 性能基准（目标值 vs 实测值分离）
- [`docs/tasks/[主任务]OhEngine长任务总控.md`](docs/tasks/%5B主任务%5DOhEngine长任务总控.md) — OpenCode 长任务唯一入口
- [`docs/tasks/[完成]本地签名与构建配置.md`](docs/tasks/%5B完成%5D本地签名与构建配置.md) — 已完成的本地签名配置说明
- [`docs/tasks/[部分完成]排版任务后台化评估.md`](docs/tasks/%5B部分完成%5D排版任务后台化评估.md) — 排版后台化现状和遗留问题
- [`tests/epub/README.md`](tests/epub/README.md) — EPUBCheck 兼容性测试记录

测试：hypium 单元测试在 `entry/src/ohosTest/ets/unit/`；桌面参考性能脚本在 `tests/bench/`。

---

## 许可证

项目内部使用。
