# PLATFORM_CAPABILITY_INVENTORY — 平台能力清单（从真实调用点反向提取）

> 生成：2026-10-11 ｜ 方式：全仓扫描 `@kit.*` / `@ohos.*` / native `.so` / `Date.now` / `setTimeout` 等真实调用点（脚本：`tests/architecture/check_boundaries.mjs` 的 capability 报告）。
> 约束：本轮**只调查/设计/验证**；不新建 HAR、不改产品代码、不实现 SPI、不迁移。
> 分层口径：ENGINE=`ui-render`+`common`；FORMAT=`epub/txt/cbz/pdf`；RENDER=`reader`；APP=`entry`；OTHER=`feature`。

## 1. Executive Summary
- 工程实际触达的**平台能力约 30 项**，但**Engine 真正需要的仅 5 项**：FileSystem、TaskScheduler、Logger、FontProvider、Archive(ZIP)。
- Engine 当前**直接泄漏**（`check_boundaries` capability 报告）：`FileSystem×12, Logger×4, ImageDecoder×2, Archive×1, FontRegister×1, TaskScheduler×1, TextCodec×1`。
- 大量能力（Window/Display/Battery/Vibrator/Preferences/Database/Clipboard/Network/TTS/Translation/FilePicker/Ability-Context/uiMaterial）**只出现在 Application/Renderer**，不应进入 Engine SPI。
- 三个"疑似 Platform SPI"应重定位：**ImageDecoder / Canvas / GLES → Renderer**；**MemoryManager → DROP**；**SecureArchive → 拆为 PlatformArchive(codec) + Format(policy)**。
- 结论：`platform-api`（engine-facing）应为 **SMALL**（5 接口），而非"万能系统服务层"。

## 2. Actual Platform Usage（扫描事实）
- `@kit.*`/`@ohos.*` import 站点：**~110 处**，覆盖 10 个模块。
- 能力分布（脚本输出）：ENGINE 7 类、FORMAT 6 类、RENDER 17 类、APP 12 类、OTHER(feature) 7 类。
- 关键原始行（节选）：
  - `ohrengine-common/src/main/ets/service/SecureArchive.ets:17,18` → `fileIo`, `zlib`
  - `ohrengine-common/src/main/ets/service/PageCacheManager.ets:23` → `fileIo`
  - `ohrengine-common/src/main/ets/font/FontLoader.ets:18` → `fileIo`
  - `ohrengine-ui-render/src/main/ets/OhEngineCore.ets:30,31` → `font`(ArkUI), `fileIo`
  - `ohrengine-ui-render/src/main/ets/core/PipelineManager.ets:28,29` → `hilog`, `taskpool`
  - `ohrengine-ui-render/src/main/ets/render/ImageRenderer.ets:13,14` → `image`, `fileIo`
  - `ohrengine-txt-exclusive/src/main/ets/TxtIndexBuilderTask.ets:10` → `taskpool`
  - `ohrengine-reader/src/main/ets/ReaderHost.ets:24,25,27` → `fileIo`, `window/display/UIContext/curves`, `hilog`
  - `ohrengine-reader/src/main/ets/glass/OhGlass.ets:55,56,57,59` → `display`, `image`, `hilog`, `libliquidglass.so`
  - `ohrengine-reader/src/main/ets/service/BatteryMonitor.ets:1` → `BusinessError, commonEventManager`
  - `ohrengine-feature/src/main/ets/annotation/AnnotationStorage.ets:10` → `relationalStore`
  - `ohrengine-epub/src/main/ets/parser/EpubParser.ets:20,21` → `fileIo`, `util`

## 3. Capability Inventory

