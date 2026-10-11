# Constraints — OhEngine

> **硬性边界与决策记录。** 违反任何一条都视为架构/规范事故。按类型分组，均可在代码或已有任务文档中溯源。

---

## 1. 模块边界（最高优先级）

### 1.1 依赖方向（单向，禁反向）

```text
common ← {parsers, feature, epub, txt-exclusive, cbz-exclusive, pdf-exclusive}
{common, feature, parsers} ← ui-render
{ui-render, epub, txt, cbz, pdf, feature, gl} ← entry
gl：零模块依赖
```

- **禁止**任何模块 import 依赖链下游模块（如 common import feature、ui-render import gl）。
- **禁止**跨模块 import `src/main/ets/...` 内部路径；外部一律从各模块 `index.ets` 入口 import。
- TXT/CBZ 解析器已迁到 format-exclusive 模块、EPUB 解析器已迁入 `ohrengine-epub`：**不得放回 parsers**。

### 1.2 职责边界（模块职责表，详见 module_map.md §1）

| 模块/层 | 职责 | 禁止 |
|---------|------|------|
| Parser | 解析文件 → ParsedBook | **不能参与 UI**（禁 import ArkUI/Canvas/组件） |
| Layout | 排版（DOM→RenderTree→分页） | **不能依赖 GL**；禁 import ohrengine-gl / EGL |
| Renderer | 绘制（Canvas 画 LineBox） | **不能管理业务状态**（不持有/改写 engine 状态、标注、进度） |
| PageFlip | 动画（PageFlipEngine，Canvas 2D 后端） | **不能修改分页**（分页提交由 Bridge 在终帧渲染后统一触发） |

### 1.3 其他边界

- 引擎核心（ui-render）不直接读源文件：下游只消费 `ParsedBook`。
- **PageFlipEngine 是唯一翻页渲染路径**（当前渲染后端 ArkTS Canvas 2D，扩展见 A8）；旧 GL 实现已归档，不参与编译与运行。
- `OhEngine` 是对外唯一 API 门面；`OhEngineCore` 不是公共入口。
- 外部消费必须走 index.ets（`ohrengine-common/index.ets` 头注释强制要求）。

## 2. 架构决策记录（改这些行为 = 违约）

| ID | 决策 | 影响 |
|----|------|------|
| ARCH-003 | Theme/FontTheme 纯类型与 PRESET_THEMES/FONT_THEMES 常量在 common | feature/ui-render 引用 common，**禁止**回迁到 feature |
| ARCH-004 | ParserRegistry/StrategyRegistry 可实例化；静态 API 仅过渡 | 新核心代码优先用注入实例 |
| FR-005 | EPUB 解析缓存 `.parsed.json` | 命中跳过 parse；写失败不阻断打开 |
| ENG-002 | 字体注册走 `UIContext.getFont().registerFont()` | UI 线程组件调用（aboutToAppear 后） |
| ENG-003 | PageRenderer 销毁标记 | dispose 后不得再提交绘制/解码回调 |
| ENG-005 | 排版任务代数 layoutEpoch + destroyed 标记 | 重排/清空/销毁必须 bump epoch；过期回调丢弃 |
| ENG-006 | PDF 桩解析器明确抛"不支持" | 不得让 .pdf 落入解压/半初始化路径 |
| ENG-012 | Debug/Release 入口构建期分离 | hvigorfile 生成 BuildProfile.ets；release 无调试分支 |
| ENG-013 | 远程请求取消令牌 | 页面销毁中止在途请求 |
| **HOS-STPAGEFLIP-001（反转记录，D1）** | 2026-08-12：翻页渲染路径由 GL 反转为主任务 D1 修订版 | 旧决策"GL 是唯一翻页渲染路径，禁止回退 2D 翻页"已废止；现行为"PageFlipEngine 唯一（Canvas 2D 后端，A8 可扩展）"；旧 GL 实现归档 `archive/legacy-pageflip/`。已知取舍：旧 GL 高光/褶皱/锥形收窄不保留，视觉基准只对齐 StPageFlip（主任务 V1/V2）。翻页架构详见 `docs/tasks/pageflip/HOS-STPAGEFLIP-001.md` |

## 3. 运行时行为契约（不得破坏）

