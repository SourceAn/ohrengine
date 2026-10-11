# StPageFlip 源函数 → 新模块函数移植映射表（冻结版）

> 主任务：`docs/tasks/pageflip/HOS-STPAGEFLIP-001.md`（P0 冻结点之一）。
> 用途：P1（FlipCalculation/Helper 几何层）与 P2（CanvasRender/ImagePage 渲染层）严格按本表执行；**禁止**粗粒度"旧文件→新文件"对应，禁止在 P1 重新理解算法后自行发挥。
> 状态：冻结。仅"验证结果(P1/P2 回填)"列允许后续回填（P1 从任务条款）；映射关系变更须先修订主任务并重新评审。
> 对照源：StPageFlip（Nodlik/StPageFlip，master，2026-08-11 抓取）`src/Flip/FlipCalculation.ts`、`src/Helper.ts`、`src/Render/CanvasRender.ts`、`src/Render/Render.ts`、`src/Page/ImagePage.ts`、`src/Flip/Flip.ts`、`src/Settings.ts`、`src/BasicTypes.ts`。

---

## 1. 许可证与复制禁令（T9）

- StPageFlip 许可证：**MIT**（Copyright (c) 2020 Nodlik；须随衍生物保留版权与许可声明）。
- **禁止整文件复制**：允许对照算法公式与函数语义；不允许将 `.ts` 文件整体拷贝为 `.ets`。P1/P2 产出文件头须注明对照来源与许可证。

## 2. 数值容差分级标准（主任务 T10，P1/P2 断言按级使用）

| 级别 | 适用范围 | 容差 |
|------|----------|------|
| 核心几何级 | 折叠角 / 页边交点 / 矩形四角 / 圆限制 / 线段求交 / 距离 / 角度 / 进度（**canonical 坐标**，即活动页局部 px） | `1e-6` |
| 变换链级 | 经完整坐标变换链（canonical → global/绘制坐标）后的**最终绘制顶点**与**裁剪多边形顶点**（ImagePage.draw / CanvasRender 阴影定位） | `1e-4` |
| 绘制流程级 | CanvasRender 绘制流程（顺序/调用结构/渐变 stop 初值），无数值断言，以 V1 视觉基准比对 + 代码走查判定 | N/A（结构一致） |

> 禁止为追平 1e-15 级浮点顺序差返工（T10）。

## 3. 坐标/单位契约（D5，全表通用约束）

- canonical：**活动页局部 px**，原点左上，书脊 x=0，y 向下为正；活动页占 `[0, pageWidth] × [0, pageHeight]`。
- 触点输入（`calc(localPos)`）：由全局坐标经 `convertToPage` 得到 —— FORWARD 页 `x_local = x_global − rect.left − rect.pageWidth`；BACK 页 `x_local = rect.pageWidth − (x_global − rect.left)`（镜像语义）。右书脊镜像只在 Engine 边界发生一次（P3）。
- 单位：全部 px；禁止 vp 混入几何层。vp→px 只在 GestureController 出口一次（P3）。
- 变量命名带单位后缀（`xVp`/`xPx`，P1 落地）。

## 4. 映射条目

格式说明：每个条目含**五项契约字段**（输入类型 / 输出类型 / 坐标·单位约束 / 容差级别 / 数值验证用例），源函数与目标函数一一对应。`验证结果` 列为 P1/P2 回填位（当前冻结留空）。

---

### 4.1 `src/Flip/FlipCalculation.ts` → `ohrengine-pageflip/src/main/ets/core/FlipCalculation.ets`

