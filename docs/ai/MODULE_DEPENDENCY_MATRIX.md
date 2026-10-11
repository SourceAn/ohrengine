# MODULE_DEPENDENCY_MATRIX — 模块依赖矩阵（当前 / 目标 / 增量）

> 生成：2026-10-11 ｜ 依据实际 import 扫描。图例：`●` 允许 ｜ `○` 仅限 Public API ｜ `△` 条件允许 ｜ `✗` 禁止 ｜ `-` 自身。

## 1. CURRENT（当前 9 HAR + entry）

| from \ to | common | parsers | epub | txt | cbz | pdf | feature | ui-render | reader | entry |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| common | - | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| parsers | ● | - | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| epub | ● | ✗ | - | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| txt | ● | ✗ | ✗ | - | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| cbz | ● | ✗ | ✗ | ✗ | - | ✗ | ✗ | ✗ | ✗ | ✗ |
| pdf | ● | ✗ | ✗ | ✗ | ✗ | - | ✗ | ✗ | ✗ | ✗ |
| feature | ● | ✗ | ✗ | ✗ | ✗ | ✗ | - | ✗ | ✗ | ✗ |
| **ui-render** | ● | ● | ✗ | ✗ | ✗ | ✗ | **●(✗目标)** | - | ✗ | ✗ |
| **reader** | ● | ✗ | ● | ● | ✗ | ✗ | ● | ● | - | ✗ |
| entry | ● | ✗ | ● | ● | ● | ● | ● | ● | ● | - |

**DELTA 违规点**：`ui-render→feature`（Engine 依赖 Feature/App）；`reader→{ePub,txt,common,feature,ui-render}`（Host 越权到 Format/Engine）；`reader→ParseCache`（经 common，见 INV-RENDER-FORMAT FAIL）。

## 2. TARGET（推荐 6 HAR + entry）

| from \ to | platform-api | engine | format | render | platform-harmony | app | entry |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| platform-api | - | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| engine | ○ | - | ✗ | ✗ | ✗ | ✗ | ✗ |
| format | ○ | ○ | - | ✗ | ✗ | ✗ | ✗ |
| render | ○ | ○ | ✗ | - | ✗ | ✗ | ✗ |
| platform-harmony | ○ | ✗ | ✗ | ✗ | - | ✗ | ✗ |
| app | ○ | ● | ● | ● | ● | - | ✗ |
| entry | ✗ | ○ | ✗ | ✗ | ✗ | ● | - |

说明：
- `○` 仅可 import 该 HAR 的 **Public API / SPI**（见 `PUBLIC_API_BOUNDARIES.md`）。
- `engine→format`/`engine→render` = ✗（Engine 不得依赖 concrete Format/Renderer，只通过 SPI + 装配注入）。
- `format→engine` = ○（依赖 engine 的 `spi/BookParser` 与 `document` 类型，非 engine 内部实现）。
- `render→engine` = ○（依赖 engine 的 Page/RenderModel 类型）。
- `app` 是**装配层**：可依赖 format/render/platform-harmony 以注册实现。

## 3. 方向语义（Allow / Forbid / Conditional）

| 边 | 判定 | 理由 |
|---|---|---|
| app → engine | ● allow | Application 可用 Engine |
| app → format/render/platform-harmony | ● allow（装配） | 注册实现，Engine 不知 Application |
| engine → platform-api | ● allow | 唯一平台入口 |
| engine → format/render | ✗ forbid | I4/I3 |
| format → engine(spi/document) | △ conditional | 仅 SPI + Document 类型 |
| format → render | ✗ forbid | I14 |
| render → engine(Page/RenderModel) | △ conditional | 仅消费 Page Model |
| render → format/navigation/cache | ✗ forbid | I8/I9 |
| render → platform-api | ● allow | ImageDecoder 等 |
| cache → platform-api | ● allow | 不直接 `@kit.*` |
| platform-harmony → OS | ● allow | **唯一**允许层（I12） |
| document → layout/viewport/font | ✗ forbid | I5/I6/I7 |
| any → app | ✗ forbid | I1 反向禁止 |

## 4. 迁移工作量估计（DELTA → TARGET）

| 当前边 | 目标 | 动作 |
|---|---|---|
| `ui-render → common,parsers,feature` | `engine → platform-api`（+ `format/render` 由 app 注入） | 拆 `ui-render`；`parsers→engine`；去掉 `feature` 依赖 |
| `reader → ui-render,common,feature,epub,txt` | `app → engine,format,render,platform-harmony` | 拆 `reader`（Host→app、PageRenderer/glass→render、format 由 app 注册） |
| `{epub,txt,cbz,pdf,parsers} → common` | `format → engine,platform-api`（parsers 入 engine） | 各格式并入 `format` HAR |
| `feature → common` | 语义入 `engine`；应用能力入 `app` | 拆 `feature` |
| `* → @kit.*` | 仅 `platform-harmony` | 抽 SPI（Phase 1） |

## 5. 验证

`node tests/architecture/check_boundaries.mjs` 输出当前 module edges + cycles（无环）+ 违规清单。目标：补齐 `engine→platform-api` 方向后，`INV-PLATFORM/INV-UI/INV-RENDER-FORMAT` 全部 PASS。
