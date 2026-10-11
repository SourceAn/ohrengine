# MODULE_TOPOLOGY — OHR 最终 HAR / 模块物理拓扑

> 生成：2026-10-11 ｜ 方式：实际扫描 `module.json5` / `build-profile.json5` / `oh-package.json5` / `index.ets` / 跨模块 import（脚本：`tests/architecture/check_boundaries.mjs`）。
> 承接上一轮逻辑架构（`docs/architecture/*`）。**本轮只设计与验证，不修改产品代码、不移动、不新建 HAR。**
> 核心原则：**Logical Boundary ≠ Physical HAR Boundary**。

## 1. 当前 HAR topology

`build-profile.json5` 注册 10 个模块；9 个 `type: har` + `entry`（`type: entry`）：

```
ohrengine-common           (har)   34 ets   依赖: 无
ohrengine-parsers          (har)    3 ets   依赖: common
ohrengine-epub             (har)    8 ets   依赖: common
ohrengine-txt-exclusive    (har)   12 ets   依赖: common
ohrengine-cbz-exclusive    (har)    1 ets   依赖: common
ohrengine-pdf-exclusive    (har)    4 ets   依赖: common
ohrengine-feature          (har)   15 ets   依赖: common
ohrengine-ui-render        (har)   31 ets   依赖: common, feature, parsers
ohrengine-reader           (har)   38 ets   依赖: common, ui-render, feature, epub, txt-exclusive  (+ libliquidglass.so 原生)
entry                      (entry) 15+ ets 依赖: 全部
```

实测模块依赖边（无环）：
```
cbz → common ; epub → common ; txt → common ; pdf → common ; parsers → common ; feature → common
ui-render → common, feature, parsers
reader    → ui-render, common, feature
entry     → common, epub, txt, cbz, pdf, ui-render, reader, feature
```

## 2. 当前各 HAR 职责 / 问题

| HAR | 名义职责 | 实际问题 |
|---|---|---|
| `common` | "基础" | **catch-all**：模型 + 缓存(PageCache/ParseCache) + 解压(SecureArchive) + 配额 + 阅读状态；直接 `@kit.*`（8 文件） |
| `ui-render` | "UI 渲染" | **名不副实**：实为 Engine Core（open 管线/分页/布局/CSS/页模型/导航）+ feature 依赖 + ArkUI |
| `reader` | "阅读器" | **混合**：Engine 宿主 + 面板 UI + Canvas 渲染 + GLES + 平台(电池/传感器) + ParseCache 泄漏 |
| `feature` | "特性" | 阅读语义(批注/书签/搜索/选词) 与 应用能力(词典/TTS/生词本/历史/主题) 混；被 Engine 依赖 |
| `parsers` | HTML/CSS | 清晰（无 `@kit`），但归 `style`/`document` 更准 |
| `epub`/`txt`/`cbz`/`pdf` | 格式适配 | 方向对；但 txt 带 taskpool、pdf 带 renderer/router（越层） |

`check_boundaries.mjs` 当前：**INV-PLATFORM / INV-UI / INV-RENDER-FORMAT FAIL**（`common`+`ui-render` 直接 `@kit.*`；`OhEngineCore` 用 ArkUI；`ReaderHost` 触 ParseCache）。

## 3. 三个候选方案

### Candidate A — Minimal Modules（~4）
```
ohrengine-api · ohrengine-engine(含 document/layout/cache/render) · ohrengine-format(全格式) · ohrengine-platform-harmony · entry
```
- ✅ 最少模块、构建最快、装配最简。
- ❌ `engine` 会把 `@kit.*`(文件/图片/线程) 与 Renderer 一起吸入 ⇒ **无法达成 I2/I3（Engine 不依赖 ArkUI/GLES）**；格式与 renderer 无法独立替换；`common` 问题被换名继承。