| ID | Capability | 代表调用点 | 当前模块 | OS/API | Consumer | Replaceable | Cross-platform | Candidate SPI | Priority |
|---|---|---|---|---|---|---|---|---|---|
| P-001 | File read/write/stat | `common/service/PageCacheManager.ets:23`;`ui-render/OhEngineCore.ets:31`;`txt/TxtDocument.ets:17` | common/ui-render/txt/reader/epub/cbz/pdf/feature/entry | `@kit.CoreFileKit fileIo` | engine/format/render/app | Yes | Yes | FileSystem | **P0** |
| P-002 | ZIP decompress | `common/service/SecureArchive.ets:18`;`pdf/PdfParser.ets:24` | common/pdf | `@kit.BasicServicesKit zlib` | format(epub/cbz/pdf) | Yes | Yes | PlatformArchive | **P1** |
| P-003 | Parallel task execution | `txt/TxtIndexBuilderTask.ets:10`;`ui-render/core/PipelineManager.ets:29` | txt/ui-render | `@kit.ArkTS taskpool` | engine(layout)/format(txt) | Yes | Yes | TaskScheduler | **P0** |
| P-004 | Logging | `ui-render/OhEngineCore.ets:16`;`txt/TxtDocument.ets:18`;`reader/ReaderHost.ets:27` | 全模块 | `@kit.PerformanceAnalysisKit hilog` | all | Yes | Yes | Logger | **P1** |
| P-005 | Font file load + register | `ui-render/OhEngineCore.ets:30`(`font`);`common/font/FontLoader.ets:18` | ui-render/common | `@kit.ArkUI font` + `fileIo` | engine(text) | Yes | Yes | FontProvider | **P1** |
| P-006 | Text decode/encode | `txt/TxtChunkReader.ets:16`;`epub/EpubParser.ets:21` | txt/epub/feature/ui-render | `@kit.ArkTS util` | format/engine | Partly(JS builtin) | Yes | TextCodec | P2 |
| P-007 | XML parse | `epub/parser/XmlDomParser.ets:7` | epub | `@kit.ArkTS xml` | format/epub | Yes | Yes | (format util) | P2 |
| P-008 | Image decode | `ui-render/render/ImageRenderer.ets:13`;`reader/reader/PageRenderer.ets:7`;`reader/glass/OhGlass.ets:56` | ui-render/reader | `@kit.ImageKit image` | render backend | Yes | Yes | **Renderer ImageDecoder** | P1(render) |
| P-009 | GLES 材质渲染 | `reader/glass/OhGlass.ets:59` | reader | `libliquidglass.so`(native EGL/GL) | render backend | Yes | No(原生) | **DROP→Renderer** | DROP |
| P-010 | Canvas 绘制 | `reader/reader/PageRenderer.ets`(CanvasRenderingContext2D) | reader | ArkUI Canvas | render backend | Yes | No | **DROP→Renderer** | DROP |
| P-011 | Wall clock | `ui-render/core/PageManager.ets:1618`;`reader/reader/FlipPageController.ets:426` | ui-render/reader/common/feature/epub | `Date.now()`(JS 内建) | all(timing/ts) | N/A(非 OS) | Yes | Clock | **P2** |
| P-012 | Timers | `ui-render/OhEngineCore.ets:1279`;`epub/media/MediaOverlayController.ets:163` | ui-render/epub/reader/txt | `setTimeout/setInterval`(JS) | engine/render | N/A | Yes | (JS runtime) | DROP |
| P-013 | Memory pressure | `EntryAbility.onMemoryLevel → common/service/MemoryPressureHub.ets:28` | entry→common | `AbilityConstant.MemoryLevel` | engine(PageManager shrink) | Yes | Yes | MemoryPressure(可选) | P2 |
| P-014 | Key-value prefs | `feature/bookmark/BookmarkStorage.ets:12`;`reader/utils/ReaderSettings.ets:12` | feature/reader | `@kit.ArkData preferences` | app | Yes | Yes | (App 存储) | **DROP** |
| P-015 | Relational DB | `feature/annotation/AnnotationStorage.ets:10` | feature | `@kit.ArkData relationalStore` | app | Yes | Yes | (App 存储) | **DROP** |
| P-016 | Clipboard | `feature/selection/TextSelection.ets:12` | feature | `@kit.BasicServicesKit pasteboard` | app | Yes | Yes | (App) | **DROP** |
| P-017 | HTTP | `feature/dictionary/DictionaryScheduler.ets:13` | feature | `@kit.NetworkKit http` | app | Yes | Yes | (App) | **DROP** |
| P-018 | TTS | feature(dictionary/TTS) | feature | `@kit.SpeechKit` | app | Yes | Yes | (App) | **DROP** |
| P-019 | Translation | feature | feature | `@kit.TranslationKit` | app | Yes | Yes | (App) | **DROP** |
| P-020 | Battery | `reader/service/BatteryMonitor.ets:1`;`reader/utils/ReaderStatus.ets:4` | reader | `commonEventManager`,`batteryInfo` | app | Yes | Yes | (App) | **DROP** |
| P-021 | Vibrator | `reader/panels/ReaderFontSlider.ets:1` | reader | `@kit.SensorServiceKit vibrator` | app | Yes | Yes | (App) | **DROP** |
| P-022 | Display metrics | `reader/common/ReaderTheme.ets:1`;`reader/glass/OhGlass.ets:55` | reader | `@kit.ArkUI display` | app/render | Yes | Yes | (App/Render) | **DROP** |
| P-023 | Window | `reader/ReaderHost.ets:25`;`reader/utils/ReaderThemeUtils.ets:1` | reader/entry | `@kit.ArkUI window` | app | Yes | Yes | (App) | **DROP** |
| P-024 | UI widgets/material/animation | `entry/*`,`reader/panels/*`,`feature/selection/TextSelection.ets:13` | entry/reader/feature | `@kit.ArkUI`(Component/uiMaterial/curves/UIContext) | app | N/A | No | (App UI) | **DROP** |
| P-025 | Ability/Context/Want | `entry/EntryAbility.ets:1`;`feature/.../common` | entry/feature | `@kit.AbilityKit` | app/platform(装配) | N/A | No | (App/Platform 装配) | **DROP** |
| P-026 | Audio (AVPlayer) | `epub/media/MediaOverlayController.ets`(占位) | epub | `@ohos.multimedia.media`(未启用) | format/media-overlay | Yes | Yes | (暂缓) | P2 |
| P-027 | Key input | `reader/reader/VolumeKeyTurner.ets:22` | reader | `@kit.InputKit` | app | Yes | No | (App) | **DROP** |
| P-028 | System events | `reader/service/BatteryMonitor.ets:1` | reader | `commonEventManager` | app | Yes | Yes | (App) | **DROP** |
| P-029 | deviceInfo/时间 | `entry/debug/HdsMaterialHostPoc.ets:10`;`reader/utils/ReaderStatus.ets:4`(`systemDateTime`) | entry/reader | `@kit.BasicServicesKit` | app | Yes | Yes | (App) | **DROP** |
| P-030 | File picker | `entry/debug/DebugBookshelf.ets:16` | entry | `@kit.CoreFileKit picker` | app | N/A | No | (App) | **DROP** |

