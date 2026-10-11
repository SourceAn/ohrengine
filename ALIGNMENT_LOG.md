# 翻页动画效果一致性 — 打磨进度日志

> 任务：`$HOME/Code/Python/StPageFlip`（基准，StPageFlip 复现）与
> `$HOME/Code/Harmony/ohrengine/ohrengine-pageflip`（目标，鸿蒙移植）在
> 同一本书、相同输入下做到**动画效果一致**（几何结构、时序节奏、视觉观感一致），不要求逐像素一致。
>
> 环境路径说明（**权威，prompt 里的路径是笔误**）：prompt 中的 `/code/python/stpageflip` → 实际 `$HOME/Code/Python/StPageFlip`（目录名 `StPageFlip`，且是 Vite/JS 项目，非 Python，见其 README）；prompt 中的 `/code/harmony/ohregine` → 实际 `$HOME/Code/Harmony/ohrengine`（目录名 `ohrengine` 多一个 `n`，`ohregine` 为 prompt 笔误，磁盘上不存在该目录）。
>
> 对齐工件目录：`ohrengine/.align/`（input.json / stpageflip_baseline.json / venv / 脚本）。
>
> **验证口径（重要）**：本日志中"0 差异 / 逐帧一致"均指**数据/逻辑层**（FlipReplay + FrameLogger 算出的 angle/coords/alpha 中间量）与基准日志一致；验证手段是 Node 纯数值脚本 `.align/verify_mirror.mjs`（不经过 ArkUI Canvas 渲染管线）与模拟器 hypium 单测（不涉及像素）。**尚未验证视觉/渲染层**——ArkUI Canvas 的 `drawImage`/`createLinearGradient`/`clip`、图片解码、坐标变换这一层可能引入新的偏差，需待"ohrengine 侧帧捕获 + SSIM"（待办①）补齐后才算视觉层闭环。引用本日志时勿把逻辑层结论等同于视觉层已验证。

---

## 迭代 0 — 前置条件核实（2026-08-13）

**对应验收标准**：第 3 节 #1（确定性接口触发）、#2（中间量日志）、#8（未达标不降级）。

### 结论：前置条件部分就绪，存在多项结构性缺口（已与用户确认三项决策）

用户决策：
1. **分辨率统一**：以基准竖屏 **1316×2832 @ 453 DPI**（单页）为准。
2. **时序模型**：允许重写 ohrengine 的 FlipAnimator/FlipReplay/PageFlipEngine 时序模型，StPageFlip 为唯一基准。
3. **运行方式**：启动模拟器 Mate 70 RS（已存在实例，屏幕 1316×2832，`hdc` 已连接 `127.0.0.1:5555`）。

### 核实结果明细

| 项 | 状态 | 说明 |
|---|---|---|
| 确定性输入驱动接口 | ⚠️ 部分 | 两边都有 `flip(startX,startY,path,releaseVelocity)`，但完成判定/收尾动画/方向判定/坐标系语义均不同（见下） |
| 统一日志 schema | ❌ | `t_normalized` 语义不同（几何进度 vs 帧序号）、`shadow_gradient_stops` 结构不同（{outer,inner,rgba} vs 扁平数组）、`control_points` 坐标系不同 |
| 统一分辨率/DPI | ❌→✅ | 基准竖屏 1316×2832；目标原为横屏 2832×1316（D1）。已决策统一为竖屏 |
| 统一素材 | ❌ | 共享目录不存在；两边各自程序化生成页面 |
| 运行环境 | ✅ | StPageFlip 用 Chrome 151 headless + puppeteer-core；ohrengine 用模拟器 hdc |

### 已确认的关键差异（根因清单，逐项标注结构/时序/渲染）