### Candidate B — Balanced Modules（~6）**← 推荐**
```
ohrengine-platform-api · ohrengine-engine · ohrengine-format · ohrengine-render · ohrengine-platform-harmony · ohrengine-app · entry
```
- ✅ 三缝（Platform/Render/Format）物理可换；Engine 只依赖 `platform-api`；模块数少（6+1）。
- ⚠️ `engine` HAR 较大（core 全部逻辑包），但**逻辑包**内部再分包（`document/layout/...`）。

### Candidate C — Maximum Isolation（~15）
```
api · document · layout · pagination · cache · format-spi · epub · txt · pdf · cbz · render-api · render-canvas · render-gles · platform-api · platform-harmony · entry
```
- ✅ 边界最硬、测试隔离最好。
- ❌ **过度碎片化**：大量 HAR 间接口依赖、构建/装配成本高、易出现"1–2 个类一个 HAR"、版本管理负担；与任务 §4/§28（不为架构而拆）冲突。

## 4. 候选对比

| Dimension | A(Minimal) | B(Balanced) | C(Isolation) |
|---|---|---|---|
| HAR 数 | 4 | **6** | ~15 |
| 耦合 | 高（engine 吸一切） | 中 | 低 |
| 构建复杂度 | 最低 | 低 | 高 |
| 跨平台 | 差（engine 绑 OS） | **好** | 最好 |
| API 稳定性 | 差（engine 巨变） | **好** | 好 |
| 扩展性（新格式/Renderer/Platform） | 差 | **好** | 最好 |
| 维护成本 | 低但易腐化 | **平衡** | 高 |

## 5. 推荐方案（Final Recommendation）

> **Recommended: 6 HAR + 1 entry**
> `ohrengine-platform-api` · `ohrengine-engine` · `ohrengine-format` · `ohrengine-render` · `ohrengine-platform-harmony` · `ohrengine-app` · `entry`

**为什么选 B**：在"跨平台可替换"与"不过度碎片化"之间取平衡；仅把**存在真实替换需求**的缝物理隔离（Platform impl、Renderer backend、Format adapter、Application），其余（document/style/layout/pagination/cache/search）保留在 `ohrengine-engine` 的**逻辑包**内。
**为什么不选 A**：会把 Platform/Renderer 吸进 Engine，违背 I2/I3/I12，跨平台目标破产。
**为什么不选 C**：碎片化、构建/装配成本、单类 HAR、版本管理负担（任务 §4/§28 明令避免）。

### 5.1 最终 HAR topology

```
ohrengine-platform-api      (har)  纯接口(SPI)，无 @kit
ohrengine-engine            (har)  Engine Core + Document + Style/Layout/Pagination/Page + Locator/Navigation/Search/Annotation + Format SPI + Renderer SPI + Cache
ohrengine-format            (har)  Format Adapters: format/{epub,txt,pdf,comic}
ohrengine-render            (har)  Renderer SPI + backends/{canvas,gles,pdf}
ohrengine-platform-harmony  (har)  platform-api 的 HarmonyOS 实现
ohrengine-app               (har)  Application: ReaderHost facade + panels UI + app features(词典/TTS/生词本/历史/主题) + 装配(注册 format/render/platform)
entry                       (entry) Ability + Bookshelf
```

### 5.2 每个 HAR 的职责 / 禁止职责 / Public / Internal / 依赖

