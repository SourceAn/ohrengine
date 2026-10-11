# PLATFORM_SPI_PROPOSAL — 最小 Platform SPI 设计（不实现）

> 生成：2026-10-11 ｜ 依据 `PLATFORM_CAPABILITY_INVENTORY.md`（真实调用点）。**本轮不创建 HAR、不实现接口、不改产品代码。**
> 原则：**Minimum Sufficient Interface**（§16）——只抽有真实调用点、明确消费者、可替换价值的缝。

## 1. Final SPI Set

| Priority | SPI | Owner HAR | 真实调用点 | 消费者 |
|---|---|---|---|---|
| **P0** | `PlatformFileSystem` | `platform-api` | `common/service/*`(8)、`ui-render/*`(4)、`txt/*`(4)、reader/entry/format | engine, format, render, app |
| **P0** | `PlatformTaskScheduler` | `platform-api` | `txt/TxtIndexBuilderTask.ets:10`、`ui-render/core/PipelineManager.ets:29` | engine(layout), format(txt) |
| **P1** | `PlatformLogger` | `platform-api` | 全模块 `hilog`（engine 4 + format 3 + …） | engine, format, render |
| **P1** | `PlatformFontProvider` | `platform-api` | `ui-render/OhEngineCore.ets:30`(`font`)、`common|ui-render FontLoader` | engine(text) |
| **P1** | `PlatformArchive` | `platform-api` | `common/SecureArchive.ets:18`、`pdf/PdfParser.ets:24` | format(epub/cbz/pdf) |
| **P2** | `PlatformClock` | `platform-api` | `Date.now()`（JS 内建） | （暂不必要） |
| **P2** | `PlatformMemoryPressure` | `platform-api` | `EntryAbility.onMemoryLevel→MemoryHub` | engine(可选) |
| **P2** | `Renderer.ImageDecoder` | **`render`**（非 platform-api） | `ImageRenderer.ets:13`、`PageRenderer.ets:7`、`OhGlass.ets:56` | render backend |
| **DROP** | `Storage`/`MemoryManager`/`TextShaper`/`TextMeasurer` | — | 无真实替换需求（见 §7） | — |
| **DROP** | `Canvas`/`GLES`/`Window`/`Battery`/`Sensor`/`Display`/`Preferences`/`Database`/`Clipboard`/`Network`/`TTS`/`Translation`/`FilePicker` | — | 属 **Renderer** 或 **Application** | — |

> **Engine-facing `platform-api` = 5 接口**（P0×2 + P1×3）；P2 为可选；Renderer/App 能力**不进** platform-api。

## 2. SPI Ownership

| 层/HAR | 拥有 |
|---|---|
| `platform-api` | FileSystem, TaskScheduler, Logger, FontProvider, Archive（+可选 Clock, MemoryPressure） |
| `engine` | Format SPI（`BookParser`）、Renderer SPI、Document/Layout/Page/Cache 类型 |
| `render` | ImageDecoder、Canvas backend、GLES backend、RenderSurface（消费 Page/RenderModel） |
| `format` | XML/TextCodec 内部依赖、SecureArchive 的 **安全策略**（路径/符号链接/上限） |
| `platform-harmony` | `@kit.*` 的真实实现（唯一 OS 落点） |
| `app` | Window/Display/Battery/Vibrator/Preferences/DB/Clipboard/Network/TTS/Translation/FilePicker/UI |

## 3. Dependency Graph

```
engine ─▶ platform-api ◀─ platform-harmony ─▶ OS(@kit.*)
format ─▶ platform-api
render ─▶ platform-api   (ImageDecoder 由 render 自身拥有)
app    ─▶ engine ─▶ platform-api
```
`platform-api ⇒ (nothing)`（**不得反向依赖 engine/document**，§21）。Engine 不依赖 `platform-harmony`（只依赖 api）。

## 4. Minimal Interface Sketch（仅契约，不实现）

