# ohrengine-pageflip 仿真翻页引擎完善说明

> 状态：2026-08-12。在既有 StPageFlip 1:1 移植（P0–P5）基础上完成的"完善层"：
> 页背纹理、上下角翻页、BACK 方向镜像修正、速度+进度联合完成判定、P50/P95/P99
> 统计、尺寸/可见性/密度变化处理、引擎级单测与几何边界单测。
> 不引入 ReaderKit，不新建独立翻页组件，几何核心仍为 FlipCalculation（1:1 移植语义不变）。

---

## 1. 关键算法说明

### 1.1 页背纹理（正面/背面内容正确）

翻起页（flipping page）在折叠过中点后，读者看到的是纸张背面，而 1:1 移植的
`ImagePage.draw` 只画正面图（StPageFlip 官方对 ImagePage 也不画背）。本层在
`FlipRenderer.drawFlippingPage` 加入背纹理：

```
progress > FLIP_DEFAULTS.backSideProgressThreshold (默认 50)  → 画背面纹理
progress ≤ 阈值                                            → 画正面纹理
```

- 背图 = 目标方向相邻页（FORWARD → 下一页，BACK → 上一页），由 Engine 在
  `renderFrame` 传入（`flippingBackPage`）。
- 背图绘制：`translate(anchor) → rotate(angle) → scale(-1, 1) → drawImage(back, -W, 0, W, H)`。
  水平镜像 = 物理纸张翻面后内容左右颠倒，镜像后为正确读向；占用与正面相同的物理区域。
- 背图未就绪时回退正面占位，不整帧 return（与既有底页降级语义一致，不产生白屏）。
- 阈值选取依据：progress 从 0（页平铺当前页，正面朝上）单调增长到 100（页落在另一侧，
  背面朝上）；越过中点后页开始"落地"，背面朝向读者。25%/50% 姿态与 P2 视觉基准
  （正面对照）保持一致，75%/终态为背面（符合真实书页语义）。

### 1.2 翻起页旋转中心修正（BOTTOM 角）

1:1 移植版 `drawFlippingPage` 用 `state.pageRect.topLeft` 作旋转中心，但 StPageFlip
语义的旋转中心是**活动角触点 position**：TOP 角时 position == topLeft，BOTTOM 角时
position == bottomLeft。旧实现 BOTTOM 角卷曲旋转中心错位（上下角视觉效果不对称）。
`FlipState` 新增 `position` 字段（`FlipCalculation.getPosition()` 聚合），渲染器改用
`toGlobal(state.position)` 作为旋转锚点。

### 1.3 BACK 方向镜像（左右方向翻页）

单页阅读器下，BACK 翻页（返回上一页）应从屏幕左缘起手、向右拖拽。旧实现
`normalizeX` 恒等（无镜像），导致 BACK 拖拽 progress 单调**递减**、永远回弹。
本层修正：

```
normalizeX(x, BACK)  = pageWidth − x        // 屏幕左缘(=0) ↔ 页外缘(=W)
normalizeX(x, FORWARD) = x                  // 屏幕右缘(=W) ↔ 页外缘(=W)
```

方向判定在 beginDrag 用**原始触点 x**：右半区 → FORWARD，左半区 → BACK（D5 镜像
只在 Engine 边界一次完成）。修复后左缘拖拽 progress 随位移单调递增，可正常完成翻页。

### 1.4 上下角翻页

beginDrag 按触点 y 锁定活动角（拖拽期不变）：

```
canonicalY ≤ pageHeight × FLIP_DEFAULTS.cornerThresholdRatio(0.5) → TOP 角
否则                                                                 → BOTTOM 角
```

旧实现 `lockGesture` 强制 `dragCorner = TOP`，下角起手永远走 TOP 几何。收尾目标
`toY` 已按角对齐页边线（TOP→0 / BOTTOM→pageHeight），角判定接线后上下角翻页对称。

### 1.5 松手完成判定（进度 + 速度）

旧实现只按 progress ≥ 45 判定。本层新增有向速度（canonical velocityX，px/ms，
负 = 向完成方向移动）联合判定，纯函数 `PageFlipEngine.decideFlipOutcome`：

```
progress ≥ completeProgressThreshold(45)                          → 完成
或 (velocityX ≤ −completeVelocityThreshold(0.8) 且 progress ≥ 15) → 完成（甩动）
其余                                                                → 回弹
```

