/**
 * FlipGeometry — 仿真翻页几何算法
 *
 * 算法移植自 MIT 协议开源项目 Nodlik/StPageFlip（src/Flip/FlipCalculation.ts + src/Helper.ts），
 * 并参考了 turn.js / react-pageflip 等实现的通用做法。本项目为单页模式，
 * "书本区域"即整个内容区，活动页局部坐标 = 内容区坐标（原点 = 内容区左上角，单位 vp）。
 *
 * 核心模型（与 STPageFlip 一致）：
 *   1. 页面是一个 pageWidth × pageHeight 的矩形（当前页），初始覆盖整个内容区；
 *   2. 触摸点 pos 是被"拖拽的角"，页面绕 pos 旋转 angle；
 *   3. angle = 2 × atan2(top, pageWidth - pos.x + 1)，保证页边翻折到书脊镜像位置；
 *   4. 旋转后的页面与书本区域求交，得到裁剪多边形（翻转页只在书本区域内可见）；
 *   5. 底页（目标页）同样按交点多边形裁剪，画在内容区；
 *   6. 阴影从折痕（交点连线）出发，沿垂直方向渐变，宽度/透明度随翻页进度变化。
 */

/** 视觉翻页方向（与阅读器视觉一致：FORWARD = 页面向左翻，露出下一页） */
export enum FlipVisualDirection {
  FORWARD = 0,
  BACK = 1,
}

/** 被拖拽的页角（上/下） */
export enum FlipCorner {
  TOP = 0,
  BOTTOM = 1,
}

export interface FlipPoint {
  x: number;
  y: number;
}

export interface FlipRectPoints {
  topLeft: FlipPoint;
  topRight: FlipPoint;
  bottomLeft: FlipPoint;
  bottomRight: FlipPoint;
}

interface FlipBoundRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

interface FlipSegment {
  a: FlipPoint;
  b: FlipPoint;
}

/**
 * 几何辅助数学函数（移植自 StPageFlip Helper.ts）
 */
export class FlipMath {
  /** 两点距离（null 点视为无穷远） */
  static distance(p1: FlipPoint | null, p2: FlipPoint | null): number {
    if (p1 === null || p2 === null) {
      return Infinity;
    }
    return Math.sqrt(Math.pow(p2.x - p1.x, 2) + Math.pow(p2.y - p1.y, 2));
  }

  /** 两线段夹角（弧度，0..π） */
  static angleBetweenLines(s1: FlipSegment, s2: FlipSegment): number {
    const A1: number = s1.a.y - s1.b.y;
    const A2: number = s2.a.y - s2.b.y;
    const B1: number = s1.b.x - s1.a.x;
    const B2: number = s2.b.x - s2.a.x;
    const denom: number =
      Math.sqrt(A1 * A1 + B1 * B1) * Math.sqrt(A2 * A2 + B2 * B2);
    if (denom === 0) {
      return 0;
    }
    return Math.acos((A1 * A2 + B1 * B2) / denom);
  }

  /** 点是否在矩形内（含边界） */
  static pointInRect(rect: FlipBoundRect, pos: FlipPoint | null): FlipPoint | null {
    if (pos === null) {
      return null;
    }
    if (
      pos.x >= rect.left &&
      pos.x <= rect.width + rect.left &&
      pos.y >= rect.top &&
      pos.y <= rect.top + rect.height
    ) {
      return pos;
    }
    return null;
  }

  /** 点绕原点旋转 angle（弧度） */
  static rotatedPoint(p: FlipPoint, origin: FlipPoint, angle: number): FlipPoint {
    return {
      x: p.x * Math.cos(angle) + p.y * Math.sin(angle) + origin.x,
      y: p.y * Math.cos(angle) - p.x * Math.sin(angle) + origin.y,
    };
  }

  /**
   * 把点限制到以 center 为圆心、radius 为半径的圆内：
   * 圆内直接返回；圆外返回"圆心→该点"连线与圆的交点。
   */
  static limitPointToCircle(center: FlipPoint, radius: number, point: FlipPoint): FlipPoint {
    if (FlipMath.distance(center, point) <= radius) {
      return point;
    }
    const a: number = center.x;
    const b: number = center.y;
    const n: number = point.x;
    const m: number = point.y;
    let x: number =
      Math.sqrt((radius * radius * (a - n) * (a - n)) / ((a - n) * (a - n) + (b - m) * (b - m))) + a;
    if (point.x < 0) {
      x *= -1;
    }
    let y: number = ((x - a) * (b - m)) / (a - n) + b;
    if (a - n + b === 0) {
      y = radius;
    }
    return { x: x, y: y };
  }