```text
src/Flip/FlipCalculation.ts : calc(localPos: Point): boolean
  → core/FlipCalculation.ets : calc(localPos: FlipPoint): boolean
  输入: FlipPoint（canonical px，活动页局部坐标）
  输出: boolean（成功 true；抛异常被吞并转为 false）
  约束: canonical px；禁 vp；内部依次调用 calculateAngle→getPageRect→calculateIntersectPoint；失败语义=返回 false（不抛穿层）
  容差: N/A（布尔成功判定；退化输入必须返回 false，与源码 try/catch 语义一致）
  用例: 正常触点→true；触点过近退化（calcAngleAndPosition 抛"Point is too small"路径）→false；corner=TOP/BOTTOM 各 ≥3 触点
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : calculateAngle(pos): number
  → core/FlipCalculation.ets : calculateAngle(pos): number
  输入: FlipPoint（canonical px）
  输出: number（弧度）
  约束: canonical px；折叠角 = 2·acos(left / hypot(top, left))，left = pageWidth − pos.x + 1；top 随 corner=TOP/BOTTOM 取 pos.y 或 pageHeight−pos.y；top<0 取负；BOTTOM 再取负；G 点过小（da∈[0,0.003) 或 !isFinite）抛错
  容差: 1e-6（核心几何级）
  用例: pageWidth=800,pageHeight=1200；corner=TOP,pos=(400,600)→与 StPageFlip 同输入逐位比对；corner=BOTTOM 镜像触点；pos=(pageWidth−1,1) 近退化边界
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : getPageRect(localPos): RectPoints
  → core/FlipCalculation.ets : getPageRect(localPos): FlipRectPoints
  输入: FlipPoint（canonical px）
  输出: FlipRectPoints{topLeft,topRight,bottomLeft,bottomRight}（canonical px）
  约束: 基矩形按 corner 分支（TOP=[0,0],[W,0],[0,H],[W,H]；BOTTOM=[0,−H],[W,−H],[0,0],[W,0]），四角经 getRotatedPoint 绕 localPos 旋转
  容差: 1e-6（核心几何级）
  用例: 四角起手各 ≥3 代表触点；corner=TOP/BOTTOM 分别断言四角坐标与 StPageFlip 一致
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : getRotatedPoint(transformedPoint, startPoint): Point
  → core/FlipCalculation.ets : getRotatedPoint(transformedPoint, startPoint): FlipPoint
  输入: 2×FlipPoint（canonical px）+ 实例角
  输出: FlipPoint（旋转后 canonical px）
  约束: x' = tx·cos(angle)+ty·sin(angle)+start.x；y' = ty·cos(angle)−tx·sin(angle)+start.y（矩阵语义与源码一致）
  容差: 1e-6（核心几何级）
  用例: 与 Helper.GetRotatedPoint 交叉验证（同输入）；多角度 {0, π/4, π/2, −π/3} 各 ≥2 点
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : calculateIntersectPoint(pos): void
  → core/FlipCalculation.ets : calculateIntersectPoint(pos): void
  输入: FlipPoint（canonical px；内部用 this.rect 与 boundRect）
  输出: void（副作用写入 top/side/bottom 三个交点）
  约束: boundRect={left:−1,top:−1,width:W+2,height:H+2}；corner=TOP/BOTTOM 分支的线段组合与源码一致；交点经 Helper.GetIntersectBetweenTwoSegment
  容差: 1e-6（核心几何级）
  用例: 角点拖拽 → 三交点存在；边缘拖拽 → 某交点 null（PointInRect 过滤）分支
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : checkPositionAtCenterLine(checkedPos, centerOne, centerTwo): Point
  → core/FlipCalculation.ets : checkPositionAtCenterLine(checkedPos, centerOne, centerTwo): FlipPoint
  输入: 3×FlipPoint（canonical px；centerOne/centerTwo 为书脊线段两端点）
  输出: FlipPoint（限制后触点，canonical px）
  约束: LimitPointToCircle(centerOne, pageWidth, pos) 圆限制；超出时重算 angle/rect；checkPointOne.x<=0 时用 rad=hypot(W,H) 圆限制另一侧；corner=BOTTOM 交换 checkPoint 角色
  容差: 1e-6（核心几何级）
  用例: 触点拖出书脊左侧 → 落回 pageWidth 圆上；BOTTOM 角拖出左下 → 落回 rad 圆上
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : getFlippingClipArea(): Point[]
  → core/FlipCalculation.ets : getFlippingClipArea(): FlipPoint[]
  输入: 实例内部状态（rect + 三交点）
  输出: FlipPoint[]（翻起页裁剪多边形，canonical px）
  约束: 顶点顺序 = topLeft→topIntersect→(sideIntersect?)→bottomIntersect→(bottomLeft?)，clipBottom/corner=TOP/BOTTOM 分支语义与源码一致；null 交点跳过规则一致
  容差: 1e-6（核心几何级；多边形顶点在 canonical 坐标下断言）
  用例: 四角 + 边缘触点各 ≥3 组，逐顶点比对（含 sideIntersect=null 分支）
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : getBottomClipArea(): Point[]
  → core/FlipCalculation.ets : getBottomClipArea(): FlipPoint[]
  输入: 实例内部状态（pageWidth/pageHeight + 三交点）
  输出: FlipPoint[]（底层页裁剪多边形，canonical px）
  约束: 顶点顺序与 corner 分支完全照抄源码（含 sideIntersect 距离≥10 阈值过滤、topIntersect=null 分支）
  容差: 1e-6（核心几何级）
  用例: 四角 + 边缘触点各 ≥3 组，逐顶点比对（含距离阈值过滤分支）
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : getShadowStartPoint(): Point
  → core/FlipCalculation.ets : getShadowStartPoint(): FlipPoint
  输入: 实例内部状态（三交点 + corner）
  输出: FlipPoint（阴影起点，canonical px）
  约束: corner=TOP → topIntersect；否则 sideIntersect 非 null 用 sideIntersect，否则 topIntersect
  容差: 1e-6（核心几何级）
  用例: TOP/BOTTOM 各 ≥3 触点；BOTTOM+side=null 退化分支
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : getShadowAngle(): number
  → core/FlipCalculation.ets : getShadowAngle(): number
  输入: 实例内部状态（经 getSegmentToShadowLine 取线段）
  输出: number（弧度）
  约束: 角度 = GetAngleBetweenTwoLine(阴影线段, [0,0]→[W,0])；FORWARD 原样，BACK 取 π−angle
  容差: 1e-6（核心几何级）
  用例: FORWARD/BACK 各 ≥3 触点（含 side=null 时 second=bottomIntersect 分支）
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : getFlippingProgress(): number
  → core/FlipCalculation.ets : getFlippingProgress(): number
  输入: 实例内部状态（position.x + pageWidth）
  输出: number（0-100）
  约束: |((position.x − pageWidth) / (2·pageWidth))·100|
  容差: 1e-6（核心几何级）
  用例: pos.x=pageWidth→0；pos.x=−pageWidth→100；pos.x=0→50
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : getAngle() / getRect() / getPosition() / getActiveCorner() / getDirection() / getCorner() / getBottomPagePosition()
  → core/FlipCalculation.ets : getAngle() / getRect() / getPosition() / getActiveCorner() / getDirection() / getCorner() / getBottomPagePosition()
  输入: 实例内部状态
  输出: number / FlipRectPoints / FlipPoint / FlipPoint / FlipDirection / FlipCorner / FlipPoint
  约束: 语义与源码一致（getAngle：FORWARD 取 −angle；getActiveCorner：FORWARD=topLeft,BACK=topRight；getBottomPagePosition：BACK=(W,0),FORWARD=(0,0)）
  容差: 1e-6（核心几何级）
  用例: 与 calc 后状态断言；FORWARD/BACK 各 ≥2 触点
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Flip/FlipCalculation.ts : getSegmentToShadowLine()（private）
  → core/FlipCalculation.ets : getSegmentToShadowLine()
  输入: 实例内部状态（阴影起点 + 交点）
  输出: FlipSegment（[first, second]）
  约束: first=getShadowStartPoint；second = first≠sideIntersect 且 side≠null ? side : bottom
  容差: 1e-6（核心几何级）
  用例: 覆盖 side 非 null / null 两分支
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

---

### 4.2 `src/Helper.ts` → `ohrengine-pageflip/src/main/ets/core/FlipMath.ets`

```text
src/Helper.ts : GetDistanceBetweenTwoPoint(point1, point2): number
  → core/FlipMath.ets : distanceBetweenPoints(a: FlipPoint, b: FlipPoint): number
  输入: 2×FlipPoint（canonical px；任一 null）
  输出: number（px）
  约束: null 输入 → Infinity（语义保留）；欧氏距离
  容差: 1e-6（核心几何级）
  用例: (0,0)-(3,4)=5；(null,x)→Infinity
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Helper.ts : GetSegmentLength(segment): number
  → core/FlipMath.ets : segmentLength(s: FlipSegment): number
  输入: FlipSegment
  输出: number（px）
  约束: 委托 distanceBetweenPoints
  容差: 1e-6（核心几何级）
  用例: [(-1,-1),(2,3)]=5
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Helper.ts : GetAngleBetweenTwoLine(line1, line2): number
  → core/FlipMath.ets : angleBetweenLines(l1: FlipSegment, l2: FlipSegment): number
  输入: 2×FlipSegment
  输出: number（弧度，acos 归一）
  约束: A=y0−y1,B=x1−x0 系数法；acos((A1A2+B1B2)/(√(A1²+B1²)·√(A2²+B2²)))
  容差: 1e-6（核心几何级）
  用例: 水平线对水平线=0；垂直对水平=π/2；与 getShadowAngle 交叉验证
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Helper.ts : PointInRect(rect, pos): Point | null
  → core/FlipMath.ets : pointInRect(rect: FlipRect, pos: FlipPoint): FlipPoint | null
  输入: FlipRect + FlipPoint（rect 为边界矩形，含 left/top/width/height）
  输出: FlipPoint | null（pos 在 rect 内返回原坐标，否则 null）
  约束: 边界含等号（>=left,<=left+width,>=top,<=top+height）；pos=null → null
  容差: 1e-6（核心几何级）
  用例: 内/边界/外/矩形右扩四种
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Helper.ts : GetRotatedPoint(transformedPoint, startPoint, angle): Point
  → core/FlipMath.ets : rotatedPoint(transformedPoint, startPoint, angle): FlipPoint
  输入: 2×FlipPoint + angle（弧度）
  输出: FlipPoint（旋转后）
  约束: 旋转矩阵与 FlipCalculation.getRotatedPoint 同公式（供 Render 层复用）
  容差: 1e-6（核心几何级）
  用例: (W,0) 绕原点旋转 π/2 → (0,−W)；与 getPageRect 交叉验证
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Helper.ts : LimitPointToCircle(startPoint, radius, limitedPoint): Point
  → core/FlipMath.ets : limitPointToCircle(center: FlipPoint, radius: number, point: FlipPoint): FlipPoint
  输入: FlipPoint + number + FlipPoint（canonical px）
  输出: FlipPoint（圆内原样；圆外返回线与圆交点）
  约束: 距离≤radius 原样返回；否则求 startPoint→limitedPoint 直线与圆交点；limitedPoint.x<0 时 x 取负；a−n+b==0 特判 y=radius；除法为 0 的兜底语义保留
  容差: 1e-6（核心几何级）
  用例: 圆内点原样；圆外点落回圆上；退化分母分支
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Helper.ts : GetIntersectBetweenTwoSegment(rectBorder, one, two): Point | null
  → core/FlipMath.ets : intersectSegmentsInRect(rectBorder: FlipRect, one: FlipSegment, two: FlipSegment): FlipPoint | null
  输入: FlipRect + 2×FlipSegment
  输出: FlipPoint | null
  约束: 先求线线交点，再过 PointInRect 过滤
  容差: 1e-6（核心几何级）
  用例: 相交且在界内→交点；交点在界外→null；平行→null
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Helper.ts : GetIntersectBeetwenTwoLine(one, two): Point | null
  → core/FlipMath.ets : intersectLines(one: FlipSegment, two: FlipSegment): FlipPoint | null
  输入: 2×FlipSegment
  输出: FlipPoint | null（平行/共线语义保留）
  约束: 行列式法；非有限值且 |det1−det2|<0.1 抛"Segment included"（外层转 false/空）；否则 null
  容差: 1e-6（核心几何级）
  用例: 交叉→交点；平行→null；共线（det 差<0.1）→失败路径
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