- 速度路径带最低进度门槛：刚起手就甩动（progress < 15）不翻页，防止误翻。
- 收尾动画传入**有向**速度：complete 时负速度加速向完成点推进；rebound 时产生
  "惯性再回弹"（先沿拖拽方向冲一小段再被临界阻尼弹簧拉回）。旧实现传速度模值，
  complete 时反而被速度推离目标点（方向反了）。
- 速度估算：最近 5 触点环形缓冲，`(canonicalX − lastX)/dt`，单调时钟。

### 1.6 松手收尾曲线

沿用临界阻尼弹簧（ζ=1）`x(t) = 1 − (1+ωt)e^{−ωt}`，时长按剩余距离与末速度
clamp 至 [220, 450]ms。改动点为：速度贡献项 `vx·duration·(1−t)·0.5` 使用有向
velocityX（修复 1.5 方向问题）。

### 1.7 性能统计扩展（P50/P95/P99）

`FlipRenderer` 新增 `getPercentiles()`（`FlipPercentiles`）与纯函数 `computePercentiles`：
- 口径一（帧间隔）：displaySync `IntervalInfo.timestamp` 相邻差值。
- 口径二（JS 提交耗时）：`systemDateTime.getTime(true)` 包裹 `renderFrame`。
- 分位定义：`sorted[floor(n·p)]`；空样本返回 0。渲染耗时与帧间隔各出 P50/P95/P99/max。

热路径零分配保持：toGlobal 复用单点对象、FlipRenderContext 复用、帧级 opacity 字符串
缓存、书脊渐变缓存、drawImage/clip 次数仍逐帧计数（目标 PixelMap 复制次数 = 0）。

### 1.8 尺寸 / 密度 / 可见性处理（Canvas 生命周期）

`PageFlipView` 新增：
- `onAreaChange` → 重算 px（vp × density），`renderer.setSize` + `cache.setViewport` +
  `engine.setPageSize` + `refresh`（旋转/窗口/密度变化统一走此路径；Area.width 类型为
  `Length`，先 `typeof === 'number'` 判型再取数）。
- `onVisibleAreaChange([0,1])` → `renderer.setVisible`（不可见停绘，T6）。
- 既有 `aboutToAppear/aboutToDisappear`：可见置位 / detach + destroy + cache.dispose +
  renderer.release 保留。

---

## 2. 第三方参考来源与许可证说明

| 来源 | 协议 | 用途 | 移植方式 |
|------|------|------|----------|
| Nodlik/StPageFlip（master，2026-08-11 抓取） | MIT | 翻页几何模型（FlipCalculation/FlipMath）、Canvas 渲染流程（CanvasRender/ImagePage）、FLIP_DEFAULTS 初值 | 仅算法对照，逐函数按 `docs/ai/stpageflip_mapping.md` 移植，禁止整文件复制（T9）；`docs/ai/stpageflip_mapping.md`、各 `.ets` 头部均保留来源说明 |
| harism/android-pagecurl（参考） | Apache-2.0 | 页背在翻过折叠线后显示的判据参考、镜像背图思路 | 仅参考判据与思路，未复制代码 |

MIT 与 Apache-2.0 均允许派生使用；本模块仅做算法对照与必要移植，保留来源标注。

---

## 3. 性能测试结果

### 3.1 基线（P5 已入库，`docs/performance/pageflip-canvas-benchmark.md`）

- 设备：DevEco 模拟器 "Mate 70 RS"（HarmonyOS 6.1.1(24)，API 24，density≈3.5）。
- 页面：1316×2832 px 全屏 Canvas；harness 连续 20 次程序化翻页（每次 ~29 帧）。

| 指标 | 目标值 | P5 实测 | 结论 |
|------|--------|---------|------|
| JS 提交 P95 | <16ms | 1.188ms | 达标 |
| 帧间隔 P95 | <16ms | 16.120ms | ≈60fps |
| PixelMap 复制/解码/帧 | 0 | 0 | 达标 |
| IDLE 帧回调 | 0 | 0（displaySync 已 stop） | 达标 |

### 3.2 完善层实测（2026-08-12，DevEco 模拟器 Mate 70 RS，API 24，density≈3.5）

