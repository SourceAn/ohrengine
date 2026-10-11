# REFACTOR_RESULT — Reading Pipeline 结构重构结果

> 生成：2026-10-11 ｜ 本轮为 **Structural Refactor**（行为不变）。已执行分阶段迁移并逐步验证。

## 1. Before
```
ohrengine-common/src/main/ets/     controller/ font/ model/ parser/ service/ types/
ohrengine-ui-render/src/main/ets/  core/ layout/(23) render/ router/  OhEngine.ets OhEngineCore.ets
（其余 HAR 未动）
```

## 2. After
```
ohrengine-common/src/main/ets/     document/ typography/ cache/ storage/ spi/ runtime/ types/
ohrengine-ui-render/src/main/ets/  style/ typography/ layout/(13) core/ render/ router/  OhEngine.ets OhEngineCore.ets
（其余 HAR 未动）
```
泛名目录：**9 → 7**。

## 3. Files moved
见 `FILE_OWNERSHIP_MATRIX.md §1/§2`（共 **34 个文件**：`common` 24 + `ui-render` 10）。要点：
- `common`: `model→document`(6)、`font→typography`(3)+`controller/FontSizeController→typography`(1)、`parser→spi`(2)、`service→cache`(6)/`storage`(2)/`runtime`(4)。
- `ui-render`: `layout→style`(6)/`typography`(4)；`layout` 保留 13。
- 同步更新 `common/index.ets`、`ui-render/index.ets` 的 export 路径；`common`/`ui-render`/`types` 内部相对 import（`../model`, `../font`, `../parser`, `./X`）已重写。

## 4. Files split
**本轮未拆分巨型类**（`PageManager`/`PipelineManager`/`OhEngineCore`/`ReaderHost`/`OhEngine`）。原因：拆分会改变内部结构，风险高，按任务“分阶段 + 每阶段可构建”原则推迟至 P3。→ **deferred**。

## 5. Files merged
无（本轮只做归属迁移，不做职责合并）。

## 6. Deleted / Legacy
- 删除（清空后）：`common/{controller,font,model,parser,service}` 5 个旧目录（内容已迁走，非丢失）。
- 无孤儿文件；无 `misc/unknown/temp`。
- Legacy（既有，未动）：`archive/legacy-pageflip/*`、`docs/ai/legacy_pageflip_inventory.md`。
- 兼容：`index.ets` 公共符号名不变 ⇒ **无需 facade**（消费方仍 `import ... from 'ohrengine-common'/'ohrengine-ui-render'`）。

## 7. Feature Status
见 `FEATURE_IMPLEMENTATION_MATRIX.md`。摘要：EPUB/TXT/CBZ/HTML/CSS/Style/Typography/Layout/Pagination/Cache/Annotation/Bookmark/Selection/Theme/Navigation/ReadingState = IMPLEMENTED；PDF/Search/Vocabulary/Dictionary/TTS/AssetCache/Renderer(PDF) = PARTIAL；DocumentIR/Platform SPI/Translation/MediaOverlay = PLANNED（未伪装为已实现）。

## 8. Architecture violations remaining（本轮未处理）
| # | 违规 | 证据（`check_boundaries.mjs`） | 计划 |
|---|---|---|---|
| V1 | **Engine → HarmonyOS**（`@kit.*`） | `INV-PLATFORM` FAIL：`common/cache/*`(5)、`common/runtime/ReadingStateStore`、`common/storage/SecureArchive`、`common/typography/FontLoader`、`ui-render/OhEngineCore` … (+12) | P1 Platform SPI |
| V2 | **Engine → ArkUI** | `INV-UI` FAIL：`ui-render/OhEngineCore.ets:30`(`font`) | P1 FontProvider |
| V3 | **Renderer(reader) → Cache/Format** | `INV-RENDER-FORMAT` FAIL：`reader/ReaderHost.ets:22,676,693`(ParseCacheManager) | P3/P6 |
| — | Format → Renderer | 无（PASS） | — |
| — | 模块环 | 无（`INV-CYCLES` PASS） | — |

> 注：V1–V3 均为**本轮之前既有**的违规，重构未新增、未修复（属后续 P1/P3/P6）。

## 9. Verification（实际执行）
| 项 | 命令 | 结果 |
|---|---|---|
| ArkTS 全量构建 | `hvigor assembleHap -p product=default` | ✅ BUILD SUCCESSFUL |
| 测试 HAP 构建 | `hvigor assembleHap -p module=entry@ohosTest` | ✅ BUILD SUCCESSFUL |
| 单测回归（真机） | `aa test … -s class {TxtLazy,PageCacheManager,ReadingState,VChapter,Phase7,PageGeneration,TxtLibrary}Test` | ✅ 与重构前**逐项一致**：`PageCacheManager 8/8`、`ReadingState 8/8`、`VChapter 6/6`、`TxtLibrary 6/6`；`TxtLazy 3 Error`、`Phase7 1 Fail`、`PageGeneration 1 Fail`（**均为重构前已存在的既有失败**，非本轮引入） |
| 架构检查 | `node tests/architecture/check_boundaries.mjs` | 3/6 PASS（与重构前一致：`INV-FORMAT-IN-ENGINE`/`INV-COMMON-LEAF`/`INV-CYCLES` PASS；`INV-PLATFORM`/`INV-UI`/`INV-RENDER-FORMAT` FAIL，见 §8） |
| import 完整性 | 无 stale 路径；无未解析 import（构建即验证） | ✅ |
| 循环依赖 | `INV-CYCLES` | ✅ 无环 |
