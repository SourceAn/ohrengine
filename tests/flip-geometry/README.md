# FlipGeometry 几何算法验证

`FlipGeometry.ets`（entry/src/main/ets/reader/）是 STPageFlip（Nodlik/StPageFlip，MIT）翻页几何算法的 ArkTS 移植。
本目录提供桌面回归验证，确保移植与原版逐位一致。

## 文件

| 文件 | 说明 |
|------|------|
| `orig/helper.ts` + `orig/flipcalc.ts` | STPageFlip 原版源码（`src/Helper.ts` + `src/Flip/FlipCalculation.ts`，仅剔除 DOM 依赖） |
| `orig-out/` | esbuild 转译产物（`npx esbuild orig/*.ts --outdir=orig-out --format=cjs --platform=node`） |
| `flip-algo.mjs` | 本项目的移植算法（JS 镜像，与 ArkTS 版逐行一致） |
| `compare.mjs` | 逐输入对照测试：同一批触摸点同时喂给原版与移植，比对 angle / progress / pos / rect / 裁剪多边形 / 阴影角 |

## 运行

```bash
cd tests/flip-geometry
node compare.mjs
```

## 已知差异（有意为之）

原版 `GetIntersectBeetwenTwoLine` 对"重合线段"（如页面矩形边与书脊边界重合）抛出
`Segment included` 异常 → `calc()` 返回 false（页面停在上一帧）。移植版返回 `null`
交点，`calc()` 继续成功且裁剪多边形退化为零宽条带（不可见）——对"动画终点页面完全
翻出"的场景更干净，视觉上无残留。

## 单页适配说明

原版面向双页展开书（书本宽 = 2×页宽，触摸点经 `convertToPage` 映射到活动页局部坐标）。
本项目单页模式下"书本区域 = 内容区"，因此：

- 活动页局部坐标 = 内容区坐标（原点内容区左上角）；
- BACK（上一页）方向触摸点做**水平镜像**（`lx = contentWidth - rawX`），保持
  "向右拖 = 翻页进度增大"的拖拽语义（原版由 convertToPage 的镜像公式完成）；
- 动画终点 Y 固定为页角边缘（0 或 contentHeight，同原版 `stopMove`），保证终点帧
  页面完全翻出/平整。