连续拖拽翻页会话实测（1336 帧，FLIP_RENDER_STATS 落盘 smoke-stats.txt）：

| 指标 | 实测 | 说明 |
|------|------|------|
| JS 提交 P50 / P95 / P99 | 0.152 / 0.501 / **1.265** ms | 远低于 16ms 预算 |
| JS 提交 max | 1.718 ms | 无 GC jank |
| 帧间隔 P50 / P95 / P99 | 15.546 / 15.549 / 15.550 ms | ≈64fps 显示节拍，无掉帧 |
| 帧间隔 max | 15.551 ms | 跨动画空窗已过滤（见 3.4） |
| avg drawImage/帧 | 2.97 | 当前页 + 底页 + 翻起页（背纹理在 progress>50 后 +1） |
| avg clip/帧 | 3.94 | 底页/翻起页/外/内阴影 |
| PixelMap 复制/帧 | **0** | 热路径无像素拷贝 |

真机交互验证（同模拟器，uinput 注入真实触摸事件）：
- 程序化翻页（下一页/上一页按钮）：页索引正确前进/后退，终帧后提交。
- FORWARD 拖拽（右→左，TOP/BOTTOM 角）：beginDrag consumed=true → 松手完成翻页。
- BACK 拖拽（左→右，镜像）：canonical 镜像生效，页正确回退。
- 上下角判定：y>H/2 起手 corner=BOTTOM（日志核验），BOTTOM 角卷曲旋转中心正确。
- 快速连续翻页 40+ 次：无崩溃、无 FATAL/JSCRASH。
- 长时间会话（~50 分钟、数百次翻页）：进程存活，VmRSS 稳定（168→201MB，含系统开销，
  无 PixelMap 泄漏）。
- 无白屏/黑屏/穿透：静态帧直绘 + 降级渲染路径未触发（页图预产命中）。

> 注：`verify_ui` 自动化工具的滑动手势在该模拟器上未触发拖拽（其注入时序与
> `uinput -g`（press≥500ms）不同）；改用 hdc uinput 直接注入真实触摸序列验证通过。

### 3.3 热路径核对（T7 零分配）

- 翻页中不重新排版：页图经 `PageContentCache` LRU（≤8 页），短边 > 视口 1.5× 时
  0.5× 降采样，放入时一次完成。
- 不每帧复制/解码 PixelMap：`drawImage` 直接引用缓存对象。
- 复用数组/点/渐变/Canvas 状态：toGlobal 单点复用、FlipRenderContext 复用、书脊渐变
  缓存、帧级 opacity 字符串。
- 每帧 save/restore 隔离（renderFrame 顶层 + 各绘制子过程）。
- 阴影仅 `createLinearGradient`，无 shadowBlur（T4）。

### 3.4 帧间隔口径修正（跨动画空窗过滤）

`setFrameTimestampNs` 原先记录任意相邻帧间隔；相邻两次动画之间的空窗（静止/跨手势，
秒级）会污染 P50/P95/P99（表现为 P99=25s 假象）。修正为：间隔 > 100ms
（`FRAME_INTERVAL_GAP_MS`）视为动画边界，重置基准不记录。修正后 P50/P95/P99 反映
动画内真实帧节拍（见 3.2，P99=15.55ms）。

---

## 4. 单测

- `entry/src/ohosTest/ets/unit/FlipEngine.test.ets`（新增）：松手完成判定纯函数
  （进度/速度/门槛）、分位纯函数、FORWARD/BACK 方向与镜像、上下角、完成/回弹、
  取消、尺寸变化取消、快速连续手势（含收尾中断接管）、无相邻页拒绝、页尺寸未就绪
  拒绝、程序化翻页、setDefaults 阈值覆盖。
- `entry/src/ohosTest/ets/unit/FlipCalculation.test.ets`（扩展）：起手姿态、中心线、
  极值 y、书脊退化、BACK 极值 x、零尺寸防御。
- `entry/src/ohosTest/ets/unit/FlipStateMachine.test.ets`（修复）：与当前
  `FlipSM.handleBeginDrag(hasNeighbor)` 单参 API 对齐（旧测试仍调用已删除的热区双参
  形态，无法编译）。

运行方式：DevEco Studio → entry → Run 'entry[ohosTest]'（本机无设备连接时无法在此
环境执行；代码已通过 arkts_check 逐文件校验，debug/release 双构建通过）。