1. **[时序] t_normalized 语义**：基准 = `getFlippingProgress()/100`（几何进度，回弹时递减）；目标 = `i/(n-1)`（帧序号，单调 0→1）。**必须改**。
2. **[时序] 帧序列结构**：基准 = 初始静态帧 + 每拖拽点一帧 + 收尾动画帧 + 末稳定帧（67 帧）；目标 = 按时间步长采样拖拽 + 弹簧收尾（帧结构完全不同）。**必须改**。
3. **[时序] 收尾动画模型**：基准 = `GetCordsFromTwoPoint` 1px 直线插值 + 时长 `(size/1000)*flippingTime`（size≥1000 → flippingTime）；目标 = 临界阻尼弹簧 + 时长 clamp [220,450]ms。**必须改**。
4. **[结构] 完成判定**：基准 = `stopMove` 的 `pos.x <= 0`；目标 = `decideFlipOutcome`（进度≥45 或 velocity≤-0.8 且进度≥15）。**必须改**。
5. **[结构] 方向判定**：基准 portrait = `(bookPos.x - pageWidth) <= rect.width/5`（即 rawX ≤ 0.4·W → BACK）；目标 = `startX >= pageWidth/2`。**必须改**。
6. **[结构] 坐标系/镜像**：基准 BACK 镜像 `convertToPage` x = −rawX；目标 `normalizeX` = W − rawX。**必须改**（FORWARD 两者一致，故首个目标帧用 FORWARD）。
7. **[日志] shadow_gradient_stops**：基准 `{outer:[[off,"rgba(0,0,0,a)"]], inner:[...]}`；目标扁平 `[[off,alpha]]`。**必须改**。
8. **[渲染] shadow_alpha**：基准 = `(100-progress)/100·maxShadowOpacity`（maxShadowOpacity=1 时线性）；目标已线性，但 README D4 误记为"二次"。**对齐 maxShadowOpacity 因子**即可。
9. **[日志] control_points 坐标系**：基准 = `convertRectToGlobal`（FORWARD 恒等、BACK x 取负）；目标 = canonical。FORWARD 下两者数值一致。
10. **[参数] flippingTime**：基准确定性路径用 `buildFlipSettings`（flippingTime=1000, maxShadowOpacity=1.0），非 demo 的 650/0.5。目标 FLIP_REFERENCE_DEMO 标注的是 demo 覆盖，非确定性基准。

### 基准基线（`stpageflip_baseline.json`）

- 输入：竖屏单页 1316×2832，FORWARD+TOP 角拖拽，5 个路径点，releaseVelocity=0。
- 确定性：`logsIdentical=true`、`framesIdentical=true`，67 帧。
- 帧结构实测：帧0 初始静态(t=0 空) → 帧1-5 拖拽(每路径点一帧) → 帧6-64 收尾回弹(t 从 0.469 递减到 0.0076) → 帧65-66 末稳定(t=0 空)。
- 该输入为**回弹**（release 时 pos.x=60 > 0），非完成。

---

## 迭代 1 — 时序模型 + 日志 schema 对齐（2026-08-13）

**对应验收标准**：第 3 节 #2（中间量日志 schema 统一）、#3（几何/结构一致性）、#4（时序一致性）、#6（结构性/时序性差异必须修复）。

- 本轮目标：修复根因清单中的**时序类**（#1 帧序列、#2 t_normalized、#3 收尾动画、#4 完成判定、#5 方向判定、#6 镜像）与**日志 schema**（#7 shadow_gradient_stops、#9 control_points）。
- 采取的修改：
  - `ohrengine-pageflip/src/main/ets/replay/FlipReplay.ets` 重写：1:1 对齐 StPageFlip `DeterministicFlip`（fold-per-point + stopMove `pos.x<=0` + `GetCordsFromTwoPoint` 1px 收尾 + `getAnimationDuration`）。
  - `ohrengine-pageflip/src/main/ets/replay/FrameLogger.ets` 重写：`t_normalized`=几何进度、`shadow_gradient_stops`={outer,inner,rgba}、`control_points`=convertRectToGlobal（FORWARD 恒等/BACK x 取负）、新增 `buildEmptyEntry`。
  - `entry/src/ohosTest/ets/unit/FlipReplay.test.ets` 重写：断言新帧结构/新完成判定。