```
PlatformFileSystem
  Purpose: engine/format 的基础文件访问（读/写/列/stat/删除/重命名）
  Consumers: engine, format, render(读写asset)
  Implementations: platform-harmony(fileIo)
  Methods: readFile(path)/writeFile(path,bytes,atomic?)/append(path,bytes)/
           list(dir)/stat(path)/exists(path)/remove(path)/rename(src,dst)/
           mkdirs(path)/readText(path)/writeText(path,s,atomic?)
  Data: 仅 string 路径 + Uint8Array/string + 中立 FileStat{size,mtimeSec,isDir}
  Must NOT expose: Context/URI 实现/ohos.file.fs 类型

PlatformTaskScheduler
  Purpose: 把计算/IO 任务移出主线程（提交/取消/结果）
  Consumers: engine(layout), format(txt)
  Implementations: platform-harmony(taskpool)
  Methods: submit(taskRef, arg)/cancel(taskId)/（可选）submitWithPriority(ref,arg,P0..P2)
  Contract: 结果经结构化克隆返回；取消为协作式；不得泄漏 taskpool 类型

PlatformLogger
  Purpose: 结构化日志
  Methods: debug/info/warn/error(domain,tag,fmt,args)
  Must NOT expose: hilog 类型

PlatformFontProvider
  Purpose: 字体发现/加载 + 注册到渲染文本系统
  Consumers: engine(text measurement provider)
  Methods: registerFont(family, src)/loadFontBytes(family)/fallbackFor(codepoint)/
           （可选）measureText(text, style) → 暂 DEFER
  Must NOT expose: UIContext/font 类型

PlatformArchive
  Purpose: ZIP/deflate 解压（容器解码）
  Consumers: format(epub/cbz/pdf)
  Methods: unzip(archivePath, destDir)/(可选)listEntries(path)
  Contract: 安全上限（条目数/单文件/总量）交由调用方(format 策略)裁决

PlatformClock (P2)      : now():sec / monotonic():ms
PlatformMemoryPressure (P2): onPressure(cb: (level)=>void)
Renderer.ImageDecoder (render): decode(bytes) → RenderImage（中立句柄）
```

## 5. Forbidden Types（§19）

下列**绝不允许**出现在 platform-api 契约里：
`Context`、`UIAbilityContext`、`UIContext`、`PixelMap`、`BusinessError`、`Want`、`AbilityConstant`、`ArkUI 任意组件/Attribute`、`hilog`、`taskpool`、`fileIo`、`zlib`、`image`、`preferences`、`relationalStore`、`window/display`、GLES 对象、Harmony 枚举。
一律转换为 **Engine-neutral** 值类型（`string`/`number`/`Uint8Array`/`{size,mtimeSec,isDir}`/自定义 enum）。

## 6. Thread / Lifecycle Contract（§20，只记录）

| SPI | async/sync | 取消 | 线程 | 生命周期 |
|---|---|---|---|---|
| FileSystem | 允许双形态；热路径 `statSync/readSync` 保留同步 | 无 | 调用方线程 | 无状态（路径驱动） |
| TaskScheduler | async（`Promise`） | 需要（协作式 `cancel(taskId)`） | 由实现建池 | 任务局部 |
| Logger | sync | 无 | 任意线程 | 无状态 |
| FontProvider | async（加载/注册） | 可选 | 主线程注册（UI 线程约束） | 进程级缓存 |
| Archive | async | 可选 | 后台线程 | 每次调用 |
| ImageDecoder | async | 可选 | 后台线程 | 句柄由 render 管理 |

## 7. Keep / Defer / Drop（上一轮 10 项逐条）