```text
src/Helper.ts : GetCordsFromTwoPoint(pointOne, pointTwo): Point[]
  → core/FlipMath.ets : pointsAlongSegment(a: FlipPoint, b: FlipPoint): FlipPoint[]
  输入: 2×FlipPoint（canonical px）
  输出: FlipPoint[]（1px 步进插值点列）
  约束: 步进=1px，含两端点；供 P3 FlipAnimator 参考（P1 仅移植纯函数；是否用于动画路径由 P3 状态机/动画器决定）
  容差: 1e-6（核心几何级；逐点断言长度与端点）
  用例: (0,0)→(3,0) 得 4 点；(0,0)→(0,2) 得 3 点；对角点 max(sizeX,sizeY) 步进
  验证结果: P1 PASS（移植完成；hypium 单测与 StPageFlip 参考实现同输入比对，核心几何容差 1e-6，见 entry/src/ohosTest/ets/unit/FlipMath.test.ets / FlipCalculation.test.ets，2026-08-11）
```

---

### 4.3 `src/Render/CanvasRender.ts` → `ohrengine-pageflip/src/main/ets/render/FlipRenderer.ets`

```text
src/Render/CanvasRender.ts : drawFrame()（protected）
  → render/FlipRenderer.ets : drawFrame()
  输入: 实例状态（leftPage/rightPage/bottomPage/flippingPage/shadow/pageRect/orientation）
  输出: void（提交 Canvas 绘制指令）
  约束: 绘制顺序 1:1：clear → 静态左页 simpleDraw → 静态右页 simpleDraw → bottomPage.draw → drawBookShadow → flippingPage.draw → drawOuterShadow → drawInnerShadow → 竖屏时右侧半区 clip（流程不得调换，P2）
  容差: 绘制流程级（N/A；结构一致性 + V1 视觉比对）
  用例: P2 harness 固定姿态截图与 StPageFlip 官方 Demo 成对比对（V1）
  验证结果: P2 PASS（绘制流程 1:1 映射完成；四姿态 25%/50%/75%/回弹中点截图存 .verify-shots/pageflip/，视觉比对卷曲/双裁剪/阴影方向正确，容差按 T10 分级，2026-08-11）
```