- 修改前：目标 t_normalized 为帧序号、弹簧收尾、进度/速度双阈值完成判定、扁平 shadow stops（与基准 67 帧结构完全不匹配）。
- 修改后：Node 镜像（`.align/verify_mirror.mjs`，**纯数值 JS，不含 ArkTS Canvas 渲染**）对同一输入产出 67 帧，与 `stpageflip_baseline.json` **逻辑层逐帧 0 差异**（maxAngleErr/maxCoordErr/maxAlphaErr 均为 0）；模拟器 hypium 单测（无像素）pageflip 全绿。**该结论仅覆盖数据/逻辑层，未覆盖视觉/渲染层**。
- 回归检测结果：`ohrengine_pageflip` HAR `assembleHar` 构建通过；几何层（FlipCalculation/FlipMath）未改动（P1 已 1e-6 验证）。
- **模拟器验证（已完成）**：构建 entry + ohosTest HAP，部署到模拟器 Mate 70 RS，跑 hypium 单测 —— 全部 pageflip 相关测试通过（`three_runs_identical`/`frame_structure_empty_ends`/`forward_drag_past_spine_completes`/`back_direction_from_left_region`/schema/命名，及 FlipMath/FlipCalculation/FlipSM/FlipEngine 全绿）。169 项中 12 项失败均为**无关模块**（TextBreaker/PageSplitter/StyleMapper/SelectorMatcher/FontFallbackChain/PageGeneration）的历史遗留，非本次改动引入。
- 下一步计划：
  1. 重写交互路径 `PageFlipEngine`（decideFlipOutcome → pos.x≤0；FlipAnimator 弹簧 → GetCordsFromTwoPoint 1px 收尾 + getAnimationDuration）与回放/StPageFlip 对齐（当前回放已对齐，交互路径仍是旧模型，二者不一致）。
  2. 补齐共享测试素材 + ohrengine 侧帧捕获 + SSIM 视觉比对（建立视觉验收管线）。

---

## 迭代 2 — 交互路径（PageFlipEngine/FlipAnimator）时序对齐（2026-08-13）

**对应验收标准**：第 3 节 #3（几何/结构一致性）、#4（时序一致性）、#6（结构性差异必须修复）。

- 本轮目标：修复交互路径（真实动画，非回放）与 StPageFlip 的结构/时序差异（#3 收尾动画、#4 完成判定、#5 方向判定、#6 镜像）。
- 采取的修改：
  - `core/FlipAnimator.ets` 重写：收尾从「临界阻尼弹簧」改为 `pointsAlongSegment` 1px 步进直线插值 + `getAnimationDuration(size)`，帧下标 `round(elapsed/durationFrame)`；拖拽段去除一阶低通（StPageFlip 原始触点语义）。
  - `PageFlipEngine.ets`：方向判定 `rawX ≤ 0.4·W → BACK`；角判定 `y ≥ H·cornerThresholdRatio → BOTTOM`；完成判定 `pos.x ≤ 0`（删除 `decideFlipOutcome`/末速度估算/阈值覆盖）；镜像 `BACK x → -x`（原 `W - x`）；程序化翻页起手对齐 `Flip.flip`（起点 x=W−H/10、y=H/10，目标 (−W,0)）。
  - `config/FlipConfig.ets`：删除弹簧/低通/完成阈值等产品参数，`FLIP_TIMING` 仅保留 `fixedTimestepMs`。
  - `entry/.../FlipEngine.test.ets` 重写：按新完成判定/方向/镜像语义更新断言。
- 修改前：交互路径用弹簧 + 进度/速度双阈值完成判定 + `W-x` 镜像（与 StPageFlip 不匹配）。
- 修改后：HAR + entry + ohosTest 构建通过；模拟器 hypium 单测 **150/162 通过，12 项失败均为无关模块（文本/CSS/字体/分页）历史遗留**，pageflip 相关测试 0 失败。
- 回归检测结果：FlipMath/FlipCalculation/FlipSM/FlipReplay 全部通过（未回归）；几何层未改动。
- 下一步计划（按成本/依赖排序，**BACK 基线验证优先**）：
  1. **BACK 方向独立基线验证**（复用已跑通的确定性基线捕获流程，改方向参数重跑，低成本收尾"结构/时序对齐"主线；确认 BACK 镜像 x→-x 语义与基准一致，排除结构层隐藏 bug 后再投入视觉基建）。
  2. 建立 ohrengine 侧帧捕获（宿主把 FlipReplay 的 FlipState 渲染到 Canvas 落盘 PNG）+ 共享测试素材（两项目同一套页面位图）。
  3. SSIM 视觉比对（建立 `.align/` 比对脚本，对每对同时刻帧计算 SSIM，闭环视觉/渲染层验证）。

---

## 迭代 3 — BACK 方向基线验证（2026-08-13）

**对应验收标准**：第 3 节 #3（几何/结构一致性）、#4（时序一致性）、#6（结构性差异必须修复）。