---

## 5. 已知限制

1. **页背纹理简化**：背图在 `progress > 50` 后一次性切换，未做 50% 附近的透明度
   过渡；切换点附近可能有一帧可见跳变。可用 `backSideProgressThreshold` 微调，或
   后续在阈值附近做 cross-fade（需入 FLIP_DEFAULTS）。
2. **单页阅读器模型**：书脊固定在左缘（FORWARD），无双页 spread；`isSpread=false`
   不绘制书脊中缝阴影（与 P0–P5 冻结范围一致）。
3. **无贝塞尔折叠边缘**：默认 1:1 StPageFlip 几何；增强属 P5 可选且需 ADR 先行
   （现有任务未做）。
4. **速度门槛为经验值**：`completeVelocityThreshold=0.8`、`completeVelocityMinProgress=15`
   需真机手感校准，全部入 FLIP_DEFAULTS 可调。
5. **ohosTest 编译依赖 DevEco 集成环境**：CLI 无法直接触发 `ohosTest` 编译任务
   （任务未在 project 级注册），单测需在 DevEco Studio 内运行。
6. **Canvas 2D 帧率**：P5 基线 JS 提交 P95≈1.2ms 而帧间隔 16.1ms（受 VSync/提交管线
   限制），本层变更在余量内；若目标真机无法稳定 60fps，见 §6 的后端替换路径。

---

## 6. 后续切换 XComponent + OpenGL ES 的后端接口建议

架构已预留 A8 固定接口 `FlipRendererInterface`（`PageFlipEngine → FlipRendererInterface
→ Canvas2D 实现（当前）/ 未来 Native 实现`），切换**不需要**改 FlipCalculation /
FlipSM / FlipAnimator / PageFlipEngine 的接口与语义。

### 6.1 现状数据先行的门禁

切换前必须复测并落盘 §3.2 口径的性能数据（真机全尺寸 Canvas 连续 20 次翻页 +
长时间连续翻页），确认 Canvas 2D 确实无法达标（P95 ≥ 16ms 或掉帧），再进入 GL 设计，
避免无数据返工。

### 6.2 后端接口改动建议（保持语义不变）

1. `FlipRendererInterface` 已含：`setSize/setDensity/renderFrame/setVisible/
   getStats/getPercentiles/resetStats/release/getContext/setFrameTimestampNs`。
   Native 后端实现同一接口即可；`renderFrame` 的 `image.PixelMap` 参数在 XComponent
   下应替换为 `ImageBitmap | TextureId`（纹理上传/释放所有权移交给后端），接口签名
   变化需 ADR 评审（A8 强制）。
2. 新增 `onSurfaceReady(hostCtx, xComponentController)` 绑定：XComponent 生命周期
   与 `PageFlipView` 解耦，`PageFlipView` 仍负责手势路由与尺寸/可见性转发。
3. `FlipState`（模块内部）已是 Native 数据喂入的最小集合：`angle/pageRect/position/
   flippingClipArea/bottomClipArea/shadowStart/shadowAngle/progress`，可直接经 napi
   传入 C++；背纹理在 Native 侧以两个 texture（正/背）表达。
4. 统计埋点（P50/P95/P99、drawImage/clip 次数、帧间隔）由 Native 侧通过回调回灌
   相同的 `FlipPercentiles` 结构，Reader 侧读取路径不变。

### 6.3 GL 渲染要点（供后续设计参考）

- 顶点：翻起页 = 页矩形四角 + 裁剪多边形（两 clip 区域分别生成三角网格），
  `position` 为旋转中心；底页 = bottomClipArea 三角化；静态页 = 全屏 quad。
- 纹理：当前页/目标页/背页各一；用 `glTexImage2D` 上传 PixelMap（YUV/RGBA 转换
  在 CPU 侧一次完成，热路径零上传）。
- 阴影：三道阴影用屏幕空间渐变 quad（顶点色/片元渐变），等价于当前 Canvas 渐变语义；
  `shadowAngle/shadowWidth/progress` 驱动渐变参数。
- 混合：背页半透明过渡可在阈值附近用片元 alpha 渐变，弥补 §5.1 的切换跳变。
- 双缓冲/XComponent 合成：`EGL` + `GLES3`，`vsync` 由 displaySync 现有驱动保持不变。