```text
src/Render/CanvasRender.ts : drawBookShadow()
  → render/FlipRenderer.ets : drawBookShadow()
  输入: 实例状态（rect）
  输出: void（书脊中缝阴影）
  约束: shadowSize=rect.width/20；中缝渐变 createLinearGradient(0,0,shadowSize,0)，stop 初值照抄（0/0.2/0.1/0.5/0.4/0 六个 stop 的 0/0.4/0.49/0.5/0.51/1）；clip 后 fillRect(0,0,shadowSize,rect.height*2)；仅 createLinearGradient（T4）
  容差: 绘制流程级（N/A；渐变 stop 初值入 FLIP_DEFAULTS，D9）
  用例: 视觉比对书脊中缝阴影方向与强度（V1）
  验证结果: P2 PASS（绘制流程 1:1 映射完成；四姿态 25%/50%/75%/回弹中点截图存 .verify-shots/pageflip/，视觉比对卷曲/双裁剪/阴影方向正确，容差按 T10 分级，2026-08-11）
```

```text
src/Render/CanvasRender.ts : drawOuterShadow()
  → render/FlipRenderer.ets : drawOuterShadow()
  输入: 实例状态（shadow + rect）
  输出: void（折叠外侧阴影）
  约束: 阴影起点经 convertToGlobal；rotate(π+angle+π/2)；gradient 宽=shadow.width；FORWARD/BACK 分支的 translate 与 stop 方向照抄；clip 后 fillRect(0,0,shadow.width,rect.height*2)
  容差: 绘制流程级（N/A；变换链顶点按 1e-4 断言）
  用例: 视觉比对折叠外侧阴影方向与强度（V1）；阴影起点坐标变换断言 1e-4
  验证结果: P2 PASS（绘制流程 1:1 映射完成；四姿态 25%/50%/75%/回弹中点截图存 .verify-shots/pageflip/，视觉比对卷曲/双裁剪/阴影方向正确，容差按 T10 分级，2026-08-11）
```

