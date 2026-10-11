var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var flipcalc_exports = {};
__export(flipcalc_exports, {
  FlipCalculation: () => FlipCalculation,
  FlipCorner: () => FlipCorner,
  FlipDirection: () => FlipDirection
});
module.exports = __toCommonJS(flipcalc_exports);
var import_helper = require("./helper");
var FlipDirection = /* @__PURE__ */ ((FlipDirection2) => {
  FlipDirection2[FlipDirection2["FORWARD"] = 0] = "FORWARD";
  FlipDirection2[FlipDirection2["BACK"] = 1] = "BACK";
  return FlipDirection2;
})(FlipDirection || {});
var FlipCorner = /* @__PURE__ */ ((FlipCorner2) => {
  FlipCorner2["TOP"] = "top";
  FlipCorner2["BOTTOM"] = "bottom";
  return FlipCorner2;
})(FlipCorner || {});
class FlipCalculation {
  constructor(direction, corner, pageWidth, pageHeight) {
    this.direction = direction;
    this.corner = corner;
    this.pageWidth = parseInt(pageWidth, 10);
    this.pageHeight = parseInt(pageHeight, 10);
  }
  direction;
  corner;
  angle;
  position;
  rect;
  topIntersectPoint = null;
  sideIntersectPoint = null;
  bottomIntersectPoint = null;
  pageWidth;
  pageHeight;
  calc(localPos) {
    try {
      this.position = this.calcAngleAndPosition(localPos);
      this.calculateIntersectPoint(this.position);
      return true;
    } catch (e) {
      return false;
    }
  }
  getFlippingClipArea() {
    const result = [];
    let clipBottom = false;
    result.push(this.rect.topLeft);
    result.push(this.topIntersectPoint);
    if (this.sideIntersectPoint === null) {
      clipBottom = true;
    } else {
      result.push(this.sideIntersectPoint);
      if (this.bottomIntersectPoint === null) clipBottom = false;
    }
    result.push(this.bottomIntersectPoint);
    if (clipBottom || this.corner === "bottom" /* BOTTOM */) result.push(this.rect.bottomLeft);
    return result;
  }
  getBottomClipArea() {
    const result = [];
    result.push(this.topIntersectPoint);
    if (this.corner === "top" /* TOP */) result.push({ x: this.pageWidth, y: 0 });
    else {
      if (this.topIntersectPoint !== null) result.push({ x: this.pageWidth, y: 0 });
      result.push({ x: this.pageWidth, y: this.pageHeight });
    }
    if (this.sideIntersectPoint !== null) {
      if (import_helper.Helper.GetDistanceBetweenTwoPoint(this.sideIntersectPoint, this.topIntersectPoint) >= 10) result.push(this.sideIntersectPoint);
    } else {
      if (this.corner === "top" /* TOP */) result.push({ x: this.pageWidth, y: this.pageHeight });
    }
    result.push(this.bottomIntersectPoint);
    result.push(this.topIntersectPoint);
    return result;
  }
  getAngle() {
    return this.direction === 0 /* FORWARD */ ? -this.angle : this.angle;
  }
  getRect() {
    return this.rect;
  }
  getPosition() {
    return this.position;
  }
  getActiveCorner() {
    return this.direction === 0 /* FORWARD */ ? this.rect.topLeft : this.rect.topRight;
  }
  getFlippingProgress() {
    return Math.abs((this.position.x - this.pageWidth) / (2 * this.pageWidth) * 100);
  }
  getShadowStartPoint() {
    if (this.corner === "top" /* TOP */) return this.topIntersectPoint;
    else {
      if (this.sideIntersectPoint !== null) return this.sideIntersectPoint;
      return this.topIntersectPoint;
    }
  }
  getShadowAngle() {
    const angle = import_helper.Helper.GetAngleBetweenTwoLine(this.getSegmentToShadowLine(), [{ x: 0, y: 0 }, { x: this.pageWidth, y: 0 }]);
    return this.direction === 0 /* FORWARD */ ? angle : Math.PI - angle;
  }
  calcAngleAndPosition(pos) {
    let result = pos;
    this.updateAngleAndGeometry(result);
    if (this.corner === "top" /* TOP */) result = this.checkPositionAtCenterLine(result, { x: 0, y: 0 }, { x: 0, y: this.pageHeight });
    else result = this.checkPositionAtCenterLine(result, { x: 0, y: this.pageHeight }, { x: 0, y: 0 });
    if (Math.abs(result.x - this.pageWidth) < 1 && Math.abs(result.y) < 1) throw new Error("Point is too small");
    return result;
  }
  updateAngleAndGeometry(pos) {
    this.angle = this.calculateAngle(pos);
    this.rect = this.getPageRect(pos);
  }
  calculateAngle(pos) {
    const left = this.pageWidth - pos.x + 1;
    const top = this.corner === "bottom" /* BOTTOM */ ? this.pageHeight - pos.y : pos.y;
    let angle = 2 * Math.acos(left / Math.sqrt(top * top + left * left));
    if (top < 0) angle = -angle;
    const da = Math.PI - angle;
    if (!isFinite(angle) || da >= 0 && da < 3e-3) throw new Error("The G point is too small");
    if (this.corner === "bottom" /* BOTTOM */) angle = -angle;
    return angle;
  }
  getPageRect(localPos) {
    if (this.corner === "top" /* TOP */) {
      return this.getRectFromBasePoint([{ x: 0, y: 0 }, { x: this.pageWidth, y: 0 }, { x: 0, y: this.pageHeight }, { x: this.pageWidth, y: this.pageHeight }], localPos);
    }
    return this.getRectFromBasePoint([{ x: 0, y: -this.pageHeight }, { x: this.pageWidth, y: -this.pageHeight }, { x: 0, y: 0 }, { x: this.pageWidth, y: 0 }], localPos);
  }
  getRectFromBasePoint(points, localPos) {
    return { topLeft: this.getRotatedPoint(points[0], localPos), topRight: this.getRotatedPoint(points[1], localPos), bottomLeft: this.getRotatedPoint(points[2], localPos), bottomRight: this.getRotatedPoint(points[3], localPos) };
  }
  getRotatedPoint(transformedPoint, startPoint) {
    return {
      x: transformedPoint.x * Math.cos(this.angle) + transformedPoint.y * Math.sin(this.angle) + startPoint.x,
      y: transformedPoint.y * Math.cos(this.angle) - transformedPoint.x * Math.sin(this.angle) + startPoint.y
    };
  }
  calculateIntersectPoint(pos) {
    const boundRect = { left: -1, top: -1, width: this.pageWidth + 2, height: this.pageHeight + 2 };
    if (this.corner === "top" /* TOP */) {
      this.topIntersectPoint = import_helper.Helper.GetIntersectBetweenTwoSegment(boundRect, [pos, this.rect.topRight], [{ x: 0, y: 0 }, { x: this.pageWidth, y: 0 }]);
      this.sideIntersectPoint = import_helper.Helper.GetIntersectBetweenTwoSegment(boundRect, [pos, this.rect.bottomLeft], [{ x: this.pageWidth, y: 0 }, { x: this.pageWidth, y: this.pageHeight }]);
      this.bottomIntersectPoint = import_helper.Helper.GetIntersectBetweenTwoSegment(boundRect, [this.rect.bottomLeft, this.rect.bottomRight], [{ x: 0, y: this.pageHeight }, { x: this.pageWidth, y: this.pageHeight }]);
    } else {
      this.topIntersectPoint = import_helper.Helper.GetIntersectBetweenTwoSegment(boundRect, [this.rect.topLeft, this.rect.topRight], [{ x: 0, y: 0 }, { x: this.pageWidth, y: 0 }]);
      this.sideIntersectPoint = import_helper.Helper.GetIntersectBetweenTwoSegment(boundRect, [pos, this.rect.topLeft], [{ x: this.pageWidth, y: 0 }, { x: this.pageWidth, y: this.pageHeight }]);
      this.bottomIntersectPoint = import_helper.Helper.GetIntersectBetweenTwoSegment(boundRect, [this.rect.bottomLeft, this.rect.bottomRight], [{ x: 0, y: this.pageHeight }, { x: this.pageWidth, y: this.pageHeight }]);
    }
  }
  checkPositionAtCenterLine(checkedPos, centerOne, centerTwo) {
    let result = checkedPos;
    const tmp = import_helper.Helper.LimitPointToCircle(centerOne, this.pageWidth, result);
    if (result !== tmp) {
      result = tmp;
      this.updateAngleAndGeometry(result);
    }
    const rad = Math.sqrt(Math.pow(this.pageWidth, 2) + Math.pow(this.pageHeight, 2));
    let checkPointOne = this.rect.bottomRight;
    let checkPointTwo = this.rect.topLeft;
    if (this.corner === "bottom" /* BOTTOM */) {
      checkPointOne = this.rect.topRight;
      checkPointTwo = this.rect.bottomLeft;
    }
    if (checkPointOne.x <= 0) {
      const bottomPoint = import_helper.Helper.LimitPointToCircle(centerTwo, rad, checkPointTwo);
      if (bottomPoint !== result) {
        result = bottomPoint;
        this.updateAngleAndGeometry(result);
      }
    }
    return result;
  }
  getSegmentToShadowLine() {
    const first = this.getShadowStartPoint();
    const second = first !== this.sideIntersectPoint && this.sideIntersectPoint !== null ? this.sideIntersectPoint : this.bottomIntersectPoint;
    return [first, second];
  }
}
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  FlipCalculation,
  FlipCorner,
  FlipDirection
});
