# DEPENDENCY_RULES — 允许 / 禁止依赖（可执行）

> 生成：2026-10-11 ｜ 规则由 `tests/architecture/check_boundaries.mjs` **实际执行**（扫描 204 个 `.ets`）。
> 本文件取代旧 `DEPENDENCY_GRAPH.md`。

## 1. 依赖方向（允许）

```
application ──▶ api(ReaderEngine) ──▶ engine ──▶ platform-api ──▶ platform-impl(harmony) ──▶ OS
                                        ▲
                                        │ (engine 只经 SPI)
                    format-adapter ─────┘   format-adapter ──▶ engine/document(IR)
                    render/backend  ◀─────  engine(page model)    (Renderer 只消费 Page Model)
```

允许的边：
- `application → api / engine / format(注册)`。
- `api → engine`。
- `engine → document / format-spi / platform-api / cache(接口)`。
- `format/* → format-spi + document(IR) + platform-api`。
- `render/backend → render/api`（只消费 Page/Render Model）。
- `platform/harmony → platform/api`（+ OS 能力）。
- `cache/* → platform-api`（不得直接 `@kit.*`）。

## 2. 禁止依赖（硬性）

```
engine ✗─▶ @kit.* / ArkUI / Canvas / GLES / Ability / HiLog        (Rule 3.1)
document ✗─▶ layout / pageIndex / viewport / canvas / GL           (Rule 3.3)
layout ✗─▶ format-adapter / EPUB / OPF / ZIP                       (Rule 3.2, I2)
render ✗─▶ format / navigation / parse-cache / engine             (Rule 3.5)
pageIndex ✗─ 作为 canonical identity（须用 Locator）                (Rule 3.4)
application 逻辑 ✗─▶ core engine                                   (Rule 3.1 / I5)
common ✗─ 作为跨层收容所                                            (任务 §P3)
```

## 3. API / SPI / Implementation 三层辨识度

**只有存在可替换实现处才引入 SPI**（任务 §12）。目标：

| 类别 | 位置 | 举例 |
|---|---|---|
| Public API | `api/` | ReaderEngine, ReaderSession, Publication, Locator |
| Format SPI | `format/spi/` | `BookParser`（现 `common/parser/ParserRegistry.ets:121`）|
| Platform SPI | `platform/api/` | `PlatformFileSystem/FontProvider/ImageDecoder/TextShaper/TextMeasurer/TaskScheduler/MemoryManager/Logger/Clock` |
| Renderer SPI | `render/api/` | Renderer Backend / Render Model（现 `StrategyRouter` `common/parser/StrategyRegistry.ets:30`）|
| Implementation | `format/{epub,txt,…}` `platform/harmony/` `render/backend/*` | — |

> 现状：Format/Render SPI **已有**（`BookParser`/`StrategyRouter`）；Platform SPI **完全缺失**（各层直接 `@kit.*`）。

## 4. 可执行检查结果（当前态，`node tests/architecture/check_boundaries.mjs`）

```
=== OHR architecture boundary check ===
scanned 204 .ets files

[FAIL] INV-PLATFORM — Engine(ui-render/common) 不得 import @kit.*
        ohrengine-common/src/main/ets/font/FontLoader.ets:18
        ohrengine-common/src/main/ets/service/CacheMigration.ets:15
        ohrengine-common/src/main/ets/service/DiskCacheQuotaManager.ets:13
        ohrengine-common/src/main/ets/service/ImportCheckpoint.ets:12
        ohrengine-common/src/main/ets/service/PageCacheManager.ets:23
        ohrengine-common/src/main/ets/service/ParseCacheManager.ets:19
        ohrengine-common/src/main/ets/service/ReadingStateStore.ets:15
        ohrengine-common/src/main/ets/service/SecureArchive.ets:17
        ohrengine-common/src/main/ets/service/SecureArchive.ets:18
        ohrengine-ui-render/src/main/ets/OhEngineCore.ets:16
        ohrengine-ui-render/src/main/ets/OhEngineCore.ets:30
        ohrengine-ui-render/src/main/ets/OhEngineCore.ets:31
        … (+10 more)
[FAIL] INV-UI — Engine(ui-render/common) 不得 import @kit.ArkUI 或声明 @Component/@Entry
        ohrengine-ui-render/src/main/ets/OhEngineCore.ets:30
[PASS] INV-FORMAT-IN-ENGINE — Engine 不得 import format 模块
[PASS] INV-COMMON-LEAF — ohrengine-common 不得 import 其它 ohrengine-* 模块
[PASS] INV-RENDERER — Renderer(reader/reader,reader/glass) 不得 import format/ParseCache/Navigation

=== generic-name directories (target: 0) : 9 ===
   ohrengine-common/src/main/ets/model
   ohrengine-common/src/main/ets/service
   ohrengine-common/src/main/ets/types
   ohrengine-epub/src/main/ets/model
   ohrengine-feature/src/main/ets/model
   ohrengine-reader/src/main/ets/common
   ohrengine-reader/src/main/ets/service
   ohrengine-reader/src/main/ets/utils
   ohrengine-ui-render/src/main/ets/core

RESULT: 3/5 invariants PASS
```

**解读（事实）**：
- `INV-PLATFORM` / `INV-UI` **FAIL**：`engine` 层（`ui-render` + `common`）直接依赖 HarmonyOS/ArkUI（含 `common/service/*` 与 `OhEngineCore`）。这是跨平台目标的**头号障碍**。
- `INV-FORMAT-IN-ENGINE` **PASS**：`ui-render`/`common` 不直接 import `epub/txt/pdf/cbz`（模块级格式缝已成立）。
- `INV-COMMON-LEAF` **PASS**：`common` 无工程内依赖（DAG 叶子）。
- `INV-RENDERER` **PASS**：`reader/reader`、`reader/glass` 未直接 import 格式/ParseCache/Navigation。

## 5. 依赖图实况（模块级，实测）

```
entry  ─▶ reader, ui-render, feature, parsers, common, epub, txt-exclusive, cbz, pdf
reader ─▶ ui-render, feature, epub, txt-exclusive, common   (+ libliquidglass.so)
ui-render ─▶ feature, parsers, common
feature  ─▶ common        epub ─▶ common     txt ─▶ common
cbz ─▶ common             pdf ─▶ common      parsers ─▶ common
common ─▶ （无）
```
- **环**：0（DAG 成立）。
- **上行依赖（Application/Engine 混入）**：`ui-render`(Engine) → `feature`(App/Feature)。
- **平台 API 进入基础层**：`common/*` 直接 `@kit.*`（8 文件）。

## 6. 迁移期使用方式

- 新增/改动代码时运行 `node tests/architecture/check_boundaries.mjs`。
- 迁移期允许 FAIL（作为"当前状态"证据）；每个 Phase 收敛一条规则：
  - Phase 1/7 收敛 `INV-PLATFORM`、`INV-UI`。
  - Phase 2 收敛 generic-dir 计数。
- 目标：终态 **5/5 PASS + generic=0**。