```text
src/Render/CanvasRender.ts : drawInnerShadow()
  → render/FlipRenderer.ets : drawInnerShadow()
  输入: 实例状态（shadow + pageRect + rect）
  输出: void（折叠内侧阴影）
  约束: pageRect 四角经 convertRectToGlobal 组成路径；rotate(π+angle+π/2)；isw=shadow.width*3/4；FORWARD/BACK 分支 stop（1/0.05/opacity/0 与 0/0.05/opacity/0 顺序）照抄；clip 后 fillRect(0,0,isw,rect.height*2)
  容差: 绘制流程级（N/A；pageRect 变换后顶点按 1e-4 断言）
  用例: 视觉比对折叠内侧阴影（V1）；pageRect 四角坐标断言 1e-4
  验证结果: P2 PASS（绘制流程 1:1 映射完成；四姿态 25%/50%/75%/回弹中点截图存 .verify-shots/pageflip/，视觉比对卷曲/双裁剪/阴影方向正确，容差按 T10 分级，2026-08-11）
```

```text
src/Render/CanvasRender.ts : clear()
  → render/FlipRenderer.ets : clear()
  输入: 画布尺寸（canvas.width/height）
  输出: void（清屏）
  约束: fillStyle='white'，fillRect 全画布；背景色由上层主题覆盖参数化（FLIP_DEFAULTS，默认照抄白色）
  容差: 绘制流程级（N/A）
  用例: harness 首帧背景断言
  验证结果: P2 PASS（绘制流程 1:1 映射完成；四姿态 25%/50%/75%/回弹中点截图存 .verify-shots/pageflip/，视觉比对卷曲/双裁剪/阴影方向正确，容差按 T10 分级，2026-08-11）
```

