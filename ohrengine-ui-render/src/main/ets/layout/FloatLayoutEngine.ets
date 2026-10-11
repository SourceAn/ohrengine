/**
 * Float Layout Engine
 *
 * Manages active CSS float boxes per page layout call.
 * Supports per-side Y-stacking for left and right floats,
 * available line width computation for text wrapping around floats,
 * and clear property integration.
 *
 * Usage:
 *   const engine: FloatLayoutEngine = new FloatLayoutEngine();
 *   const positioned: FloatBox = engine.positionFloat({ x:0, y:0, width:100, height:80, side:'left' }, contentWidth);
 *   const availWidth: number = engine.getAvailableLineWidth(y, contentWidth);
 *   const clearY: number = engine.clearFloats('left', contentWidth);
 *   engine.reset(); // per page
 */

/**
 * Represents a positioned float box within the content area.
 */
export interface FloatBox {
  x: number;
  y: number;
  width: number;
  height: number;
  side: 'left' | 'right';
  marginTop?: number;
  marginRight?: number;
  marginBottom?: number;
  marginLeft?: number;
}

/**
 * FloatLayoutEngine — manages active float boxes and provides
 * positioning, wrapping-width computation, and clear support.
 */
export class FloatLayoutEngine {
  private activeLeftFloats: FloatBox[] = [];
  private activeRightFloats: FloatBox[] = [];
  private leftStackY: number = 0;
  private rightStackY: number = 0;

  constructor() {
  }

  /**
   * Position a float box on its specified side.
   *
   * Left floats are placed at x=0, right floats at x=contentWidth - width.
   * Each side maintains an independent Y cursor for vertical stacking.
   *
   * @param box - The float box to position (side must be set)
   * @param contentWidth - The full content area width for right-side positioning
   * @returns The positioned FloatBox with x and y set
   */
  public positionFloat(box: FloatBox, contentWidth: number): FloatBox {
    if (box.side === 'left') {
      box.x = 0;
      box.y = this.leftStackY;
      this.leftStackY = box.y + box.height;
      this.activeLeftFloats.push(box);
    } else {
      box.x = Math.max(0, contentWidth - box.width);
      box.y = this.rightStackY;
      this.rightStackY = box.y + box.height;
      this.activeRightFloats.push(box);
    }
    return box;
  }

  /**
   * Get the available line width at a given Y position,
   * accounting for active floats that overlap at that Y.
   *
   * If no float overlaps at the given Y, returns full contentWidth.
   *
   * @param y - The Y position to check
   * @param contentWidth - The full content area width
   * @returns The available width for text at this Y position
   */
  public getAvailableLineWidth(y: number, contentWidth: number): number {
    // Find the rightmost edge of left floats that overlap this Y
    let leftBlockRight: number = 0;
    for (let i = 0; i < this.activeLeftFloats.length; i++) {
      const fb: FloatBox = this.activeLeftFloats[i];
      if (y >= fb.y && y < fb.y + fb.height) {
        const rightEdge: number = fb.x + fb.width;
        if (rightEdge > leftBlockRight) {
          leftBlockRight = rightEdge;
        }
      }
    }

    // Find the leftmost edge of right floats that overlap this Y
    let rightBlockLeft: number = contentWidth;
    for (let i = 0; i < this.activeRightFloats.length; i++) {
      const fb: FloatBox = this.activeRightFloats[i];
      if (y >= fb.y && y < fb.y + fb.height) {
        if (fb.x < rightBlockLeft) {
          rightBlockLeft = fb.x;
        }
      }
    }

    const available: number = rightBlockLeft - leftBlockRight;
    return available > 0 ? available : 0;
  }

  /**
   * Clear floats on the specified side(s).
   * Removes cleared floats from the active list and returns the Y position
   * below all cleared floats for subsequent element placement.
   *
   * @param side - Which side(s) to clear: 'left', 'right', or 'both'
   * @param contentWidth - The full content area width
   * @returns The Y value below the tallest cleared float
   */
  public clearFloats(side: 'left' | 'right' | 'both', contentWidth: number): number {
    let maxBottom: number = 0;

    if (side === 'left' || side === 'both') {
      for (let i = 0; i < this.activeLeftFloats.length; i++) {
        const fb: FloatBox = this.activeLeftFloats[i];
        const bottom: number = fb.y + fb.height;
        if (bottom > maxBottom) {
          maxBottom = bottom;
        }
      }
      this.activeLeftFloats = [];
      this.leftStackY = maxBottom;
    }

    if (side === 'right' || side === 'both') {
      for (let i = 0; i < this.activeRightFloats.length; i++) {
        const fb: FloatBox = this.activeRightFloats[i];
        const bottom: number = fb.y + fb.height;
        if (bottom > maxBottom) {
          maxBottom = bottom;
        }
      }
      this.activeRightFloats = [];
      this.rightStackY = maxBottom;
    }

    return maxBottom;
  }

  /**
   * Get all currently active floats from both sides.
   * Useful for rendering or debugging.
   */
  public getActiveFloats(): FloatBox[] {
    const result: FloatBox[] = [];
    for (let i = 0; i < this.activeLeftFloats.length; i++) {
      result.push(this.activeLeftFloats[i]);
    }
    for (let i = 0; i < this.activeRightFloats.length; i++) {
      result.push(this.activeRightFloats[i]);
    }
    return result;
  }

  /**
   * Reset all active floats and Y cursors.
   * Must be called at the start of each page layout.
   */
  public reset(): void {
    this.activeLeftFloats = [];
    this.activeRightFloats = [];
    this.leftStackY = 0;
    this.rightStackY = 0;
  }
}
