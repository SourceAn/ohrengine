# MODULES — OHR HAR / 模块清单（重构后）

> 生成：2026-10-11 ｜ 反映已完成结构。

| HAR | 类型 | 依赖 | 职责 | Pipeline 阶段 |
|---|---|---|---|---|
| `ohrengine-common` | har | 无 | Semantic model / Cache / SPI / Typography(字体) / Storage / Runtime / Types | Document·Cache·SPI·Typography |
| `ohrengine-parsers` | har | common | HTML DOM / CSS / @font-face 解析 | Style/Document parse |
| `ohrengine-epub` | har | common | EPUB 解析（OPF/NCX/nav/SMIL/封面/媒体叠） | Format Parser |
| `ohrengine-txt-exclusive` | har | common | TXT 解析 + 惰性索引 + chunk 读取 | Format Parser |
| `ohrengine-cbz-exclusive` | har | common | CBZ 图片书解析 | Format Parser |
| `ohrengine-pdf-exclusive` | har | common | PDF 解析 + 渲染路由 | Format Parser（+ Render 待分） |
| `ohrengine-feature` | har | common | 批注/书签/搜索/选词/主题/生词本/词典/TTS/历史 | Application 特性 |
| `ohrengine-ui-render` | har | common, feature, parsers | Engine：Style/Typography/Layout/Pagination/Page/Navigation + Render Model | Engine 主体 |
| `ohrengine-reader` | har | common, ui-render, feature, epub, txt, `libliquidglass.so` | 阅读器 UI + Canvas/GL Renderer + Host | Application + Renderer |
| `entry` | entry | 全部 | Ability / 书架 / 装配 | Application 入口 |

## 依赖方向（实测，无环）
```
common (叶子)
 └─ parsers / epub / txt / cbz / pdf / feature
      └─ ui-render
           └─ reader
                └─ entry
```

## Engine 内部目录（`ui-render/src/main/ets/`）
`style/`、`typography/`、`layout/`、`core/`、`render/`、`router/`。

## 基础域目录（`common/src/main/ets/`）
`document/`、`typography/`、`cache/`、`storage/`、`spi/`、`runtime/`、`types/`。

## 边界校验
`node tests/architecture/check_boundaries.mjs`（module graph / forbidden imports / cycles / generic-dir / platform-capability 报告）。
