export interface Point { x: number; y: number; }
export interface Rect { left: number; top: number; width: number; height: number; }
export type Segment = [Point, Point];

export class Helper {
    static GetDistanceBetweenTwoPoint(point1: Point, point2: Point): number {
        if (point1 === null || point2 === null) return Infinity;
        return Math.sqrt(Math.pow(point2.x - point1.x, 2) + Math.pow(point2.y - point1.y, 2));
    }
    static GetAngleBetweenTwoLine(line1: Segment, line2: Segment): number {
        const A1 = line1[0].y - line1[1].y;
        const A2 = line2[0].y - line2[1].y;
        const B1 = line1[1].x - line1[0].x;
        const B2 = line2[1].x - line2[0].x;
        return Math.acos((A1 * A2 + B1 * B2) / (Math.sqrt(A1 * A1 + B1 * B1) * Math.sqrt(A2 * A2 + B2 * B2)));
    }
    static PointInRect(rect: Rect, pos: Point): Point {
        if (pos === null) return null;
        if (pos.x >= rect.left && pos.x <= rect.width + rect.left && pos.y >= rect.top && pos.y <= rect.top + rect.height) return pos;
        return null;
    }
    static GetRotatedPoint(transformedPoint: Point, startPoint: Point, angle: number): Point {
        return { x: transformedPoint.x * Math.cos(angle) + transformedPoint.y * Math.sin(angle) + startPoint.x,
                 y: transformedPoint.y * Math.cos(angle) - transformedPoint.x * Math.sin(angle) + startPoint.y };
    }
    static LimitPointToCircle(startPoint: Point, radius: number, limitedPoint: Point): Point {
        if (Helper.GetDistanceBetweenTwoPoint(startPoint, limitedPoint) <= radius) return limitedPoint;
        const a = startPoint.x, b = startPoint.y, n = limitedPoint.x, m = limitedPoint.y;
        let x = Math.sqrt((Math.pow(radius, 2) * Math.pow(a - n, 2)) / (Math.pow(a - n, 2) + Math.pow(b - m, 2))) + a;
        if (limitedPoint.x < 0) x *= -1;
        let y = ((x - a) * (b - m)) / (a - n) + b;
        if (a - n + b === 0) y = radius;
        return { x, y };
    }
    static GetIntersectBetweenTwoSegment(rectBorder: Rect, one: Segment, two: Segment): Point {
        return Helper.PointInRect(rectBorder, Helper.GetIntersectBeetwenTwoLine(one, two));
    }
    static GetIntersectBeetwenTwoLine(one: Segment, two: Segment): Point {
        const A1 = one[0].y - one[1].y, A2 = two[0].y - two[1].y;
        const B1 = one[1].x - one[0].x, B2 = two[1].x - two[0].x;
        const C1 = one[0].x * one[1].y - one[1].x * one[0].y;
        const C2 = two[0].x * two[1].y - two[1].x * two[0].y;
        const det1 = A1 * C2 - A2 * C1;
        const det2 = B1 * C2 - B2 * C1;
        const x = -((C1 * B2 - C2 * B1) / (A1 * B2 - A2 * B1));
        const y = -((A1 * C2 - A2 * C1) / (A1 * B2 - A2 * B1));
        if (isFinite(x) && isFinite(y)) return { x, y };
        else { if (Math.abs(det1 - det2) < 0.1) throw new Error('Segment included'); }
        return null;
    }
}