- 本轮目标：交叉确认 BACK 方向镜像语义（canonical x = −rawX、getAngle 取正、control_points 全局坐标 x→−x）与 StPageFlip 基准一致，排除结构层隐藏 bug。
- 对基准项目的**最小增补改动**（不改翻页逻辑，仅暴露 startPage 供 BACK 起手，因 StPageFlip `checkDirection` 要求 BACK 时 currentPageIndex ≥ 1）：
  - `StPageFlip/src/flip/flipConfig.ts` `buildFlipSettings` 增 `startPage=0` 参数；`DeterministicFlip.ts` 构造器增 `startPage=0`；`main.js` `runDeterministicFlip` 透传 `input.startPage`。
- 采取的动作：
  - 新增 `.align/input_back.json`（竖屏 1316×2832，startPage=1，BACK 拖拽：200→300→500→700）。
  - 跑 `.align/capture_stpageflip.mjs` 生成 `stpageflip_baseline_back.json`（**42 帧、deterministic 通过**）。
  - 修正 `.align/verify_mirror.mjs` 的 control_points 全局坐标换算（BACK x→−x，此前仅 FORWARD 恒等），并改为按 argv 读基线。
  - 新增 `.ets` 单测 `flip_replay_back_mirror.back_geometry_mirror_and_angle_sign`（断言方向/角/完成/control_points[0]=原始触点(300,300)/curl_angle>0）。
- 修改前：镜像仅 FORWARD 验证过；BACK 镜像存在"可能把 canonical 当全局"的隐患（此前 Node 镜像未做 x→−x 换算）。
- 修改后：
  - Node 镜像 BACK **42 帧逐帧 0 差异**（maxAngleErr/maxCoordErr/maxAlphaErr 均为 0）；FORWARD 回归 67 帧仍 0 差异。
  - 模拟器 hypium：`back_geometry_mirror_and_angle_sign` 通过，pageflip 相关 0 失败（12 项仍为无关模块历史遗留）。
- 回归检测结果：FORWARD 基线 67 帧复测 0 差异；几何层未改动。
- 结论：**结构/时序对齐主线（FORWARD + BACK 两方向）在数据/逻辑层闭环**；视觉/渲染层仍未验证（待办① SSIM 管线）。
- 下一步计划：建立 ohrengine 侧帧捕获 + 共享测试素材 + SSIM 视觉比对管线（视觉/渲染层闭环）。

---

## 迭代 4 — 渲染层（FlipRenderer）结构差异排查与修复（2026-08-13）

**对应验收标准**：第 3 节 #3（几何/结构一致性——渲染层卷曲形状/阴影方向）、#6（结构性差异必须修复）。**本轮开始涉足逻辑层之外的实际渲染管线（用户提示的两层问题）。**

- 本轮目标：逐行对照 StPageFlip `CanvasRender`/`ImagePage` 与 ohrengine `FlipRenderer`，定位逻辑层镜像未覆盖的渲染层偏差。
- 发现并修复的渲染层结构问题：
  1. **`FlipRenderer.toGlobal` BACK 镜像错误**（已修）：原 `out.x = rect.left + rect.width - pos.x`（= W − pos.x），但 canonical BACK 已是 −rawX（StPageFlip convertToPage），StPageFlip `convertToGlobal` BACK 应为 −pos.x。已改为 `out.x = -pos.x`。此前逻辑层 mirror 验证不经过渲染管线，未暴露此 bug。
  2. **`FlipRenderer.drawFlippingPage` 裁剪/旋转顺序 + 旋转中心错误**（已修）：原实现「绝对坐标 clip → translate(触点) → rotate → draw」，即裁剪遮罩在**未旋转帧**、旋转中心用 `getPosition()`（触点）；StPageFlip 为「translate(活动角) → 相对路径 → rotate → clip → draw」，裁剪遮罩在**旋转帧**、旋转中心用 `getActiveCorner()`（FORWARD=topLeft / BACK=topRight）。已按 StPageFlip 顺序重写（活动角旋转中心 + rotate 后再 clip）。
- 已知待验（需 SSIM 实证，未盲目改）：
  3. **背面纹理（backSideProgressThreshold=50）为产品自行增加的翻面近似**：StPageFlip `ImagePage.draw` 只画正面，无背面纹理；ohrengine 越过中点后画背面（镜像）。属产品功能差异，SSIM 比对须用**同内容页**（正反面相同）规避，或后续按 StPageFlip 禁用。
  4. **`drawBottomPage` 的 BACK 定位**与 StPageFlip `getBottomPagePosition()`（BACK=(W,0)）是否等价，待 SSIM 实证。