  /** 两线段交点（限制在矩形内则返回交点，否则 null） */
  static intersectBetweenSegments(
    rect: FlipBoundRect, s1: FlipSegment, s2: FlipSegment
  ): FlipPoint | null {
    return FlipMath.pointInRect(rect, FlipMath.intersectLines(s1, s2));
  }

  /** 两直线交点（平行/重合返回 null） */
  static intersectLines(s1: FlipSegment, s2: FlipSegment): FlipPoint | null {
    const A1: number = s1.a.y - s1.b.y;
    const A2: number = s2.a.y - s2.b.y;
    const B1: number = s1.b.x - s1.a.x;
    const B2: number = s2.b.x - s2.a.x;
    const C1: number = s1.a.x * s1.b.y - s1.b.x * s1.a.y;
    const C2: number = s2.a.x * s2.b.y - s2.b.x * s2.a.y;
    const denom: number = A1 * B2 - A2 * B1;
    if (denom === 0) {
      return null;
    }
    const x: number = -((C1 * B2 - C2 * B1) / denom);
    const y: number = -((A1 * C2 - A2 * C1) / denom);
    if (isFinite(x) && isFinite(y)) {
      return { x: x, y: y };
    }
    return null;
  }

  /** 两点间线性插值点序列（step 步长，包含两端点） */
  static cordsFromTwoPoint(p1: FlipPoint, p2: FlipPoint, step: number): FlipPoint[] {
    const sizeX: number = Math.abs(p1.x - p2.x);
    const sizeY: number = Math.abs(p1.y - p2.y);
    const lengthLine: number = Math.max(sizeX, sizeY);
    const steps: number = Math.max(1, Math.floor(lengthLine / step));
    const result: FlipPoint[] = [];
    for (let i: number = 0; i <= steps; i++) {
      const t: number = i / steps;
      result.push({ x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t });
    }
    return result;
  }
}

/**
 * 翻页几何计算（移植自 StPageFlip FlipCalculation.ts）。
 * 坐标系：内容区局部坐标（[0, pageWidth] × [0, pageHeight]）。
 */
export class FlipGeometry {
  private angle: number = 0;
  private position: FlipPoint = { x: 0, y: 0 };
  private rect: FlipRectPoints = {
    topLeft: { x: 0, y: 0 },
    topRight: { x: 0, y: 0 },
    bottomLeft: { x: 0, y: 0 },
    bottomRight: { x: 0, y: 0 },
  };
  private topIntersectPoint: FlipPoint | null = null;
  private sideIntersectPoint: FlipPoint | null = null;
  private bottomIntersectPoint: FlipPoint | null = null;
  private readonly direction: FlipVisualDirection;
  private readonly corner: FlipCorner;
  private readonly pageWidth: number;
  private readonly pageHeight: number;

  constructor(
    direction: FlipVisualDirection,
    corner: FlipCorner,
    pageWidth: number,
    pageHeight: number
  ) {
    this.direction = direction;
    this.corner = corner;
    this.pageWidth = pageWidth;
    this.pageHeight = pageHeight;
  }