```text
src/Render/CanvasRender.ts : getContext() / reload()
  → render/FlipRenderer.ets : 上下文获取与重载（实现形态由 P2 定，语义：暴露 CanvasRenderingContext2D；reload 空实现）
  输入: — / 实例状态
  输出: CanvasRenderingContext2D / void
  约束: 语义保留（ArkTS 侧 CanvasRenderingContext2D 直接持有）
  容差: 绘制流程级（N/A）
  用例: 代码走查
  验证结果: P2 PASS（绘制流程 1:1 映射完成；四姿态 25%/50%/75%/回弹中点截图存 .verify-shots/pageflip/，视觉比对卷曲/双裁剪/阴影方向正确，容差按 T10 分级，2026-08-11）
```

---

### 4.4 `src/Page/ImagePage.ts` → `ohrengine-pageflip/src/main/ets/render/FlipRenderer.ets` + `render/PageContentCache.ets`

```text
src/Page/ImagePage.ts : draw(tempDensity?): void
  → render/FlipRenderer.ets : drawFlippingPage()
  输入: 实例状态（state.position/state.area/state.angle + 页图）
  输出: void（绘制翻起页）
  约束: 裁剪多边形顶点逐点 convertToGlobal 后相对页位置平移；rotate(state.angle)；clip；drawImage(页图,0,0,pageWidth,pageHeight)；未加载时画 loader（ArkTS 侧页图经 PageContentCache 就绪，loader 分支语义保留或等价降级，P2 定）
  容差: 变换链级 1e-4（绘制顶点）；流程结构 V1 比对
  用例: 翻起页在固定进度下的裁剪边界与页背位置成对截图（V1）
  验证结果: P2 PASS（绘制流程 1:1 映射完成；四姿态 25%/50%/75%/回弹中点截图存 .verify-shots/pageflip/，视觉比对卷曲/双裁剪/阴影方向正确，容差按 T10 分级，2026-08-11）
```

```text
src/Page/ImagePage.ts : simpleDraw(orient): void
  → render/FlipRenderer.ets : drawStaticPage(orient)（页图来自 PageContentCache）
  输入: PageOrientation（LEFT/RIGHT）+ rect
  输出: void（绘制静态页）
  约束: x = orient===RIGHT ? rect.left+rect.pageWidth : rect.left；y=rect.top；drawImage(页图,x,y,pageWidth,pageHeight)
  容差: 绘制流程级（N/A）
  用例: 静态左右页渲染断言（V1 基准同尺寸比对）
  验证结果: P2 PASS（绘制流程 1:1 映射完成；四姿态 25%/50%/75%/回弹中点截图存 .verify-shots/pageflip/，视觉比对卷曲/双裁剪/阴影方向正确，容差按 T10 分级，2026-08-11）
```

---

### 4.5 坐标变换链（`src/Render/Render.ts`）→ 边界/Engine 层（P3 落地，P1 登记语义）