- 回归检测结果：`ohrengine_pageflip` HAR `assembleHar` 构建通过；逻辑层（FlipMath/FlipCalculation/FlipSM/FlipReplay）未改动。
- 下一步计划：
  1. 建立 ohrengine 侧确定性帧捕获（FlipReplay → FlipRenderer → 落盘 PNG）+ 与 StPageFlip 同内容的测试页素材。
  2. 编写 SSIM 比对脚本（StPageFlip 基线 PNG 已可提取），对每对同时刻帧计算 SSIM，量化渲染层残余差异并据此继续修。

---

## 迭代 5 — 视觉比对管线建立 + 渲染层差异定位（2026-08-13）

**对应验收标准**：第 3 节 #2（关键帧截图+日志）、#5（SSIM≥0.98）、#6（结构性差异必须修复）、#7（渲染细节差异须完整举证）。

- 本轮目标：建立正式视觉比对管线（StPageFlip 帧 PNG ↔ ohrengine 离屏渲染帧 PNG ↔ SSIM），量化渲染层残余差异并定位根因。
- 采取的动作（含清理与基础设施修正）：
  - **清理**（按用户要求）：删除 `PageFlipDemoPage.ets`（翻页渲染 harness）及其 main_pages 注册、DebugBookshelf「翻页渲染 Harness」按钮、rawfile 中冗余的 `epub_page_00~03.png`（此前用 html2canvas 单独栅格化并打包，属造轮子）。确认现有 `rawfile/test.epub` 即《妹妹人生·上卷》（与根目录同字节），reader（Index→PageFlipBridge→PageFlipEngine→PageRenderer）就是唯一翻页入口。
  - **帧率 >60**：`fixedTimestepMs` 由 `1000/60` 改为 `1000/120`（120fps，两项目一致）。实测 426×640 输入 60fps=29 帧、120fps=51 帧（收尾时长 363ms × 120Hz ≈ 44 帧 + 拖拽 5 帧 + 首末帧），帧数增加即 120fps 已生效。
  - **视觉捕获**：新增 hypium 单测 `FlipVisualCapture.test.ets`（`FlipReplay`+`FlipRenderer` 离屏逐帧渲染→PNG 落盘），用白底黑框测试页隔离折页/阴影渲染。
  - **分辨率修复**：`OffscreenCanvas` 默认 VP 单位会被系统密度 3.5× 放大（capture 1491×2240 vs 基准 426×640）；改用 `new OffscreenCanvasRenderingContext2D(W,H,settings,LengthMetricsUnit.PX)` 强制 PX 单位，两项目同为 426×640。
  - **阴影根因排查（两轮假设均被证伪）**：
    - 假设 1：外侧阴影裁剪矩形（单页 vs 整本书）→ 已按 StPageFlip 改为 `rect(-W,0,2W,H)`，SSIM 无变化（证伪：填充区从未超出单页裁剪）。
    - 假设 2：阴影几何（shadowStart/shadowAngle）偏移 → 已给两项目日志增加 `shadow_start`/`shadow_angle` 字段，**逐位一致**（如帧5 shadowStart=(240.7052,0)、shadowAngle=1.409671），证伪。
  - **裁剪多边形对比**：给 mirror 增补 `getFlippingClipArea/getBottomClipArea`，ohrengine 测试 dump `frame5_clip.txt`，**两项目帧5 的 flippingClipArea/bottomClipArea/shadowStart/angle 逐位一致**。
- 修改前：SSIM 0.16（分辨率不匹配，ohrengine 3.5×）；修复分辨率后 SSIM 0.83（min 0.8314，avg 0.9009）。
- 修改后（当前）：**几何层（日志全部中间量 + 裁剪多边形）100% bit-exact；绘制代码逐行一致；视觉残余差异（SSIM 0.83）定位为 ArkUI Canvas vs HTML Canvas 渲染管线差异**——视觉子代理确认：卷曲纸边缘抗锯齿粒度不同（StPageFlip 平滑 / ohrengine 阶梯状）、阴影渐变/变换精度略有差异。
- 回归检测结果：`ohrengine_pageflip` HAR + entry + ohosTest 构建通过；`FlipReplay.test`/`FlipEngine.test` 等 pageflip 单测全绿（几何未改动）。
- 结论（待用户裁决）：SSIM 0.83 < 0.98，但已证明差异**不改变几何/时序**（中间量与裁剪多边形逐位一致），属第 3 节 #7 的"渲染管线细节差异"候选；是否按 #7 容差声明流程接受、或继续深挖 ArkUI Canvas clip/渐变/抗锯齿的特定差异，由用户决定。