1. 状态机 `INITIALIZED → LOADING → READY / ERROR → DESTROYED`；非 READY 导航一律拒绝。
2. `open()` 返回时**全书已同步分页 + 已写缓存**（`layoutAllChaptersSync`，缓存优先+写穿）；不允许 stub 后台补齐。
3. 翻页到 stub 章节：**同步** `ensureChapterReady`，禁止 50ms 后台布局造成"解析中闪现"。
4. 排版后台化：`setTimeout` **50ms** 间隔逐章（防 30 章连续阻塞主线程 ~3.6s），不允许改回 0ms 或同步全量。
5. 分页模型提交时机：`PageFlipController.releaseCurl()` 判定完成/回弹 → `engine.turnPage()` → native 收尾动画；900ms 兜底防 native 完成回调丢失。
6. RTL 书籍视觉方向映射在 `PageManager.turnPage/peekPage`（FORWARD⇄BACKWARD 互换）。
7. 首行缩进 = **2em**（两个汉字宽，随字号联动）；禁止固定 vp 覆盖。
8. GL 纹理上传：PixelMap 先 `readPixelsToBuffer` 异步读回（不阻塞 UI）；native 方法仅经 XComponent `libraryname` 加载路径（禁静态 import，否则双加载冲突）。
9. `destroy()` 后 setTimeout 后台回调不得更新页面（ENG-005：pipeline.shutdown 置 destroyed）。

## 4. 缓存约束

- 页缓存指纹 = 源文件 mtime/size + `computeLayoutSignature(config, layoutProfile, baseFontSize)`；**layoutProfile/字号变化必须令缓存失效**（不失效 = 读到旧排版）。
- FXL（pre-paginated）书籍**跳过**页缓存。
- 缓存写入失败不得阻断打开（ParseCacheManager/PageCacheManager 内部容错）。

## 5. 安全约束（SEC-*）

- 解压 EPUB/CBZ 必经 `SecureArchive`：路径穿越（../）、符号链接、条目数量、解压总大小上限校验。
- 远程资源仅 HTTPS；5s 超时；响应体大小上限；内存/磁盘缓存上限；页面销毁取消在途请求。
- 签名/密钥（storePassword/keyPassword/私钥/证书路径）**永不入库**；本地签名配置放 `signing/`（.gitignore 忽略），经 hvigorfile 注入。

## 6. 编码规范

- ArkTS strict-mode：**禁 `any`/`unknown`/解构赋值/结构类型违规**；所有字段显式类型标注。
- **不加冗余注释**：只在决策/契约处写"为什么"。
- 日志统一 `hilog`，tag 前缀 `OhEngine`，性能日志用 `OhEngine-Perf`。
- 禁 emoji（除非用户要求）；文件命名/目录遵循现有约定（.ets 后缀、驼峰类名）。
- 新功能遵循插件式：先注册（ParserRegistry/StrategyRegistry）后使用，核心不写 `switch(format)`。

## 7. 性能红线（目标值，未真机实测）

| 操作 | 目标 |
|------|------|
| 翻页（含表格/列表/ruby） | <16ms |
| 字号调整当前页 | <16ms（ripple 前后 5 章 <100ms） |
| 首行缩进 / 行距调整 | <5ms / <2ms |
| 两端对齐 | <5ms |
| 全文搜索（30 万字） | <5ms |
| CSS 匹配（100 节点） | <3ms |

> ⚠️ 均为**设计目标**，未在真机实测；实测记录以 `docs/性能基准.md` 为准，禁止把目标值当实测引用。

## 8. 已知限制（改这里先确认）

> **迁移完成（2026-08-12，HOS-STPAGEFLIP-001 P4）：翻页渲染路径已切换。** 旧 GL 实现（`ohrengine-gl` + `PageFlipController`）已归档至 `archive/legacy-pageflip/`；唯一翻页驱动 = `PageFlipEngine`（`ohrengine-pageflip`，StPageFlip ArkTS Engine，当前 Canvas 2D 后端）。§1.3 已按主任务 D1 修订；§2 决策表新增反转记录。

- **PDF 不可用**（ENG-006，桩）；TTS 为桩（CoreSpeechKit 不可用，speakWord/stopSpeaking 仅日志）。
- CFI 定位为**近似实现**（`navigateToCfi` 只取章节号 + par 索引做字符偏移估算）。
- **已知取舍（HOS-STPAGEFLIP-001 D1 修订说明）**：旧 GL 实现的高光/褶皱/锥形收窄效果不保留；视觉基准只对齐 StPageFlip Canvas 版（主任务 V1/V2），禁止以"缺少旧 shader 效果"为由返工。翻页子系统后续以 `docs/tasks/pageflip/HOS-STPAGEFLIP-001.md` 及其从任务为准；`docs/tasks/iBooks风格仿真翻页动画重构.md` 已加 superseded 横幅（GL 路径不再重构）。
- 性能基准未真机采集。

## 9. 格式/命名约定（新文件必守）

- 新增解析器：放对应 format-exclusive 模块（txt/cbz/pdf），**不是** parsers/epub。
- 新增渲染策略：实现 `StrategyRouter`，在 OhEngine 构造时注册。
- 新增共享类型：先评估是否下沉到 `ohrengine-common/types/`（避免 ui-render↔feature 循环依赖）。
- index.ets 是唯一出口：新增公开符号必须在该模块 index.ets 显式导出。
- 构建：本地签名配置不入库；构建期注入，无签名时产物 unsigned。
