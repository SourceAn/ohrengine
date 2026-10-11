# PUBLIC_API_BOUNDARIES — Public API / SPI / Internal / Implementation

> 生成：2026-10-11 ｜ 目标：**不是所有东西都通过 `index.ets` 暴露**；明确谁能 import 什么。

## 1. 四类可见性

| 类别 | 含义 | 谁可 import |
|---|---|---|
| **Public API** | 稳定契约，跨 HAR 使用 | Application / 其它 HAR / 第三方 |
| **SPI** | 可替换实现点的接口 | 对应实现方（format/render/platform 实现 HAR） |
| **Internal** | 同 HAR 内跨 package | 仅本 HAR 内 |
| **Implementation** | 具体实现细节 | 仅定义处 |

## 2. 各 HAR 的暴露面

### `ohrengine-platform-api`（SPI owner）
- **SPI（可被 engine/format/render/platform-harmony import）**：`PlatformFileSystem`、`PlatformStorage`、`PlatformFontProvider`、`PlatformImageDecoder`、`PlatformTextShaper`、`PlatformTextMeasurer`、`PlatformTaskScheduler`、`PlatformMemoryManager`、`PlatformLogger`、`PlatformClock`。
- Public API：无（只有 SPI + 值类型）。
- Implementation：无。

### `ohrengine-engine`（Engine + API owner）
- **Public API（Application 可用）**：`ReaderEngine`、`ReaderSession`、`Publication`、`BookSource`、`Locator`、`ReadingPosition`、`ReadingState`、`Navigation`、`Bookmark`、`SearchQuery`、`SearchResult`、`Viewport`、`ReadingStyle`、`Page`（派生）。
- **SPI（实现方可用）**：`format/spi`：`BookParser`(=DocumentBuilder)、`FormatDetector`、`ResourceResolver`；`render/spi`：`Renderer`、`RenderContext`、`RenderCommand`、`RenderSurface`。
- **Internal**：`document/*`（Node/Resource）、`style/*`、`layout/*`、`pagination/*`、`page/*`、`cache/*`（仅 engine 内与 cache 子包）。
- Implementation：各算法（TextBreaker 等）为 Internal。

### `ohrengine-format`（Format SPI impl）
- **Public（供装配注册）**：`EpubParser`、`TxtParser`、`PdfParser`、`CbzParser`、`FormatDetector` 实现。
- **可 import**：engine 的 `format/spi` + `document` 类型；platform-api。
- **禁止**：renderer、UI、`@kit` 之外的越界。

### `ohrengine-render`（Renderer SPI impl）
- **Public**：`CanvasRenderer`、`GlesRenderer`、`PdfRenderer`（backend）。
- **SPI 实现**：engine 的 `render/spi`（`Renderer`）。
- **可 import**：engine 的 `page`/`render model` 类型；platform-api（ImageDecoder）。
- **禁止**：format、navigation、cache、EPUB 语义。

### `ohrengine-platform-harmony`
- **Public**：工厂（`createHarmonyPlatform(): PlatformBundle`）供 app 装配。
- **SPI 实现**：platform-api 全部接口（`@kit.*` 只在此）。
- **禁止**：阅读语义。

### `ohrengine-app`
- **Public**：`ReaderHost`（compat facade）、UI 组件、`AppAssembly`（注册 format/render/platform）。
- **可 import**：engine Public API、format/render/platform-harmony（装配）。
- **禁止**：被 engine import。

### `entry`
- **Public**：无（HAP 根）。**可 import**：app（+engine Public API）。

## 3. 允许 import 矩阵（谁 → 谁的可见面）

```
Application  可 import:  engine(Public API) + format/render/platform-harmony(装配)
Engine       可 import:  platform-api(SPI) ｜ 禁止: app/format-concrete/render-concrete/ArkUI/GLES/@kit
Format impl  可 import:  engine(SPI+document) + platform-api ｜ 禁止: render/UI
Render impl  可 import:  engine(Page/RenderModel) + platform-api ｜ 禁止: format/navigation/cache
Platform impl可 import:  platform-api(SPI) + OS(@kit) ｜ 禁止: engine/document
```

## 4. SPI 依赖方向裁决（任务 §7）

- **Format SPI 归属**：`BookParser` 等 SPI **属 `ohrengine-engine`（`format/spi` package）**，不单独建 HAR（无独立发布/替换需求，避免接口债）。方向：`Format Adapter → Format SPI → Document IR`。**SPI 参考 Document IR 类型**（IR 定义在 engine/document），**而非** IR 依赖 SPI。
- **Platform SPI 归属**：独立 `ohrengine-platform-api` HAR（存在真实替换需求：未来 iOS/Android/Desktop 实现）。
- **Renderer API 归属**：SPI 在 `ohrengine-engine`（`render/spi`）；backends 在 `ohrengine-render`。
- **PDF Renderer 归属裁决**：**属 `ohrengine-render/backend/pdf`，不属 `format/pdf`**。理由：Renderer 只消费 Page/Render Model；PDF 的“固定页”语义由 `format/pdf` 产出的 Document 表达，绘制归 Renderer（I3/I14）。现状 `pdf-exclusive/PdfRenderer` 放错层。

## 5. 反模式（禁止）

- 用单个 `index.ets` 把 Internal/Implementation 全量 re-export。
- 用 `export *` 掩盖边界。
- Application import engine 的 `layout/*`、`cache/*`（Internal）。
- 用动态 `import()` 绕过静态边界检查。
