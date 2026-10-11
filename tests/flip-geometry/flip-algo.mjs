// 将 FlipGeometry 的核心算法复制为纯 JS 验证（与 ArkTS 版逐行一致）
class FlipMath {
  static distance(p1, p2) { if (p1 === null || p2 === null) return Infinity; return Math.sqrt((p2.x-p1.x)**2 + (p2.y-p1.y)**2); }
  static angleBetweenLines(s1, s2) {
    const A1 = s1.a.y - s1.b.y, A2 = s2.a.y - s2.b.y, B1 = s1.b.x - s1.a.x, B2 = s2.b.x - s2.a.x;
    const denom = Math.sqrt(A1*A1+B1*B1) * Math.sqrt(A2*A2+B2*B2);
    if (denom === 0) return 0;
    return Math.acos((A1*A2 + B1*B2) / denom);
  }
  static pointInRect(rect, pos) { if (pos === null) return null; if (pos.x >= rect.left && pos.x <= rect.width+rect.left && pos.y >= rect.top && pos.y <= rect.top+rect.height) return pos; return null; }
  static rotatedPoint(p, origin, angle) { return { x: p.x*Math.cos(angle) + p.y*Math.sin(angle) + origin.x, y: p.y*Math.cos(angle) - p.x*Math.sin(angle) + origin.y }; }
  static limitPointToCircle(center, radius, point) {
    if (FlipMath.distance(center, point) <= radius) return point;
    const a = center.x, b = center.y, n = point.x, m = point.y;
    let x = Math.sqrt((radius*radius*(a-n)*(a-n)) / ((a-n)*(a-n)+(b-m)*(b-m))) + a;
    if (point.x < 0) x *= -1;
    let y = ((x-a)*(b-m)) / (a-n) + b;
    if (a-n+b === 0) y = radius;
    return { x, y };
  }
  static intersectBetweenSegments(rect, s1, s2) { return FlipMath.pointInRect(rect, FlipMath.intersectLines(s1, s2)); }
  static intersectLines(s1, s2) {
    const A1 = s1.a.y-s1.b.y, A2 = s2.a.y-s2.b.y, B1 = s1.b.x-s1.a.x, B2 = s2.b.x-s2.a.x;
    const C1 = s1.a.x*s1.b.y - s1.b.x*s1.a.y, C2 = s2.a.x*s2.b.y - s2.b.x*s2.a.y;
    const denom = A1*B2 - A2*B1;
    if (denom === 0) return null;
    const x = -((C1*B2 - C2*B1)/denom), y = -((A1*C2 - A2*C1)/denom);
    if (isFinite(x) && isFinite(y)) return { x, y };
    return null;
  }
}
const FORWARD = 0, BACK = 1, TOP = 0, BOTTOM = 1;
class FlipGeometry {
  constructor(direction, corner, pageWidth, pageHeight) { this.direction = direction; this.corner = corner; this.pageWidth = pageWidth; this.pageHeight = pageHeight; }
  calc(localPos) { try { this.position = this.calcAngleAndPosition(localPos); this.calculateIntersectPoint(this.position); return true; } catch (e) { return false; } }
  getFlippingClipArea() {
    const result = []; let clipBottom = false;
    result.push(this.rect.topLeft); result.push(this.topIntersectPoint);
    if (this.sideIntersectPoint === null) { clipBottom = true; } else { result.push(this.sideIntersectPoint); if (this.bottomIntersectPoint === null) clipBottom = false; }
    result.push(this.bottomIntersectPoint);
    if (clipBottom || this.corner === BOTTOM) result.push(this.rect.bottomLeft);
    return result;
  }
  getBottomClipArea() {
    const result = [];
    result.push(this.topIntersectPoint);
    if (this.corner === TOP) result.push({ x: this.pageWidth, y: 0 });
    else { if (this.topIntersectPoint !== null) result.push({ x: this.pageWidth, y: 0 }); result.push({ x: this.pageWidth, y: this.pageHeight }); }
    if (this.sideIntersectPoint !== null) { if (FlipMath.distance(this.sideIntersectPoint, this.topIntersectPoint) >= 10) result.push(this.sideIntersectPoint); }
    else { if (this.corner === TOP) result.push({ x: this.pageWidth, y: this.pageHeight }); }
    result.push(this.bottomIntersectPoint); result.push(this.topIntersectPoint);
    return result;
  }
  getAngle() { return this.direction === FORWARD ? -this.angle : this.angle; }
  getRect() { return this.rect; }
  getPosition() { return this.position; }
  getActiveCorner() { return this.direction === FORWARD ? this.rect.topLeft : this.rect.topRight; }
  getFlippingProgress() { return Math.abs(((this.position.x - this.pageWidth) / (2 * this.pageWidth)) * 100); }
  getShadowStartPoint() { if (this.corner === TOP) return this.topIntersectPoint; if (this.sideIntersectPoint !== null) return this.sideIntersectPoint; return this.topIntersectPoint; }
  getShadowAngle() {
    const seg = this.getSegmentToShadowLine();
    const angle = FlipMath.angleBetweenLines(seg, { a: {x:0,y:0}, b: {x:this.pageWidth,y:0} });
    return this.direction === FORWARD ? angle : Math.PI - angle;
  }
  calcAngleAndPosition(pos) {
    let result = pos; this.updateAngleAndGeometry(result);
    if (this.corner === TOP) result = this.checkPositionAtCenterLine(result, {x:0,y:0}, {x:0,y:this.pageHeight});
    else result = this.checkPositionAtCenterLine(result, {x:0,y:this.pageHeight}, {x:0,y:0});
    if (Math.abs(result.x - this.pageWidth) < 1 && Math.abs(result.y) < 1) throw new Error('too small');
    return result;
  }
  updateAngleAndGeometry(pos) { this.angle = this.calculateAngle(pos); this.rect = this.getPageRect(pos); }
  calculateAngle(pos) {
    const left = this.pageWidth - pos.x + 1;
    const top = this.corner === BOTTOM ? this.pageHeight - pos.y : pos.y;
    let angle = 2 * Math.acos(left / Math.sqrt(top*top + left*left));
    if (top < 0) angle = -angle;
    const da = Math.PI - angle;
    if (!isFinite(angle) || (da >= 0 && da < 0.003)) throw new Error('G too small');
    if (this.corner === BOTTOM) angle = -angle;
    return angle;
  }
  getPageRect(localPos) {
    if (this.corner === TOP) return this.getRectFromBasePoint([{x:0,y:0},{x:this.pageWidth,y:0},{x:0,y:this.pageHeight},{x:this.pageWidth,y:this.pageHeight}], localPos);
    return this.getRectFromBasePoint([{x:0,y:-this.pageHeight},{x:this.pageWidth,y:-this.pageHeight},{x:0,y:0},{x:this.pageWidth,y:0}], localPos);
  }
  getRectFromBasePoint(points, localPos) {
    return { topLeft: FlipMath.rotatedPoint(points[0], localPos, this.angle), topRight: FlipMath.rotatedPoint(points[1], localPos, this.angle), bottomLeft: FlipMath.rotatedPoint(points[2], localPos, this.angle), bottomRight: FlipMath.rotatedPoint(points[3], localPos, this.angle) };
  }
  calculateIntersectPoint(pos) {
    const boundRect = { left: -1, top: -1, width: this.pageWidth + 2, height: this.pageHeight + 2 };
    if (this.corner === TOP) {
      this.topIntersectPoint = FlipMath.intersectBetweenSegments(boundRect, {a:pos,b:this.rect.topRight}, {a:{x:0,y:0},b:{x:this.pageWidth,y:0}});
      this.sideIntersectPoint = FlipMath.intersectBetweenSegments(boundRect, {a:pos,b:this.rect.bottomLeft}, {a:{x:this.pageWidth,y:0},b:{x:this.pageWidth,y:this.pageHeight}});
      this.bottomIntersectPoint = FlipMath.intersectBetweenSegments(boundRect, {a:this.rect.bottomLeft,b:this.rect.bottomRight}, {a:{x:0,y:this.pageHeight},b:{x:this.pageWidth,y:this.pageHeight}});
    } else {
      this.topIntersectPoint = FlipMath.intersectBetweenSegments(boundRect, {a:this.rect.topLeft,b:this.rect.topRight}, {a:{x:0,y:0},b:{x:this.pageWidth,y:0}});
      this.sideIntersectPoint = FlipMath.intersectBetweenSegments(boundRect, {a:pos,b:this.rect.topLeft}, {a:{x:this.pageWidth,y:0},b:{x:this.pageWidth,y:this.pageHeight}});
      this.bottomIntersectPoint = FlipMath.intersectBetweenSegments(boundRect, {a:this.rect.bottomLeft,b:this.rect.bottomRight}, {a:{x:0,y:this.pageHeight},b:{x:this.pageWidth,y:this.pageHeight}});
    }
  }
  checkPositionAtCenterLine(checkedPos, centerOne, centerTwo) {
    let result = checkedPos;
    const tmp = FlipMath.limitPointToCircle(centerOne, this.pageWidth, result);
    if (result !== tmp) { result = tmp; this.updateAngleAndGeometry(result); }
    const rad = Math.sqrt(this.pageWidth**2 + this.pageHeight**2);
    let checkPointOne = this.rect.bottomRight, checkPointTwo = this.rect.topLeft;
    if (this.corner === BOTTOM) { checkPointOne = this.rect.topRight; checkPointTwo = this.rect.bottomLeft; }
    if (checkPointOne.x <= 0) { const bottomPoint = FlipMath.limitPointToCircle(centerTwo, rad, checkPointTwo); if (bottomPoint !== result) { result = bottomPoint; this.updateAngleAndGeometry(result); } }
    return result;
  }
  getSegmentToShadowLine() {
    const first = this.getShadowStartPoint();
    let second;
    if (first !== this.sideIntersectPoint && this.sideIntersectPoint !== null) second = this.sideIntersectPoint;
    else second = this.bottomIntersectPoint;
    if (first === null) return { a: {x:0,y:0}, b: {x:0,y:0} };
    if (second === null) return { a: first, b: first };
    return { a: first, b: second };
  }
}


export { FlipMath, FlipGeometry, FORWARD, BACK, TOP, BOTTOM };