---

## 迭代 6 — 分辨率统一到 reader 实际屏幕 1316×2832 @ 120fps（2026-08-13）

**对应验收标准**：第 3 节 #1（同输入同分辨率确定性接口）、#5（SSIM≥0.98 协商）、#7。

- 本轮目标（用户新要求）：帧率 ≥ 60Hz；比对分辨率采用 **进入《妹妹人生·上卷》时 reader 的实际屏幕显示分辨率**；DPI 统一；ohrengine 动画 1:1 复刻 web StPageFlip。
- 实测确认：
  - 模拟器屏幕 = **1316×2832 px**（截图实测），DPI 560（densityPixels 3.5）。
  - reader（Index.ets）`PageFlipView` 物理 canvas = `winRect.width × winRect.height` = **1316×2832 px**（density 用系统 densityPixels，vp=px/density）。
  - 帧率 120fps（≥60Hz 满足）：60fps=29 帧、120fps=127 帧（1316×2832 收尾距离更长 → 帧更多），两项目一致。
- 采取的动作：
  - StPageFlip 用 `input.json`（1316×2832 绝对坐标）@120fps 重抓白页基线 → `stpageflip_1316x2832_120fps.json`（**127 帧、deterministic**）。
  - ohrengine 捕获测试改为 `W=1316,H=2832`、`LengthMetricsUnit.PX`（1:1 无密度缩放）、同输入坐标，捕获 **127 帧**。
  - SSIM 脚本在 1316×2832 下逐帧比对。
- 修改前（426×640）：min 0.8314 / avg 0.9009。
- 修改后（1316×2832，reader 实际分辨率）：**min 0.9414 / avg 0.9635 / median 0.9611 / max 0.9916**；32 帧 ≥0.98、51 帧 0.95-0.98、44 帧 <0.95。
- 结论：分辨率对齐 reader 实际屏幕后，视觉相似度大幅提升（avg 0.96）；几何层 100% bit-exact 不变。残余差异为 ArkUI Canvas clip 边缘抗锯齿/阴影渐变精度（分辨率越高相对占比越小）。
- 下一步：视用户裁决——按 #7 接受（几何/时序已 bit-exact，avg 0.96 观感一致）或继续深挖 Canvas 抗锯齿/渐变把 SSIM 推到 0.98。

---

## 迭代 7 — 交互体验修复 + 36 方向翻页动画对比（2026-08-13）

**对应验收标准**：第 3 节 #3（几何一致）、#4（时序一致）、#5（SSIM）、#6（结构性差异必须修复）。

- 用户反馈的 5 个交互体验问题修复：
  1. **只有右上角有动画**：FlipSM 动画完成时未复位（`onAnimatorSettle` 没发 t=1 → 状态卡 SETTLING_COMPLETE），后续翻页全被拒绝。修复：`onAnimatorSettle` 补发 `sm.handleFrameProgress(1)` 复位 IDLE。36 方向拖拽验证：FORWARD/BACK × TOP/BOTTOM 全部 consumed=true。
  2. **页码映射错误**：`getCurrentPageIndex` 用 1-based 全局页号、`resolvePageIndex` 用章节内局部 `pageNumber`，错位导致翻页拿错误页。修复 Index.ets：`getCurrentPageIndex = getGlobalPageNumber()-1`（0-based），`peekPage` 返回目标页全局 0-based 索引（含 RTL）。
  3. **离屏页图空白**：`renderPageToPixelMap` 用 `OffscreenCanvas`（VP 单位被系统密度放大）→ `getImageData` 采错区域。修复：`OffscreenCanvasRenderingContext2D(W,H,settings,LengthMetricsUnit.PX)` + `OFFSCREEN_PIXEL_SCALE 0.5→1.0`。**翻页露出区/底页现在显示下一页内容**（视觉确认）。
  4. **翻页闪烁/内容未就绪**：程序化翻页 `waitForFlipContent` 等待当前+目标页 PixelMap 就绪再播动画。
  5. **拖拽不跟手**：手势控制器传内容区坐标 `cx/cy`（减了 margins）→ 引擎几何在整画布，差一个 margins 偏移。修复：`beginDrag/updateDrag` 传整画布坐标 `tx/ty`。