| Candidate | Decision | Priority | Reason |
|---|---|---|---|
| FileSystem | **KEEP** | P0 | ~35 真实调用点；engine/format/render/app 均需 |
| Storage | **DROP**（拆分） | — | 含糊；路径入 FileSystem，Preferences/DB 归 App |
| FontProvider | **KEEP** | P1 | `OhEngineCore.font` + `FontLoader` 真实使用 |
| ImageDecoder | **KEEP→Renderer** | P1 | 消费者全为 render backend；不进 platform-api |
| TextShaper | **DEFER** | P2 | 无 OS shaping 调用（`TextBreaker` 系数估算） |
| TextMeasurer | **DEFER** | P2 | 当前不调 OS 测量 |
| TaskScheduler | **KEEP** | P0 | `taskpool` 两处真实使用 |
| MemoryManager | **DROP** | — | 无跨平台需求；仅内存压力信号(P-013) |
| Logger | **KEEP** | P1 | `hilog` 全栈 |
| Clock | **DEFER** | P2 | 仅 `Date.now()`（JS 内建） |

## 8. Platform API Size Assessment（§26）

```
SPI count (engine-facing)     : 5  (P0×2 + P1×3)
method count (union)          : ~26
data type count               : ~4 (FileStat, LoggerArgs, TaskRef, ArchiveLimits)
consumer count                : engine, format, render
implementation count (now)    : 1 (platform-harmony)
→ Platform API size: SMALL  ✅  (未变成万能系统服务层)
```
若把 App 能力（Preferences/DB/Window/Display/Battery/Network/TTS…）或 Renderer 能力（ImageDecoder/Canvas/GLES）塞入 → 立即变为 **TOO LARGE**；本轮明确否决。

## 9. Migration Order（供 P1 参考；本轮不执行）

1. 新建 `ohrengine-platform-api`：先落 **P0**（FileSystem、TaskScheduler）。
2. 各层 `fileIo`/`taskpool` 调用点改为经 SPI（**platform-harmony 实现**）。
3. 加 **P1**（Logger、FontProvider、Archive）。
4. `ImageDecoder` 待 `ohrengine-render`(P6) 就绪后落 render。
5. P2（Clock/MemoryPressure）按需。
6. 每步跑 `check_boundaries.mjs`（目标：`INV-PLATFORM` PASS）。

## 10. P1 Readiness Verdict（§31 逐条）

| # | 条件 | 结论 |
|---|---|---|
| 1 | 每个 SPI 有真实调用点 | ✅（见 §1） |
| 2 | 每个 SPI 有明确消费者 | ✅ |
| 3 | 每个 SPI 有明确实现者 | ✅（platform-harmony） |
| 4 | SPI 不泄漏 HarmonyOS 类型 | ✅（§5 forbidden） |
| 5 | Engine 不反向依赖 platform-impl | ✅（engine→platform-api 单向） |
| 6 | Application-only 能力未被错抽 | ✅（§5 inventory：全部 DROP） |
| 7 | Renderer-only 能力未被错抽 | ✅（ImageDecoder/Canvas/GLES→render） |
| 8 | Format-only 能力未被错抽 | ✅（XmlCodec 留 format；Archive 为通用 codec） |
| 9 | MemoryManager 已裁决 | ✅ DROP |
| 10 | SecureArchive ownership 已明确 | ✅ codec→`PlatformArchive`(platform)，安全策略→`format` |
| 11 | Platform API 未变成万能 service | ✅ SMALL（§8） |
| 12 | P0/P1/P2/DROP 已明确 | ✅（§1/§7） |

### Q15：P1 执行前的遗留架构问题
- **无硬阻塞**。两项**约束**（非阻塞，须在 P1 文档中写明）：
  1. `platform-api` 只含 **engine-facing 5 项**；`ImageDecoder` 明确排除（render 拥有，P6 后落位）。
  2. `FontProvider` 必须包含 `registerFont` 钩子，以覆盖 `OhEngineCore.ets:30` 的 ArkUI `font` 用法（否则 Engine 仍泄漏 ArkUI）。

⇒ **P1 Readiness = READY（限 engine-facing 子集；ImageDecoder 明确 out-of-scope）**。