  /**
   * 主计算：输入触摸点（内容区局部坐标），更新旋转角/位置/交点。
   * @returns true=计算成功；false=几何非法（如角点未被拉动），保持上一帧状态
   */
  public calc(localPos: FlipPoint): boolean {
    try {
      this.position = this.calcAngleAndPosition(localPos);
      this.calculateIntersectPoint(this.position);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 翻转页裁剪多边形（内容区坐标；可能含 null 顶点，绘制时跳过） */
  public getFlippingClipArea(): (FlipPoint | null)[] {
    const result: (FlipPoint | null)[] = [];
    let clipBottom: boolean = false;

    result.push(this.rect.topLeft);
    result.push(this.topIntersectPoint);

    if (this.sideIntersectPoint === null) {
      clipBottom = true;
    } else {
      result.push(this.sideIntersectPoint);
      if (this.bottomIntersectPoint === null) {
        clipBottom = false;
      }
    }

    result.push(this.bottomIntersectPoint);

    if (clipBottom || this.corner === FlipCorner.BOTTOM) {
      result.push(this.rect.bottomLeft);
    }

    return result;
  }

  /** 底页裁剪多边形（内容区坐标；可能含 null 顶点，绘制时跳过） */
  public getBottomClipArea(): (FlipPoint | null)[] {
    const result: (FlipPoint | null)[] = [];

    result.push(this.topIntersectPoint);

    if (this.corner === FlipCorner.TOP) {
      result.push({ x: this.pageWidth, y: 0 });
    } else {
      if (this.topIntersectPoint !== null) {
        result.push({ x: this.pageWidth, y: 0 });
      }
      result.push({ x: this.pageWidth, y: this.pageHeight });
    }

    if (this.sideIntersectPoint !== null) {
      if (FlipMath.distance(this.sideIntersectPoint, this.topIntersectPoint) >= 10) {
        result.push(this.sideIntersectPoint);
      }
    } else {
      if (this.corner === FlipCorner.TOP) {
        result.push({ x: this.pageWidth, y: this.pageHeight });
      }
    }

    result.push(this.bottomIntersectPoint);
    result.push(this.topIntersectPoint);

    return result;
  }

  /** 翻转页旋转角（弧度，绘制时 rotate 用） */
  public getAngle(): number {
    if (this.direction === FlipVisualDirection.FORWARD) {
      return -this.angle;
    }
    return this.angle;
  }

  /** 旋转后的页面矩形（内容区坐标） */
  public getRect(): FlipRectPoints {
    return this.rect;
  }

  /** 当前触摸点（内容区坐标） */
  public getPosition(): FlipPoint {
    return this.position;
  }

  /** 翻转页绘制锚点（旋转中心，内容区坐标） */
  public getActiveCorner(): FlipPoint {
    if (this.direction === FlipVisualDirection.FORWARD) {
      return this.rect.topLeft;
    }
    return this.rect.topRight;
  }

  public getDirection(): FlipVisualDirection {
    return this.direction;
  }

  public getCorner(): FlipCorner {
    return this.corner;
  }

  /** 翻页进度（0..100） */
  public getFlippingProgress(): number {
    return Math.abs(((this.position.x - this.pageWidth) / (2 * this.pageWidth)) * 100);
  }

  /** 底页绘制位置（单页模式下恒为内容区原点） */
  public getBottomPagePosition(): FlipPoint {
    return { x: 0, y: 0 };
  }

  /** 阴影起点（内容区坐标） */
  public getShadowStartPoint(): FlipPoint | null {
    if (this.corner === FlipCorner.TOP) {
      return this.topIntersectPoint;
    }
    if (this.sideIntersectPoint !== null) {
      return this.sideIntersectPoint;
    }
    return this.topIntersectPoint;
  }

  /** 阴影旋转角（弧度） */
  public getShadowAngle(): number {
    const seg: FlipSegment = this.getSegmentToShadowLine();
    const angle: number = FlipMath.angleBetweenLines(seg, {
      a: { x: 0, y: 0 },
      b: { x: this.pageWidth, y: 0 },
    });
    if (this.direction === FlipVisualDirection.FORWARD) {
      return angle;
    }
    return Math.PI - angle;
  }

  private calcAngleAndPosition(pos: FlipPoint): FlipPoint {
    let result: FlipPoint = pos;
    this.updateAngleAndGeometry(result);

    if (this.corner === FlipCorner.TOP) {
      result = this.checkPositionAtCenterLine(
        result, { x: 0, y: 0 }, { x: 0, y: this.pageHeight }
      );
    } else {
      result = this.checkPositionAtCenterLine(
        result, { x: 0, y: this.pageHeight }, { x: 0, y: 0 }
      );
    }

    if (Math.abs(result.x - this.pageWidth) < 1 && Math.abs(result.y) < 1) {
      throw new Error('point is too small');
    }
    return result;
  }

  private updateAngleAndGeometry(pos: FlipPoint): void {
    this.angle = this.calculateAngle(pos);
    this.rect = this.getPageRect(pos);
  }

  private calculateAngle(pos: FlipPoint): number {
    const left: number = this.pageWidth - pos.x + 1;
    const top: number = this.corner === FlipCorner.BOTTOM ? this.pageHeight - pos.y : pos.y;

    let angle: number = 2 * Math.acos(left / Math.sqrt(top * top + left * left));
    if (top < 0) {
      angle = -angle;
    }

    const da: number = Math.PI - angle;
    if (!isFinite(angle) || (da >= 0 && da < 0.003)) {
      throw new Error('G point is too small');
    }

    if (this.corner === FlipCorner.BOTTOM) {
      angle = -angle;
    }
    return angle;
  }

  private getPageRect(localPos: FlipPoint): FlipRectPoints {
    if (this.corner === FlipCorner.TOP) {
      return this.getRectFromBasePoint(
        [
          { x: 0, y: 0 },
          { x: this.pageWidth, y: 0 },
          { x: 0, y: this.pageHeight },
          { x: this.pageWidth, y: this.pageHeight },
        ],
        localPos
      );
    }
    return this.getRectFromBasePoint(
      [
        { x: 0, y: -this.pageHeight },
        { x: this.pageWidth, y: -this.pageHeight },
        { x: 0, y: 0 },
        { x: this.pageWidth, y: 0 },
      ],
      localPos
    );
  }

  private getRectFromBasePoint(points: FlipPoint[], localPos: FlipPoint): FlipRectPoints {
    return {
      topLeft: FlipMath.rotatedPoint(points[0], localPos, this.angle),
      topRight: FlipMath.rotatedPoint(points[1], localPos, this.angle),
      bottomLeft: FlipMath.rotatedPoint(points[2], localPos, this.angle),
      bottomRight: FlipMath.rotatedPoint(points[3], localPos, this.angle),
    };
  }

  private calculateIntersectPoint(pos: FlipPoint): void {
    const boundRect: FlipBoundRect = {
      left: -1,
      top: -1,
      width: this.pageWidth + 2,
      height: this.pageHeight + 2,
    };

    if (this.corner === FlipCorner.TOP) {
      this.topIntersectPoint = FlipMath.intersectBetweenSegments(
        boundRect,
        { a: pos, b: this.rect.topRight },
        { a: { x: 0, y: 0 }, b: { x: this.pageWidth, y: 0 } }
      );
      this.sideIntersectPoint = FlipMath.intersectBetweenSegments(
        boundRect,
        { a: pos, b: this.rect.bottomLeft },
        { a: { x: this.pageWidth, y: 0 }, b: { x: this.pageWidth, y: this.pageHeight } }
      );
      this.bottomIntersectPoint = FlipMath.intersectBetweenSegments(
        boundRect,
        { a: this.rect.bottomLeft, b: this.rect.bottomRight },
        { a: { x: 0, y: this.pageHeight }, b: { x: this.pageWidth, y: this.pageHeight } }
      );
    } else {
      this.topIntersectPoint = FlipMath.intersectBetweenSegments(
        boundRect,
        { a: this.rect.topLeft, b: this.rect.topRight },
        { a: { x: 0, y: 0 }, b: { x: this.pageWidth, y: 0 } }
      );
      this.sideIntersectPoint = FlipMath.intersectBetweenSegments(
        boundRect,
        { a: pos, b: this.rect.topLeft },
        { a: { x: this.pageWidth, y: 0 }, b: { x: this.pageWidth, y: this.pageHeight } }
      );
      this.bottomIntersectPoint = FlipMath.intersectBetweenSegments(
        boundRect,
        { a: this.rect.bottomLeft, b: this.rect.bottomRight },
        { a: { x: 0, y: this.pageHeight }, b: { x: this.pageWidth, y: this.pageHeight } }
      );
    }
  }

  private checkPositionAtCenterLine(
    checkedPos: FlipPoint, centerOne: FlipPoint, centerTwo: FlipPoint
  ): FlipPoint {
    let result: FlipPoint = checkedPos;

    const tmp: FlipPoint = FlipMath.limitPointToCircle(centerOne, this.pageWidth, result);
    if (result !== tmp) {
      result = tmp;
      this.updateAngleAndGeometry(result);
    }

    const rad: number = Math.sqrt(Math.pow(this.pageWidth, 2) + Math.pow(this.pageHeight, 2));

    let checkPointOne: FlipPoint = this.rect.bottomRight;
    let checkPointTwo: FlipPoint = this.rect.topLeft;

    if (this.corner === FlipCorner.BOTTOM) {
      checkPointOne = this.rect.topRight;
      checkPointTwo = this.rect.bottomLeft;
    }

    if (checkPointOne.x <= 0) {
      const bottomPoint: FlipPoint = FlipMath.limitPointToCircle(centerTwo, rad, checkPointTwo);
      if (bottomPoint !== result) {
        result = bottomPoint;
        this.updateAngleAndGeometry(result);
      }
    }

    return result;
  }

  private getSegmentToShadowLine(): FlipSegment {
    const first: FlipPoint | null = this.getShadowStartPoint();

    let second: FlipPoint | null;
    if (first !== this.sideIntersectPoint && this.sideIntersectPoint !== null) {
      second = this.sideIntersectPoint;
    } else {
      second = this.bottomIntersectPoint;
    }

    if (first === null) {
      return { a: { x: 0, y: 0 }, b: { x: 0, y: 0 } };
    }
    if (second === null) {
      return { a: first, b: first };
    }
    return { a: first, b: second };
  }
}