## 4. Engine Platform Dependencies（Engine 真正需要的）
| SPI 候选 | 真实调用点 | 优先级 |
|---|---|---|
| FileSystem | `common/{PageCacheManager,ParseCacheManager,DiskCacheQuotaManager,CacheMigration,ImportCheckpoint,ReadingStateStore,SecureArchive,FontLoader}`、`ui-render/{OhEngineCore,FontLoader,CssImportResolver,ImageRenderer}`、`txt/*` | P0 |
| TaskScheduler | `txt/TxtIndexBuilderTask.ets:10`、`ui-render/PipelineManager.ets:29` | P0 |
| Logger | `ui-render/*`(4)、`txt/*`(3)（+engine 内 `hilog` 4 处） | P1 |
| FontProvider | `ui-render/OhEngineCore.ets:30`(`font` 注册)、`common/ui-render FontLoader`(文件加载) | P1 |
| Archive | `common/SecureArchive.ets:18`(引擎侧唯一，实际供 format 用) | P1 |

> 注：Engine（ui-render）还使用 `image`（`ImageRenderer`）——但 `ImageRenderer` 属 **Renderer**，故归 P-008（Renderer），不进 Engine platform-api。

## 5. Application-only Platform Dependencies（**不得**进 Engine SPI）
P-014 Preferences、P-015 Database、P-016 Clipboard、P-017 HTTP、P-018 TTS、P-019 Translation、P-020 Battery、P-021 Vibrator、P-022 Display、P-023 Window、P-024 UI widgets/material、P-025 Ability/Context、P-027 Input keys、P-028 System events、P-029 deviceInfo/systemDateTime、P-030 File picker。
理由：均为 **UI/产品/账号/书城/设置** 需求，Engine 不需要（§12）。

## 6. Renderer Platform Dependencies（属 Renderer，不属 platform-api）
P-008 ImageDecoder、P-009 GLES(native)、P-010 Canvas、P-022 Display(部分)。
owner：`ohrengine-render`（backend）。Engine 只见 `render/spi`。

## 7. Format Platform Dependencies（Format 真正需要）
P-001 FileSystem、P-002 Archive(zip)、P-006 TextCodec、P-007 XmlCodec、P-026 Audio(媒体叠，暂缓)。
Format 通过 `platform-api`（FileSystem/Archive）访问；XmlCodec/TextCodec 为 Format 内部依赖（JDK/ArkTS 运行时）。

## 8. Keep / Defer / Drop（裁决表）

| 候选（上一轮 10 项） | 裁决 | 优先级 | 理由 |
|---|---|---|---|
| FileSystem | **KEEP** | P0 | 真实调用点 ~35，engine/format/render/app 全需 |
| Storage | **DROP**（拆分） | — | 含糊；路径并入 FileSystem，Preferences/DB 归 App |
| FontProvider | **KEEP** | P1 | `OhEngineCore.font` + `FontLoader` 真实使用；跨平台字体加载差异 |
| ImageDecoder | **KEEP 但归 Renderer** | P1 | 消费者全是 render backend（ImageRenderer/PageRenderer/OhGlass） |
| TextShaper | **DEFER** | P2 | 无真实 OS shaping 调用（`TextBreaker` 用系数估算，见 §"文本系统"） |
| TextMeasurer | **DEFER** | P2 | 当前不调 OS 测量（系数估算），无替换需求 |
| TaskScheduler | **KEEP** | P0 | `taskpool` 两处真实使用 |
| MemoryManager | **DROP** | — | 无跨平台 MemoryManager 需求；仅"内存压力信号"(P-013)与引擎内配额 |
| Logger | **KEEP** | P1 | `hilog` 全栈使用 |
| Clock | **DEFER** | P2 | 仅用 `Date.now()`（JS 内建，非 OS 差异） |

> **最终 Engine-facing SPI = 5 项**：FileSystem(P0)、TaskScheduler(P0)、Logger(P1)、FontProvider(P1)、Archive(P1)。
> 文本系统（§6）：`line breaking/justification/pagination`（`TextBreaker/JustifyEngine/PageSplitter`）**属 Engine**；`font discovery/loading/shaping/measurement` **属 Platform**——但当前仅 `font discovery+loading` 有真实调用点（`FontLoader`），`shaping/measurement` 无调用点 ⇒ **DEFER**。