- 36 方向翻页动画对比（Web StPageFlip vs OH，同一文字页 page 8，每方向 9 帧按 t=0.05..0.45 抽帧）：
  - **方向逻辑：36/36 正确**（beginDrag 日志验证：右半 FORWARD 左翻、左半 BACK 右翻全部对应）。
  - **折叠几何：36 方向平均 SSIM 0.9577**（min 0.9373 / max 0.9804；方向若反 SSIM 应近 0，故几何+方向一致）。
  - dir_4-*（起点 xf=0.6）折叠退化（n=5），两边一致。
  - 视觉子代理拼图对比给出"方向相反/角度不同"等结论，经 SSIM 证伪（小拼图误判），以 SSIM 为准。
  - 残余差异（avg 0.96）为 ArkUI vs HTML Canvas 管线差异（抗锯齿/渐变精度）。

---

## 迭代 8 — 折叠纸直绘改造（绕过 drawImage 限制，2026-08-14）

**对应验收标准**：第 3 节 #3（折叠纸翻起一面显示页面内容 = 结构性差异，必须修复）。

- **背景**：ArkUI 对"离屏 PixelMap 在 clip+rotate 变换下 drawImage 失效"，折叠纸翻起一面一直是空白（白纸+阴影），与 web StPageFlip（CSS clip-path+transform 渲染，折叠纸有页面内容）存在结构性差异。
- **方案：页面直绘回调**（`FlipPageDrawer`）——引擎渲染折叠纸时不再 drawImage，改由宿主（PageRenderer）把该页背景+正文直接画到已带折叠 clip+rotate 变换的 ctx：
  1. `FlipRendererInterface.renderFrame` 新增可选 `pageDrawer` + `flippingIndex`/`bottomIndex` 参数；`FlipRenderer` 新增 `FlipPageDrawer` 类型，折叠纸（drawFlippingPage）与底页露出区（drawBottomPage）优先走直绘，`invokeDrawer` 防御性 try/catch（异常仅记录，绝不中断动画）。
  2. `FlipContentProvider` 新增可选 `renderFlipPageToContext`；`PageFlipEngine.renderFrame` 组装 drawer 并传 renderer。
  3. `PageFlipBridge` 新增 `setFlipPageDrawer` + 转发；`Index` 提供 `renderFlipPageToFlipCanvas`（复用 PageRenderer 管线：背景 + margins 偏移 + 正文 vp 直绘）。
  4. **根因排查**（折叠纸空白排障链）：`this` 绑定 bug——引擎把 Bridge 方法当裸函数传给 renderer，renderer 调用时 `this` 变成 renderer 自身，`this.flipPageDrawer` 为 undefined（且 `undefined !== null` 为 true 导致日志误报 "drawer=set"），调用 `undefined(...)` 抛 "undefined is not callable"，被 invokeDrawer 吞掉 → 折叠纸完全没画。**修复**：引擎闭包包装保留 provider 引用。附带发现：折叠 clip 路径缺 `moveTo`（ArkUI 不像 HTML canvas 把首个 lineTo 隐式当 moveTo）→ 补显式 moveTo 首点（防自交 clip 为空）。
- **结果（视觉+日志确认）**：
  - 折叠纸翻起一面**现在显示页面内容**（高倍裁剪确认含文字笔画/假名，之前纯白）。
  - 底页露出区继续显示下一页内容（直绘路径）。
  - 翻页提交/复位正常（`onFlipCommitted dir=0 ok=true` + `onFlipSettled index=N` 连续翻页无异常、无 rejected）。
  - 保留 invokeDrawer 防御（任何直绘异常只记日志不影响动画）。
- 注意：36 方向 SSIM 测试（0.9577）用的是 renderFrame 直驱 drawImage 路径（折叠空白），未体现直绘收益；直绘后折叠纸内容与 web 一致，但未做匹配几何的量化复测。
- 下一步（可选）：匹配几何的直绘后 SSIM 复测，或按 #7 接受。