| HAR | 负责 | 禁止 | Public API | Internal | 依赖 |
|---|---|---|---|---|---|
| `platform-api` | SPI 接口：FileSystem/Storage/FontProvider/ImageDecoder/TextShaper/TextMeasurer/TaskScheduler/MemoryManager/Logger/Clock | 任何 `@kit`/OS/实现 | 全部接口 | — | 无 |
| `engine` | publication/document/locator/navigation/style/layout/pagination/page/search/annotation/cache + Format SPI(`BookParser`) + Renderer SPI(`RenderModel/Command`) | ArkUI/Canvas/GLES/`@kit`/concrete format | `api/*`(ReaderEngine/Session/Publication/Locator/ReadingState/Navigation/Bookmark/SearchResult/Page) | `document/*` `layout/*` … | platform-api |
| `format` | `External → Document`（epub/txt/pdf/comic） | Renderer/UI/`@kit` 之外的平台细节（经 platform-api） | 各 `XxxParser` | — | engine, platform-api |
| `render` | Page/Render Model → 像素（canvas/gles/pdf backend） | format/navigation/cache/EPUB 语义 | Renderer SPI + backends | — | engine, platform-api |
| `platform-harmony` | platform-api 的 HarmonyOS 实现 | 阅读语义 | （实现，供装配） | 全部 | platform-api |
| `app` | 阅读器 UI/面板/设置 + 应用特性 + **装配**（注册 format/render/platform） | 被 Engine 依赖 | UI 组件、ReaderHost facade | — | engine, format, render, platform-harmony |
| `entry` | Ability/书架/权限 | 引擎实现 | — | — | app(+engine) |

### 5.3 最终依赖方向（DAG）
```
app ─▶ engine ─▶ platform-api ◀─ platform-harmony
 │        ▲
 ├─▶ format ─┘        (format → engine, platform-api)
 ├─▶ render ─┘        (render → engine, platform-api)
 └─▶ platform-harmony
entry ─▶ app
```
无环；Engine 只依赖 `platform-api`；`platform-harmony` 是**唯一**可直接依赖 HarmonyOS API 的 HAR（I12）。

### 5.4 为什么这样拆 / 为什么不继续拆 / 为什么不合并

- **拆（物理 HAR）仅限四处**：`platform-api`（跨平台 SPI）、`platform-harmony`（唯一 OS 实现）、`render`（可替换后端）、`format`（可增格式）；`app` 与 `engine` 分开（Application↔Engine 解耦）。
- **不再拆**：`document/style/layout/pagination/page/cache/search/annotation` 是**逻辑包**（package），共享 `ohrengine-engine` HAR。它们之间是**编译期强耦合的阅读管线**，拆成 HAR 只会制造跨 HAR 接口债（Candidate C 问题）。判据：无独立发布/独立平台实现/独立替换需求 ⇒ 不拆。
- **不合并**：Engine 不能吞 Renderer（否则 I3 破）；不能吞 Format（否则 I4 破）；不能吞 Platform（否则 I12 破）；Application 不能并入 Engine（否则 I1/I5 破）。

### 5.5 Logical ↔ Physical 双层结构

```
PHYSICAL (HAR)                          LOGICAL (package)
ohrengine-engine/       src/main/ets/  ├── api/           (ReaderEngine, ReaderSession, Locator…)
                                        ├── publication/
                                        ├── document/
                                        ├── locator/ navigation/
                                        ├── style/ layout/ pagination/ page/
                                        ├── search/ annotation/
                                        ├── cache/{document,layout,page,asset,lifecycle}/
                                        └── spi/{format,render}/     (BookParser / RenderModel)
ohrengine-format/       src/main/ets/  ├── spi/ (re-export from engine) ├── epub/ ├── txt/ ├── pdf/ ├── comic/
ohrengine-render/       src/main/ets/  ├── api/ ├── model/ └── backend/{canvas,gles,pdf}/
ohrengine-platform-api/ src/main/ets/  └── (interfaces only)
ohrengine-platform-harmony/ src/main/ets/ └── (impl only)
ohrengine-app/          src/main/ets/  └── ui/ features/ assembly/
```

### 5.6 跨平台扩展
```
platform-api ◀─ platform-harmony | platform-ios | platform-android | platform-desktop
render       ◀─ backend/{canvas,gles,skia,native}
format       ◀─ epub|txt|pdf|comic|markdown|mobi|azw
```
只新增实现 HAR，**不改** engine/document/layout。