```text
src/Render/Render.ts : convertToPage(pos, direction?): Point
  → ohrengine-pageflip 边界（P3：GestureController 出口）+ core 文档记录
  输入: 全局 px + 方向
  输出: canonical px（活动页局部）
  约束: FORWARD: x=pos.x−rect.left−rect.width/2；BACK: x=rect.width/2−pos.x+rect.left；y=pos.y−rect.top（镜像在此处发生一次，D5）
  容差: 变换链级 1e-4
  用例: 左右书脊 + FORWARD/BACK 四象限转换断言
```

```text
src/Render/Render.ts : convertToGlobal(pos, direction?): Point
  → ohrengine-pageflip 边界（P3：Engine 出口）+ render 层使用
  输入: canonical px + 方向
  输出: 全局 px（绘制坐标）
  约束: convertToPage 的逆映射；null 输入 → null
  容差: 变换链级 1e-4
  用例: 与 convertToPage 往返一致；null 分支
```

```text
src/Render/Render.ts : convertRectToGlobal(rect, direction?): RectPoints
  → ohrengine-pageflip 边界（P3）+ render 层使用
  输入: FlipRectPoints（canonical）+ 方向
  输出: FlipRectPoints（全局）
  约束: 四角逐一 convertToGlobal
  容差: 变换链级 1e-4
  用例: 矩形四角变换断言（drawInnerShadow 消费）
```

```text
src/Render/Render.ts : setShadowData(pos, angle, progress, direction)
  → core/FlipTypes.ets 的 FlipShadowData 产出（P3 状态机→renderer 数据流）
  输入: FlipPoint + angle + progress + direction
  输出: FlipShadowData{pos,angle,width,opacity,direction,progress}
  约束: width=pageWidth*3/4*progress/100；opacity=(100−progress)*maxShadowOpacity/100/100；progress 输出 = progress*2；drawShadow=false 时不产出（FLIP_DEFAULTS 默认照抄 StPageFlip：drawShadow=true,maxShadowOpacity=1,flippingTime=1000,swipeDistance=30）
  容差: 1e-6（数值字段，canonical 起点）/ 1e-4（绘制定位）
  用例: progress=25/50/75 时 width/opacity 数值断言
```

---

## 5. FLIP_DEFAULTS 参数表（D9：初值照抄 StPageFlip，P1 落 core/FlipTypes.ets）

| 参数 | StPageFlip 出处 | 初值（照抄） | 变更影响 |
|------|----------------|--------------|----------|
| `flippingTime` | Settings._default | 1000（ms） | 动画时长 |
| `maxShadowOpacity` | Settings._default | 1 | 阴影强度上限 |
| `drawShadow` | Settings._default | true | 是否绘制三道阴影 |
| `swipeDistance` | Settings._default | 30（px） | 划动阈值（P3 手势） |
| `shadowSize 比例` | CanvasRender.drawBookShadow | rect.width/20 | 书脊阴影宽度 |
| 书脊渐变 stops | CanvasRender.drawBookShadow | [0,0.4,0.49,0.5,0.51,1] × [0,0.2,0.1,0.5,0.4,0] | 中缝明暗 |
| 外侧阴影 isw 系数 | CanvasRender.drawInnerShadow | 3/4 | 内侧阴影宽度 |
| 内/外侧阴影 stops | CanvasRender.drawOuterShadow/drawInnerShadow | 按 4.3 条目 | 折叠明暗 |
| `GetBottomClipArea` 距离阈值 | FlipCalculation.getBottomClipArea | 10（px） | 底层裁剪顶点过滤 |
| `da` 退化阈值 | FlipCalculation.calculateAngle | 0.003（rad） | 几何退化判定 |

> 数学恒等常量（如 π、归一化系数）不受 D9 限制。改数值会变效果 = 必须入表（D9）。

---

## 6. 冻结与回填规则

- 本表冻结于 P0 出口；P1/P2 只允许回填"验证结果"列，格式：`P1: PASS(逐函数断言通过)` / `P2: PASS(V1 比对+结构走查通过)` 或失败说明。
- 映射关系（源/目标函数、输入输出、约束、容差）变更 → 先修订主任务 HOS-STPAGEFLIP-001 并重新评审，再改本表。
